# Local iOS development

These instructions are for local development and iteration of the mpv library.
In order to support this flow we have a new script called `local_build.py` that can
build almost the same way the CI can and produce a xcframework without having to go
through the CI.

## Requirements

Python3 is a requirement. Make sure your `python` points to `python3` or follow the steps
below invoking `python3` instead.

You need the `grabdeps` python script that we use for PMS development. The instructions
for this can be found here: https://build-tools-docs.plex.bz/pms/python/#macos-and-linux

But the TLDR is:

```
mkdir $HOME/.pip
cat >> $HOME/.pip/pip.conf << EOF
[global]
extra-index-url = https://pypi-read:eyJ2ZXIiOiIyIiwidHlwIjoiSldUIiwiYWxnIjoiUlMyNTYiLCJraWQiOiIxY0U1RG05ZU5EZ3hjS0FqQUQwenhnN3lBQUdYaWxnSEV3djByZUZnZ2dVIn0.eyJzdWIiOiJqZi1hcnRpZmFjdG9yeUBlNzQ5NTM5Ny0yMWRmLTRhYzEtYjRlNC0xZjFjM2U5NjhmNGNcL3VzZXJzXC9weXBpLXJlYWQiLCJzY3AiOiJtZW1iZXItb2YtZ3JvdXBzOnB5cGktcmVhZCBhcGk6KiIsImF1ZCI6ImpmLWFydGlmYWN0b3J5QGU3NDk1Mzk3LTIxZGYtNGFjMS1iNGU0LTFmMWMzZTk2OGY0YyIsImlzcyI6ImpmLWFydGlmYWN0b3J5QGU3NDk1Mzk3LTIxZGYtNGFjMS1iNGU0LTFmMWMzZTk2OGY0YyIsImlhdCI6MTUyMDQyNTQ4MSwianRpIjoiYTE5ZDNkZmEtNDliYy00NWU1LTgyYjctYzZlMmY1N2FlYjcxIn0.PyOkZyPQ6Grvw8XOdEGk7bCoTrF2W9PNoub8O6PzNg1rkrsVyDXJThkDOCZ6kgzXBiTWRDGG6FTh9q2Sp69jj7bqWyDS5koItQvMB2uSrOorXOVgWfTRLac2ldphgRXfcnMRShKUZ9_VkG54j2RpzA4dh_9sWb4rjXFaljH22YRvx9THxjMCPj8wPVLolZnITAIBOn0j87DU0ejFX7J-JSxM2ntRWfFt3CNjNSst8V8MJIUDepAKeEywub782hLmJnOo9x4RTuiBosIGmdPSIc7EuUP4F2qHfgWRZ6r65iEw2TdGiTegcIztauydluDcpk6fA1C5Wmj-RYxmoLiS1w@artifactory.plex.bz/artifactory/api/pypi/pypi-tools-and-cache/simple
EOF
python3 -m pip install grabdeps
```

## `local_build.py` usage

Local build takes a few arguments, to get the full list use `./local_build.py --help`. The important ones are:

* `--targets / -t` - This takes a list of targets to build, the default is `ios-arm64` if you just want to iterate on that one. Other targets are listed in the help output.
* `--clean / -c` - This removes the build dir and makes a clean build. Might be useful if you do larger changes.
* `--build / -b` - Only builds, no configure and other inital setups. This is meant to be used for the faster iteration build, test loop.

## Example usage

Let's build for iOS and tvOS arm64 this way:

`./local_build.py -t ios-arm64,tvos-arm64`

Let that run and you'll have a `PlexMPV.xcframework` in the `build` subdirectory.

Now we do some changes to the sources and we want to just build:

`./local_build.py -t ios-arm64,tvos-arm64 -b`

This will be faster since it won't run configure and similar operations.


Let's build a clean xcframework with all targets:

`./local_build.py -c -a`
