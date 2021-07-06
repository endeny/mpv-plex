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

#include "config.h"
#include "ao.h"
#include "internal.h"
#include "audio/format.h"
#include "osdep/timer.h"
#include "options/m_option.h"
#include "common/msg.h"
#include "ao_coreaudio_utils.h"
#include "ao_coreaudio_chmap.h"

#import <CoreAudio/CoreAudioTypes.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <mach/mach_time.h>

#if TARGET_OS_IPHONE
#define HAVE_AVAUDIOSESSION
#endif

struct priv {
    dispatch_queue_t queue;
    CMFormatDescriptionRef desc;
    AVSampleBufferAudioRenderer *renderer;
    AVSampleBufferRenderSynchronizer *synchronizer;
    int64_t enqueued;
};

static bool enqueue_frames(struct ao *ao)
{
    struct priv *p = ao->priv;
    int frames = ao->buffer / 4;
    int size = frames * ao->sstride;
    OSStatus err;

    CMSampleBufferRef sBuf = NULL;
    CMBlockBufferRef bBuf = NULL;

    int64_t playhead = CMTimeGetSeconds([p->synchronizer currentTime]) * 1e6;
    int64_t end = mp_time_us();
    end += ca_frames_to_us(ao, frames);
    end += MPMAX(0, ca_frames_to_us(ao, p->enqueued) - playhead);
    void *buf = calloc(size, 1);
    int samples = ao_read_data(ao, &buf, frames, 0 /*unused*/);

    if (samples <= 0) {
        free(buf);
        return false;
    }

    int bufsize = samples * ao->sstride;
    err = CMBlockBufferCreateWithMemoryBlock(NULL,    // structureAllocator
                                             buf,     // memoryBlock
                                             bufsize, // blockLength
                                             0,       // blockAllocator
                                             NULL,    // customBlockSource
                                             0,       // offsetToData
                                             bufsize, // dataLength
                                             0,       // flags
                                             &bBuf);
    CHECK_CA_WARN("failed to create CMBlockBuffer");

    p->enqueued += samples;
    CMSampleTimingInfo timing = {
        CMTimeMake(1, ao->samplerate),
        CMTimeMake(p->enqueued, ao->samplerate),
        kCMTimeInvalid
    };
    err = CMSampleBufferCreate(NULL,    // allocator
                               bBuf,    // dataBuffer
                               true,    // dataReady
                               NULL,    // makeDataReadyCallback
                               NULL,    // makeDataReadyRefcon
                               p->desc, // formatDescription
                               bufsize, // numSamples
                               1,       // numSampleTimingEntries
                               &timing, // sampleTimingArray
                               0,       // numSampleSizeEntries
                               NULL,    // sampleSizeArray
                               &sBuf);
    CHECK_CA_WARN("failed to create CMSampleBuffer");

    [p->renderer enqueueSampleBuffer:sBuf];

    CFRelease(sBuf);
    CFRelease(bBuf);
    return true;
}

static void play(struct ao *ao)
{
    struct priv *p = ao->priv;

    [p->renderer requestMediaDataWhenReadyOnQueue:p->queue usingBlock:^{
        while ([p->renderer isReadyForMoreMediaData]) {
            if (!enqueue_frames(ao))
                break;
        }
    }];
}

static bool init_renderer(struct ao *ao)
{
    struct priv *p = ao->priv;
    OSStatus err;
    AudioStreamBasicDescription asbd;

#ifdef HAVE_AVAUDIOSESSION
    AVAudioSession *instance = AVAudioSession.sharedInstance;
    AVAudioSessionPortDescription *port = nil;
    NSInteger maxChannels = instance.maximumOutputNumberOfChannels;
    NSInteger prefChannels = MIN(maxChannels, ao->channels.num);

    [instance
        setCategory:AVAudioSessionCategoryPlayback
        mode:AVAudioSessionModeMoviePlayback
        routeSharingPolicy:AVAudioSessionRouteSharingPolicyLongForm
        options:0
        error:nil];
    [instance setActive:YES error:nil];
    [instance setPreferredOutputNumberOfChannels:prefChannels error:nil];

    if (af_fmt_is_spdif(ao->format) || instance.outputNumberOfChannels <= 2) {
        ao->channels = (struct mp_chmap)MP_CHMAP_INIT_STEREO;
    } else {
        port = instance.currentRoute.outputs.firstObject;
        if (port.channels.count == 2 &&
            port.portType == AVAudioSessionPortHDMI) {
            // Special case when using an HDMI adapter. The iOS device will
            // perform SPDIF conversion for us, so send all available channels
            // using the AC3 mapping.
            ao->channels = (struct mp_chmap)MP_CHMAP6(FL, FC, FR, SL, SR, LFE);
        } else {
            ao->channels.num = (uint8_t)port.channels.count;
            for (AVAudioSessionChannelDescription *ch in port.channels) {
              ao->channels.speaker[ch.channelNumber - 1] =
                  ca_label_to_mp_speaker_id(ch.channelLabel);
            }
        }
    }
#else
    // todo: support multi-channel on macOS
    ao->channels = (struct mp_chmap)MP_CHMAP_INIT_STEREO;
#endif

    // todo: add support for planar formats to play()
    ao->format = af_fmt_from_planar(ao->format);
    ca_fill_asbd(ao, &asbd);
    err = CMAudioFormatDescriptionCreate(NULL,
                                         &asbd,
                                         0, NULL,
                                         0, NULL,
                                         NULL,
                                         &p->desc);
    CHECK_CA_ERROR_L(coreaudio_error,
                     "unable to create format description");

    return true;

coreaudio_error:
    return false;
}

static void pause_no_flush(struct ao *ao)
{
    struct priv *p = ao->priv;
    dispatch_sync(p->queue, ^{
        [p->synchronizer setRate:0.0];
        [p->renderer stopRequestingMediaData];
    });
}

static void stop(struct ao *ao)
{
    struct priv *p = ao->priv;
    dispatch_sync(p->queue, ^{
        [p->synchronizer setRate:0.0 time:CMTimeMake(0, ao->samplerate)];
        [p->renderer stopRequestingMediaData];
        [p->renderer flush];
        p->enqueued = 0;
    });
}

static void start(struct ao *ao)
{
    struct priv *p = ao->priv;
    dispatch_async(p->queue, ^{
        int n = 0;
        while (enqueue_frames(ao)) n++;
        play(ao);
        [p->synchronizer setRate:1.0];
    });
}

static void uninit(struct ao *ao)
{
    struct priv *p = ao->priv;

    p->renderer = nil;
    p->synchronizer = nil;
    if (p->desc) {
        CFRelease(p->desc);
        p->desc = NULL;
    }

#ifdef HAVE_AVAUDIOSESSION
    [AVAudioSession.sharedInstance
        setActive:NO
        withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
        error:nil];
#endif
}

static int init(struct ao *ao)
{
    struct priv *p = ao->priv;

    if (@available(tvOS 12.0, iOS 12.0, macOS 10.14, *)) {
        // supported, fall through
    } else {
        MP_FATAL(ao, "unsupported on this OS version\n");
        return CONTROL_ERROR;
    }

    p->queue = dispatch_queue_create("mpv audio renderer", NULL);
    p->renderer = [AVSampleBufferAudioRenderer new];
    p->synchronizer = [AVSampleBufferRenderSynchronizer new];
    [p->synchronizer addRenderer:p->renderer];

    if (!init_renderer(ao))
        return CONTROL_ERROR;

    return CONTROL_OK;
}

static double get_delay(struct ao *ao)
{
    struct priv *p = ao->priv;

    int64_t playhead = CMTimeGetSeconds([p->synchronizer currentTime]) * 1e6;
    double delay = (ca_frames_to_us(ao, p->enqueued) - playhead) / (double)(1e6);
    return delay;
}

static void get_state(struct ao *ao, struct mp_pcm_state *state)
{
    state->delay = get_delay(ao);
}

#define OPT_BASE_STRUCT struct priv

const struct ao_driver audio_out_avfoundation = {
    .description    = "AVFoundation AVSampleBufferAudioRenderer (macOS/iOS)",
    .name           = "avfoundation",
    .uninit         = uninit,
    .init           = init,
    .reset          = stop,
    .start          = start,
    .get_state      = get_state,
    .priv_size      = sizeof(struct priv),
};
