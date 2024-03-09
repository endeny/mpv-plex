/*
 * This file is part of mpv.
 *
 * mpv is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <CoreGraphics/CoreGraphics.h>
#include <QuartzCore/CAMetalLayer.h>
#include <MoltenVK/mvk_vulkan.h>

#include "common.h"
#include "context.h"
#include "video/out/vo.h"
#include "utils.h"

struct priv {
    struct mpvk_ctx vk;
    CAMetalLayer *layer;
    MetalLayerDelegate *delegate;
};

@interface MetalLayerDelegate : NSObject<CALayerDelegate>
@property (nonatomic) struct ra_ctx *ra_ctx;
- (id) initWithContext: (struct ra_ctx*) cxt;
@end

@implementation MetalLayerDelegate

- (id)initWithContext: (struct ra_ctx*) ctx
{
    _ra_ctx = ctx;
    return self;
}

- (void)layoutSublayersOfLayer: (CALayer*) layer
{
    struct priv *p = _ra_ctx->priv;
    CAMetalLayer *metalLayer = (CAMetalLayer *)layer;
    CGSize s = metalLayer.drawableSize;
    p->vo->dwidth = s.width;
    p->vo->dheight = s.height;
    resize(p);

    MP_MSG(p, MSGL_V, "Width: %f, Height: %f ### Triggered event\n", s.width, s.height);

    vo_event(p->vo, VO_EVENT_RESIZE | VO_EVENT_EXPOSE);
    // moltenvk_reconfig(_ra_ctx);
}

@end



static void moltenvk_uninit(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    p->layer.delegate = nil;
    p->delegate.ra_ctx = nil;
    p->delegate = nil;
    ra_vk_ctx_uninit(ctx);
    mpvk_uninit(&p->vk);
}

static bool moltenvk_init(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv = talloc_zero(ctx, struct priv);
    struct mpvk_ctx *vk = &p->vk;
    int msgl = ctx->opts.probing ? MSGL_V : MSGL_ERR;

    if (ctx->vo->opts->WinID == -1) {
        MP_MSG(ctx, msgl, "WinID missing\n");
        goto fail;
    }

    if (!mpvk_init(vk, ctx, VK_EXT_METAL_SURFACE_EXTENSION_NAME))
        goto fail;

    p->layer = (__bridge CAMetalLayer *)(intptr_t)ctx->vo->opts->WinID;
    VkMetalSurfaceCreateInfoEXT info = {
         .sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT,
         .pLayer = p->layer,
    };

    struct ra_vk_ctx_params params = {0};

    VkInstance inst = vk->vkinst->instance;
    VkResult res = vkCreateMetalSurfaceEXT(inst, &info, NULL, &vk->surface);
    if (res != VK_SUCCESS) {
        MP_MSG(ctx, msgl, "Failed creating MoltenVK surface\n");
        goto fail;
    }

    if (!ra_vk_ctx_init(ctx, vk, params, VK_PRESENT_MODE_FIFO_KHR))
        goto fail;

    p->delegate = [[MetalLayerDelegate alloc] initWithContext: ctx];
    p->layer.delegate = p->delegate;

    return true;
fail:
    moltenvk_uninit(ctx);
    return false;
}

static bool moltenvk_reconfig(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    CAMetalLayer *metalLayer = (CAMetalLayer *)p->layer;
    CGSize s = metalLayer.drawableSize;
    MP_MSG(ctx, MSGL_V, "Width: %d, Height: %d ### called moltenvk_reconfig\n", s.width, s.height);
    // ra_vk_ctx_resize(ctx, s.width, s.height);
    // MP_MSG(ctx, MSGL_V, "### called moltenvk_reconfig\n");
    return true;
}

static bool resize(struct ra_ctx *ctx)
{
    MP_MSG(ctx, MSGL_V, "Width: %d, Height: %d ### called resize function\n", ctx->vo->dwidth, ctx->vo->dheight);
    return ra_vk_ctx_resize(ctx, ctx->vo->dwidth, ctx->vo->dheight);
}

static int moltenvk_control(struct ra_ctx *ctx, int *events, int request, void *arg)
{
    struct priv *p = ctx->priv;

    // MP_MSG(ctx, MSGL_V, "Width: %d, Height: %d ### Some event: %d\n", ctx->vo->dwidth, ctx->vo->dheight, events);

    if (*events & VO_EVENT_RESIZE) {
        MP_MSG(ctx, MSGL_V, "Width: %d, Height: %d ### Resize event\n", ctx->vo->dwidth, ctx->vo->dheight);
        if (!resize(ctx))
            return VO_ERROR;
    }

    return VO_NOTIMPL;
}

const struct ra_ctx_fns ra_ctx_vulkan_moltenvk = {
    .type           = "vulkan",
    .name           = "moltenvk",
    .reconfig       = moltenvk_reconfig,
    .control        = moltenvk_control,
    .init           = moltenvk_init,
    .uninit         = moltenvk_uninit,
};
