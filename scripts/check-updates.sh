#!/bin/bash
# Compares the engine and Passkey Box pinned in scripts/versions.env with the latest upstream
# releases, and the engine with the current Chrome stable for Mac.
#
# Exit status: 0 when both are up to date; 10 when a newer macOS engine or Passkey Box is out,
# or when the engine is 2 or more major versions behind Chrome stable even though upstream has no
# newer macOS build; any other status means the check itself failed.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=scripts/versions.env
source "$root/scripts/versions.env"

# Authenticated through gh when available: anonymous API calls are rate limited.
github() {
    if command -v gh >/dev/null 2>&1; then
        gh api "$1"
    else
        curl -fsSL --proto '=https' -H 'Accept: application/vnd.github+json' "https://api.github.com/$1"
    fi
}

# True when version $1 sorts after version $2.
newer() {
    [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]
}

# The SHA-256 GitHub recorded for an asset; older uploads have none ("-") and must be hashed locally.
digest_or_note() {
    if [[ "$1" == - ]]; then
        printf 'not published by GitHub: download %s and run shasum -a 256' "$2"
    else
        printf '%s' "$1"
    fi
}

# Each answer is fetched, then parsed, then split, so a failed request or an unexpected answer
# stops the script with its error instead of reporting blanks.
#
# "<newest tag> <newest tag with a macOS DMG> <engine version> <revision> <DMG> <SHA-256 or ->":
# upstream often skips the macOS build, so the newest tag and the newest macOS build can differ.
releases="$(github "repos/adryfish/fingerprint-chromium/releases?per_page=30")"
engine_line="$(/usr/bin/python3 -I -c '
import json, re, sys
releases = sorted((r for r in json.load(sys.stdin) if not r["draft"] and not r["prerelease"]),
                  key=lambda r: [int(part) for part in re.findall(r"\d+", r["tag_name"])], reverse=True)
dmgs = ((release, asset, re.fullmatch(r"ungoogled-chromium_([\d.]+)-([^_]+)_macos\.dmg", asset["name"]))
        for release in releases for asset in release["assets"])
release, asset, match = next((dmg for dmg in dmgs if dmg[2]), (None, None, None))
digest = asset.get("digest") or "" if asset else ""
mac = [release["tag_name"], match[1], match[2], asset["name"]] if match else ["-"] * 4
print(releases[0]["tag_name"], *mac, digest.removeprefix("sha256:") if digest.startswith("sha256:") else "-")
' <<<"$releases")"
read -r latest_tag mac_tag mac_version mac_revision mac_asset mac_digest <<<"$engine_line"

# Chrome stable for Mac: the highest version the stable channel has shipped.
versions="$(curl -fsSL --proto '=https' "https://versionhistory.googleapis.com/v1/chrome/platforms/mac/channels/stable/versions")"
stable="$(/usr/bin/python3 -I -c '
import json, sys
versions = [entry["version"] for entry in json.load(sys.stdin)["versions"]]
print(max(versions, key=lambda version: [int(part) for part in version.split(".")]))
' <<<"$versions")"
behind=$((${stable%%.*} - ${engine_version%%.*}))

# "<version> <AnyBrowser ZIP or -> <SHA-256 or ->" of the latest Passkey Box release.
passkey_release="$(github "repos/riba2534/passkey-box/releases/latest")"
passkey_line="$(/usr/bin/python3 -I -c '
import json, sys
release = json.load(sys.stdin)
version = release["tag_name"].removeprefix("v")
name = f"passkey-box-extension-anybrowser-v{version}.zip"
asset = next((a for a in release["assets"] if a["name"] == name), None)
digest = asset.get("digest") or "" if asset else ""
print(version, name if asset else "-", digest.removeprefix("sha256:") if digest.startswith("sha256:") else "-")
' <<<"$passkey_release")"
read -r passkey_latest passkey_asset passkey_digest <<<"$passkey_line"

latest_note=''
[[ "$latest_tag" == "$mac_tag" ]] || latest_note=' (no macOS build)'
mac_latest="$mac_version-$mac_revision"
[[ "$mac_version" != - ]] || mac_latest=none
printf 'Fingerprint Chromium  pinned %-20s latest macOS %s\n' "$engine_version-$engine_revision" "$mac_latest"
printf '                      latest release %s%s\n' "$latest_tag" "$latest_note"
printf 'Chrome stable (Mac)   %-27s engine is %d major versions behind\n' "$stable" "$behind"
printf 'Passkey Box           pinned %-20s latest %s\n' "$passkey_version" "$passkey_latest"

status=0
engine_update=false
passkey_update=false
if [[ "$mac_version" != - ]] && newer "$mac_version-$mac_revision" "$engine_version-$engine_revision"; then
    engine_update=true
    printf '\nNew macOS engine %s:\n' "$mac_asset"
    printf '  engine_version=%s\n  engine_revision=%s\n  engine_sha256=%s\n' \
        "$mac_version" "$mac_revision" "$(digest_or_note "$mac_digest" "$mac_asset")"
    [[ "$mac_tag" == "$mac_version" ]] ||
        printf '  Its tag %s differs from the version, which build-app.sh uses in the download URL.\n' "$mac_tag"
elif ((behind >= 2)); then
    status=10
    printf '\nThe engine is %d major versions behind Chrome stable, and upstream has no newer macOS build.\n' "$behind"
fi
if newer "$passkey_latest" "$passkey_version"; then
    passkey_update=true
    printf '\nNew Passkey Box %s:\n' "$passkey_latest"
    if [[ "$passkey_asset" == - ]]; then
        printf '  The release has no passkey-box-extension-anybrowser-v%s.zip asset yet.\n' "$passkey_latest"
    else
        printf '  passkey_version=%s\n  passkey_sha256=%s\n' \
            "$passkey_latest" "$(digest_or_note "$passkey_digest" "$passkey_asset")"
        printf '  passkey_id stays %s unless the manifest key changed; build-app.sh checks it.\n' "$passkey_id"
    fi
fi

if [[ "$engine_update" == true || "$passkey_update" == true ]]; then
    status=10
    printf '\nTo upgrade, change:\n'
    printf '  - scripts/versions.env, with the values above\n'
    printf '  - Sources/AnyBrowserCore/BundledVersions.swift (VersionConsistencyTests compares it with versions.env)\n'
    if [[ "$engine_update" == true ]]; then
        printf '  - the Chrome and Edge brand versions in Sources/AnyBrowserCore/IdentityPresets.swift and\n'
        printf '    Profile.swift (randomBrandVersion), and the engine check in IdentityShim.isNeeded\n'
    fi
    printf '  - README.md: the versions and release links under 快速开始\n'
    printf 'Then run ./scripts/build-app.sh and ./scripts/test.sh --engine dist/AnyBrowser.app.\n'
fi
[[ "$status" != 0 ]] || echo "Up to date."
exit "$status"
