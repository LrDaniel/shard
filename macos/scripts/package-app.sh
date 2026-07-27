#!/bin/zsh

set -euo pipefail

script_directory="${0:A:h}"
macos_directory="${script_directory:h}"
repository_directory="${macos_directory:h}"
distribution_directory="${macos_directory}/dist"
application="${distribution_directory}/Shard.app"
previous_application="${distribution_directory}/Shard.previous.app"
contents="${application}/Contents"
resources="${contents}/Resources"
info_plist="${macos_directory}/Resources/Info.plist"
app_version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${info_plist}")"
signing_identity="${SHARD_SIGNING_IDENTITY:-}"
node_binary="${SHARD_NODE_BINARY:-${SHARD_NODE_BINARY:-}}"
asset_working_directory="$(mktemp -d "${TMPDIR:-/tmp}/shard-assets.XXXXXX")"

if [[ -z "${node_binary}" ]]; then
    node_24_candidates=("${HOME}"/.nvm/versions/node/v24*/bin/node(N))
    if (( ${#node_24_candidates[@]} > 0 )); then
        node_binary="${node_24_candidates[1]}"
    else
        node_binary="$(command -v node || true)"
    fi
fi

cleanup() {
    rm -rf "${asset_working_directory}"
}
trap cleanup EXIT

if [[ -z "${node_binary}" || ! -x "${node_binary}" ]]; then
    print -u2 "Set SHARD_NODE_BINARY to an ARM64 Node.js 24 executable."
    exit 1
fi

if [[ -z "${signing_identity}" ]]; then
    signing_identity="$(
        security find-identity -v -p codesigning |
            sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' |
            head -n 1
    )"
fi
signing_identity="${signing_identity:--}"

node_major="$("${node_binary}" -p 'process.versions.node.split(".")[0]')"
if (( node_major < 24 )); then
    print -u2 "Packaging requires Node.js 24 or newer; found $("${node_binary}" --version)."
    exit 1
fi

if ! file "${node_binary}" | grep -q "arm64"; then
    print -u2 "The bundled Node.js runtime must contain an arm64 executable."
    exit 1
fi

mkdir -p "${distribution_directory}"
if [[ -e "${application}" ]]; then
    if [[ -e "${previous_application}" ]]; then
        rm -rf "${previous_application}"
    fi
    mv "${application}" "${previous_application}"
fi

CLANG_MODULE_CACHE_PATH="${macos_directory}/.build/clang-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="${macos_directory}/.build/swiftpm-cache" \
swift build \
    --package-path "${macos_directory}" \
    --product Shard \
    --configuration release \
    --arch arm64 \
    --disable-sandbox

PATH="${node_binary:h}:${PATH}" \
    npm ci --prefix "${repository_directory}/sidecar" --omit=dev

mkdir -p \
    "${contents}/MacOS" \
    "${resources}/runtime" \
    "${resources}/sidecar"
cp "${macos_directory}/.build/arm64-apple-macosx/release/Shard" "${contents}/MacOS/Shard"
cp "${info_plist}" "${contents}/Info.plist"
cp "${node_binary}" "${resources}/runtime/node"
cp "${repository_directory}/sidecar/index.js" "${resources}/sidecar/index.js"
cp "${repository_directory}/sidecar/package.json" "${resources}/sidecar/package.json"
cp "${repository_directory}/sidecar/package-lock.json" "${resources}/sidecar/package-lock.json"
cp -R "${repository_directory}/sidecar/node_modules" "${resources}/sidecar/node_modules"
find "${resources}/sidecar/node_modules" -type d -name .bin -prune \
    -exec rm -rf {} +
xcrun actool "${macos_directory}/Resources/Assets.xcassets" \
    --compile "${resources}" \
    --platform macosx \
    --minimum-deployment-target 12.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "${asset_working_directory}/asset-info.plist"

chmod 755 "${contents}/MacOS/Shard" "${resources}/runtime/node"
if [[ "${signing_identity}" == "-" ]]; then
    codesign --force --deep --sign - "${application}"
    print "Warning: no Developer ID Application certificate found; using an ad-hoc signature."
else
    codesign \
        --force \
        --deep \
        --options runtime \
        --timestamp \
        --sign "${signing_identity}" \
        "${application}"
fi

while IFS= read -r executable; do
    architecture="$(file "${executable}")"
    if [[ "${architecture}" == *"Mach-O"* && "${architecture}" != *"arm64"* ]]; then
        print -u2 "Non-arm64 executable found: ${executable}"
        exit 1
    fi
done < <(find "${application}" -type f -perm -111)

dmg="${distribution_directory}/Shard-${app_version}-arm64.dmg"
hdiutil create \
    -volname "Shard" \
    -srcfolder "${application}" \
    -ov \
    -format UDZO \
    "${dmg}"

if [[ "${signing_identity}" != "-" ]]; then
    codesign --force --timestamp --sign "${signing_identity}" "${dmg}"
fi

rm -rf "${previous_application}"
print "Created ${application}"
print "Created ${dmg}"
