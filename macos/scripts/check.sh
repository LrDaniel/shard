#!/bin/zsh

set -euo pipefail

script_directory="${0:A:h}"
macos_directory="${script_directory:h}"
repository_directory="${macos_directory:h}"

CLANG_MODULE_CACHE_PATH="${macos_directory}/.build/clang-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="${macos_directory}/.build/swiftpm-cache" \
swift test --package-path "${macos_directory}" --disable-sandbox

npm test --prefix "${repository_directory}/sidecar"
