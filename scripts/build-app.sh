#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
engine_version=148.0.7778.215
engine_sha256=b72f091e2e1a7583eed389c4b8e3534ed355e568af8c8bbf8fc30a25e23ca679
engine_filename="ungoogled-chromium_${engine_version}-1.1_macos.dmg"
engine_url="https://github.com/adryfish/fingerprint-chromium/releases/download/${engine_version}/${engine_filename}"

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
        [[ "$(/usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}')" == "$engine_sha256" ]]
}

if ! digest_matches "$dmg"; then
    printf 'Downloading Fingerprint Chromium %s for macOS ARM64…\n' "$engine_version"
    download="$(mktemp "$cache_dir/.engine.XXXXXX")"
    /usr/bin/curl --fail --location --retry 3 --connect-timeout 15 \
        --proto '=https' --proto-redir '=https' --silent --show-error \
        --output "$download" "$engine_url"
    digest_matches "$download" || fail "downloaded engine SHA-256 differs from the pinned upstream digest"
    /bin/mv -f -- "$download" "$dmg"
    download=''
fi

printf 'Building AnyBrowser for ARM64…\n'
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
/bin/cp "$root/Resources/AnyBrowser.icns" "$contents/Resources/"
/usr/bin/install -m 755 "$bin_path/AnyBrowser" "$contents/MacOS/AnyBrowser"
/usr/bin/plutil -insert AnyBrowserEngineVersion -string "$engine_version" "$contents/Info.plist"
/usr/bin/plutil -insert AnyBrowserEngineSHA256 -string "$engine_sha256" "$contents/Info.plist"
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
