#!/usr/bin/env python3

import argparse
import sys
import os
import subprocess
from pathlib import Path
from typing import Dict, List
from pprint import pprint
from multiprocessing import cpu_count
from shutil import copytree, rmtree, copy

ALL_TARGETS = ("ios-arm64", "iossim-x86_64", "tvos-arm64", "tvossim-x86_64")
BUILD_TARGET = {
  "ios-arm64": "arm64-apple-darwin-ios",
  "iossim-x86_64": "x86_64-apple-darwin-iossim",
  "tvos-arm64": "arm64-apple-darwin-tvos",
  "tvossim-x86_64": "x86_64-apple-darwin-tvossim",
}


class LocalBuilder:
  def __init__(self) -> None:
    self.parse_args()
    self.root = Path(__file__).resolve().parent
    self.output = Path(self.args.output_dir).resolve()

  def parse_args(self) -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
      "-r",
      "--release",
      default=False,
      action="store_true",
      help="Make a release build (debug are default)",
    )
    parser.add_argument(
      "-t",
      "--targets",
      default="ios-arm64",
      help=f"Which targets to build ({', '.join(BUILD_TARGET)}, all) comma-separated",
    )
    parser.add_argument(
      "-a", "--all", default=False, action="store_true", help="Short for --target=all"
    )
    parser.add_argument("-o", "--output-dir", default="build", help="output directory")
    parser.add_argument(
      "-b", "--build", action="store_true", help="Just build - skip all other steps"
    )

    parser.add_argument("-v", "--verbose", action="store_true", help="Pass -v to waf")
    parser.add_argument(
      "-j",
      "--jobs",
      default=cpu_count(),
      help=f"Number of jobs passed to waf build (default: {cpu_count()})",
    )
    parser.add_argument(
      "-c", "--clean", action="store_true", default=False, help="Clean before build"
    )

    self.args = parser.parse_args()

  def grab_toolchain(self) -> None:
    subprocess.run(["plex-toolchain", "fetch"], check=True)

  def grab_deps(self) -> None:
    subprocess.run(["gd2"], check=True)

  def bootstrap(self) -> None:
    subprocess.run(["./bootstrap.py"], check=True)

  def do(self) -> None:

    if self.args.clean and self.args.build:
      raise RuntimeError("Can't combine clean with build.")

    if self.args.clean:
      try:
        rmtree(self.output)
      except FileNotFoundError:
        pass

    if not self.args.build:
      self.grab_toolchain()
      self.grab_deps()
      self.bootstrap()

    targets = None
    if "," in self.args.targets:
      targets = self.args.targets.split(",")
    else:
      targets = [self.args.targets]

    if self.args.all:
      targets = ALL_TARGETS

    for target in targets:
      self.build_target(target)

    self.create_xcframework(targets)

  def create_xcframework(self, targets: List[str]) -> None:
    xcframework = self.output / "PlexMPV.xcframework"
    if xcframework.is_dir():
      rmtree(xcframework)

    cmd = ["xcrun", "xcodebuild", "-create-xcframework"]
    for target in targets:
      cmd += [
        "-framework",
        str(self.build_dir(target) / "PlexMPV.framework"),
        "-debug-symbols",
        str(self.build_dir(target) / "PlexMPV.dSYM"),
      ]

    cmd += [
      "-output",
      str(xcframework),
    ]

    print(f"> {' '.join(cmd)}")
    subprocess.run(cmd, check=True)

  def build_dir(self, target) -> Path:
    return self.output / target

  def configure_args(self, target: str) -> List[str]:
    args = [
      "--enable-libmpv-shared",
      "--disable-cplayer",
      "--disable-macos-touchbar",
      "--disable-swift",
      "--disable-manpage-build",
      "--enable-lgpl",
      "--enable-ios-gl",
      "--enable-gl",
    ]

    if not self.args.release:
      args.append("--disable-optimize")

    return args

  def deps_dir(self, target: str) -> Path:
    return self.root / "dependencies" / "ios-client" / BUILD_TARGET[target]

  def ld_flags(self, target: str) -> str:
    libdirs = []
    for f in self.deps_dir(target).iterdir():
      libdir = f / "lib"
      if libdir.is_dir():
        libdirs.append(libdir)

    ldflags = [f"-L{lib}" for lib in libdirs]
    for fr in ("CoreGraphics", "CoreText", "CoreVideo", "AVFoundation", "OpenGLES"):
      ldflags.append("-framework")
      ldflags.append(fr)

    ldflags += ["-lpng", "-lz", "-lexpat", "-lbz2"]

    ldflags.append(
      f"-Wl,-cache_path_lto,{self.root / 'lto_cache'}"
    )
    ldflags.append("-Wl,")
    ldflags.append(f"-Wl,-object_path_lto,{self.build_dir(target) / 'lto_temp'}")
    ldflags.append(f"-Wl,-dead_strip")

    return " ".join(ldflags)

  def pkg_config_path(self, target: str) -> str:
    target_deps = self.deps_dir(target)
    config_paths = []
    for f in target_deps.iterdir():
      if f.is_dir():
        config_paths.append(str(f / "lib" / "pkgconfig"))

    return ":".join(config_paths)

  def build_env(self, target: str) -> Dict:

    wrapper_flags = (
      "-miphoneos-version-min=12.4" if "ios" in target else "-mtvos-version-min=12.4"
    )

    debug_flags = ""
    # We need to have bitcode for tvOS in order to link.
    if "tvos" in target:
      wrapper_flags += " -fembed-bitcode"
    else:
      # And these flags are not compatible with bitcode of course.
      debug_flags = "-gdwarf-aranges -ffunction-sections -fdata-sections"

    environment = {
      "CC": f"{BUILD_TARGET[target]}-clang",
      "CXX": f"{BUILD_TARGET[target]}-clang++",
      "PLEX_WRAPPER_FLAGS": wrapper_flags,
      "PKG_CONFIG_PATH": self.pkg_config_path(target),
      "LDFLAGS": self.ld_flags(target),
      "CFLAGS": f"-Og -g2 -Xclang -debug-info-kind=limited -fno-omit-frame-pointer {debug_flags}",
    }

    return environment

  def handle_debug(self, target: str) -> None:
    # dump debug to dSYM
    dylib_path = self.build_dir(target) / "PlexMPV.framework/PlexMPV"
    if not dylib_path.is_file():
      raise RuntimeError(f"Failed to find {dylib_path}")

    subprocess.run(
      ["xcrun", "dsymutil", "-o", self.build_dir(target) / "PlexMPV.dSYM", dylib_path]
    )

    # strip it
    subprocess.run(["strip", "-STx", dylib_path])

  # This is a pretty sad function that takes the headers from mpv and
  # ffmpeg and flatterns them. I.e. puts them all in the same directory
  # The reason for this is that a framework can't have several subdirectories
  # within the Headers directory. So we need to edit the headers and
  # put them all in the same dir.
  #
  def mistreat_headers(self, target: str, dest: Path) -> None:
    src_inc = self.deps_dir(target) / "ffmpeg" / "include"

    for header in src_inc.glob("**/*.h"):
      # This might need more entries here, but frankly I was
      # to lazy to do this properly.
      #
      replace_dirs = ("libavcodec", "libavutil", "libavformat")
      dst_hdr = dest / header.name

      hdrdata = header.read_text("utf-8")
      for replace in replace_dirs:
        hdrdata = hdrdata.replace(f"{replace}/", "")

      # we expect version.h to be overwritten - but we
      # want to catch any other overwrites.
      if dst_hdr.is_file() and dst_hdr.name != "version.h":
        raise RuntimeError(f"WARNING overwriting: {dst_hdr.name}!")

      dst_hdr.write_text(hdrdata, "utf-8")
      print(f"Copied {header.name}")

  def create_framework(self, target: str) -> None:
    framework = self.build_dir(target) / "PlexMPV.framework"
    if framework.is_dir():
      rmtree(framework)
    framework.mkdir(parents=True)

    dylib = self.build_dir(target) / "libmpv.dylib"
    copy(dylib, framework / "PlexMPV")

    subprocess.run(
      [
        "install_name_tool",
        "-id",
        "@rpath/PlexMPV.framework/PlexMPV",
        framework / "PlexMPV",
      ],
      check=True,
    )

    info_plist = self.root / "Framework-Info.plist"
    info_data = info_plist.read_text()
    info_data = info_data.replace("@VERSION@", "1.0")
    info_data = info_data.replace("@DEPLOYMENT_TARGET@", "12.4")

    (framework / "Info.plist").write_text(info_data)

    header_dir = framework / "Headers"
    header_dir.mkdir()

    for file in (self.root / "libmpv").iterdir():
      if file.name.endswith(".h"):
        copy(file, header_dir)

    self.mistreat_headers(target, header_dir)

  def build_target(self, target: str) -> None:
    if not target in ALL_TARGETS:
      print(
        f"Don't know how to build target: {target} - possible targets are: {', '.join(ALL_TARGETS)}"
      )
      sys.exit(1)
    print(f"Building target: {target}")

    conf_args = self.configure_args(target)
    if self.args.verbose:
      conf_args.append("-v")

    env = os.environ.copy()
    env.update(self.build_env(target))
    pprint(env)

    if not self.args.build:
      subprocess.run(
        ["plexec", "./waf", "configure", "-o", self.build_dir(target)] + conf_args,
        env=env,
        check=True,
      )


    dylib = self.build_dir(target) / "libmpv.dylib"
    if dylib.is_file:
      os.remove(dylib)

    build_args = []
    if self.args.verbose:
      build_args.append("-v")

    build_args.append(f"-j{self.args.jobs}")
    waf_path = str(self.root / "waf")
    cmd = ["plexec", waf_path, "build"] + build_args
    print(f"> {' '.join(cmd)}")

    subprocess.run(cmd, env=env, cwd=self.build_dir(target), check=True)

    self.create_framework(target)
    self.handle_debug(target)


if __name__ == "__main__":
  lb = LocalBuilder()
  lb.do()
