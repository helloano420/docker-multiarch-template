#!/bin/sh
# Prints the architecture this image was built for. The workflow's test step
# asserts this matches the native runner, which proves the platform split works.
set -eu

printf 'hello from linux/%s\n' "$(uname -m)"
printf 'IMAGE_ARCH baked at build time: %s\n' "$(cat /etc/image-arch)"
