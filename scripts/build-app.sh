#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=scripts/versions.env
source "$root/scripts/versions.env"
engine_filename="ungoogled-chromium_${engine_version}-${engine_revision}_macos.dmg"
engine_url="https://github.com/adryfish/fingerprint-chromium/releases/download/${engine_version}/${engine_filename}"
passkey_filename="passkey-box-extension-anybrowser-v${passkey_version}.zip"
passkey_url="https://github.com/riba2534/passkey-box/releases/download/v${passkey_version}/${passkey_filename}"

fail() {
    printf 'AnyBrowser build: %s\n' "$*" >&2
    exit 1
}

[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || fail "use an Apple Silicon Mac and a native shell"
cd "$root"

cache_dir="${ANYBROWSER_ENGINE_CACHE:-$root/.build/engine-cache}"
[[ ! -L "$root/dist" ]] || fail "dist must be a local output directory"
mkdir -p "$cache_dir" "$root/.build" "$root/dist"
cache_dir="$(cd "$cache_dir" && pwd -P)"
dmg="$cache_dir/$engine_filename"
passkey_zip="$cache_dir/$passkey_filename"
output="$root/dist/AnyBrowser.app"

lock="$root/.build/anybrowser-package.lock"
mkdir "$lock" 2>/dev/null || fail "another packaging build is active ($lock)"
staging=''
download=''
mount_dir=''

cleanup() {
    local result=$?
    trap - EXIT
    local can_remove_stage=true
    if [[ -d "$mount_dir" && "$(/usr/bin/stat -f %d "$mount_dir")" != "$(/usr/bin/stat -f %d "$staging")" ]]; then
        if ! /usr/bin/hdiutil detach "$mount_dir" -quiet; then
            printf 'AnyBrowser build: could not detach %s\n' "$mount_dir" >&2
            can_remove_stage=false
            result=1
        fi
    fi
    if [[ -n "$download" && -e "$download" ]]; then /bin/rm -- "$download" || result=1; fi
    if [[ "$can_remove_stage" == true && -n "$staging" ]]; then /bin/rm -r -- "$staging" || result=1; fi
    /bin/rmdir -- "$lock" || result=1
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

digest_matches() {
    [[ -f "$1" ]] &&
        [[ "$(/usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}')" == "$2" ]]
}

prepare_asset() {
    local destination="$1" digest="$2" url="$3" title="$4"
    if digest_matches "$destination" "$digest"; then return; fi
    printf 'Downloading %s…\n' "$title"
    download="$(mktemp "$cache_dir/.release-asset.XXXXXX")"
    /usr/bin/curl --fail --location --retry 3 --connect-timeout 15 \
        --proto '=https' --proto-redir '=https' --silent --show-error \
        --output "$download" "$url"
    digest_matches "$download" "$digest" || fail "downloaded $title SHA-256 differs from the pinned digest"
    /bin/mv -f -- "$download" "$destination"
    download=''
}

prepare_asset "$dmg" "$engine_sha256" "$engine_url" "Fingerprint Chromium $engine_version for macOS ARM64"
prepare_asset "$passkey_zip" "$passkey_sha256" "$passkey_url" "Passkey Box $passkey_version for AnyBrowser"

printf 'Building AnyBrowser for ARM64…\n'
# shellcheck source=scripts/toolchain.sh
source "$root/scripts/toolchain.sh"
select_swiftui_sdk || fail "no installed SDK can compile SwiftUI; install Xcode"
swift build --configuration release --arch arm64 --product AnyBrowser
bin_path="$(swift build --configuration release --arch arm64 --show-bin-path)"
[[ "$(/usr/bin/lipo -archs "$bin_path/AnyBrowser")" == arm64 ]] || fail "SwiftPM did not produce an ARM64 executable"

staging="$(mktemp -d "$root/dist/.anybrowser-stage.XXXXXX")"
mount_dir="$staging/engine"
bundle="$staging/AnyBrowser.app"
contents="$bundle/Contents"
embedded="$contents/Frameworks/Chromium.app"
mkdir -p "$mount_dir" "$contents/MacOS" "$contents/Frameworks" "$contents/Resources"
printf 'Embedding Fingerprint Chromium %s…\n' "$engine_version"
/usr/bin/hdiutil attach "$dmg" -readonly -nobrowse -noautoopen -mountpoint "$mount_dir" -quiet ||
    fail "could not attach the verified browser image"
upstream="$mount_dir/Chromium.app"
engine_plist="$upstream/Contents/Info.plist"
bundle_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$2"; }
[[ "$(bundle_value CFBundleShortVersionString "$engine_plist")" == "$engine_version" ]] || fail "unexpected browser version"
[[ "$(bundle_value CFBundleExecutable "$engine_plist")" == Chromium ]] || fail "unexpected browser executable"
[[ "$(/usr/bin/lipo -archs "$upstream/Contents/MacOS/Chromium")" == arm64 ]] || fail "browser asset is not ARM64"

# Retain the upstream code and signature. HFS Finder metadata is excluded from the app bundle.
/usr/bin/ditto --norsrc --noextattr "$upstream" "$embedded"
/usr/bin/hdiutil detach "$mount_dir" -quiet || fail "could not detach the upstream browser image"
/usr/bin/codesign --verify --deep --strict "$embedded"
/bin/cp "$root/Resources/Info.plist" "$contents/Info.plist"
/bin/cp "$root/Resources/FingerprintChromium.LICENSE.txt" "$contents/Resources/"
printf 'Embedding Passkey Box %s…\n' "$passkey_version"
staged_zip="$staging/$passkey_filename"
extension="$contents/Resources/Extensions/PasskeyBox"
/bin/cp "$passkey_zip" "$staged_zip"
digest_matches "$staged_zip" "$passkey_sha256" || fail "staged Passkey Box ZIP differs from the pinned digest"
mkdir -p "$extension"
/usr/bin/unzip -q "$staged_zip" -d "$extension"
for entry in manifest.json LICENSE THIRD-PARTY-NOTICES.txt background.js content.js inject.js \
    options.html options.js popup.html popup.js ui.css; do
    [[ -f "$extension/$entry" && ! -L "$extension/$entry" ]] || fail "missing Passkey Box file: $entry"
done
manifest="$extension/manifest.json"
manifest_value() { /usr/bin/plutil -extract "$1" raw -o - "$manifest"; }
[[ "$(manifest_value name)" == "Passkey Box" &&
    "$(manifest_value manifest_version)" == 3 &&
    "$(manifest_value version)" == "$passkey_version" ]] || fail "unexpected Passkey Box manifest"
embedded_id="$(manifest_value key | /usr/bin/base64 -D | /usr/bin/shasum -a 256 |
    /usr/bin/cut -c 1-32 | LC_ALL=C /usr/bin/tr '0123456789abcdef' 'abcdefghijklmnop')" ||
    fail "could not verify the Passkey Box manifest key"
[[ "$embedded_id" == "$passkey_id" ]] || fail "unexpected Passkey Box extension ID"
iconset="$staging/AnyBrowser.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$root/Resources/AnyBrowser.png" \
        --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    /usr/bin/sips -z "$retina_size" "$retina_size" "$root/Resources/AnyBrowser.png" \
        --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset" -o "$contents/Resources/AnyBrowser.icns"
/usr/bin/install -m 755 "$bin_path/AnyBrowser" "$contents/MacOS/AnyBrowser"
/usr/bin/plutil -insert AnyBrowserEngineVersion -string "$engine_version" "$contents/Info.plist"
/usr/bin/plutil -insert AnyBrowserEngineSHA256 -string "$engine_sha256" "$contents/Info.plist"
/usr/bin/plutil -insert AnyBrowserPasskeyBoxVersion -string "$passkey_version" "$contents/Info.plist"
/usr/bin/plutil -insert AnyBrowserPasskeyBoxSHA256 -string "$passkey_sha256" "$contents/Info.plist"
/usr/bin/plutil -insert AnyBrowserPasskeyBoxExtensionID -string "$passkey_id" "$contents/Info.plist"
/usr/bin/plutil -lint "$contents/Info.plist"
/usr/bin/codesign --force --sign - --timestamp=none "$bundle"
/usr/bin/codesign --verify --deep --strict "$bundle"

if [[ -e "$output" || -L "$output" ]]; then
    [[ ! -L "$output" && "$(bundle_value CFBundleIdentifier "$output/Contents/Info.plist")" == cn.riba2534.anybrowser ]] ||
        fail "the output path belongs to a different application"
    /bin/rm -r -- "$output"
fi
/bin/mv -- "$bundle" "$output"
printf 'Built %s\n' "$output"
