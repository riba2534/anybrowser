#!/bin/bash
# Compares the engine and Passkey Box pinned in build-app.sh with the latest upstream releases.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
pinned() { sed -n "s/^$1=//p" "$root/scripts/build-app.sh"; }
engine=$(pinned engine_version)
passkey=$(pinned passkey_version)

# Authenticated through gh when available: anonymous API calls are rate limited.
github() {
    if command -v gh >/dev/null 2>&1; then
        gh api "$1"
    else
        curl -fsSL --proto '=https' -H 'Accept: application/vnd.github+json' "https://api.github.com/$1"
    fi
}

# Prints "<tag> <macOS asset>" for the newest releases that ship a macOS DMG.
latest_engine=$(github "repos/adryfish/fingerprint-chromium/releases?per_page=20" |
    /usr/bin/python3 -I -c '
import json, sys
for release in json.load(sys.stdin):
    dmg = [a["name"] for a in release.get("assets", []) if a["name"].endswith("_macos.dmg")]
    if dmg and not release.get("draft") and not release.get("prerelease"):
        print(release["tag_name"], dmg[0])
        break
')
latest_passkey=$(github "repos/riba2534/passkey-box/releases/latest" |
    /usr/bin/python3 -I -c 'import json, sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))')

printf 'Fingerprint Chromium  pinned %-16s latest macOS %s\n' "$engine" "${latest_engine:-none}"
printf 'Passkey Box           pinned %-16s latest %s\n' "$passkey" "$latest_passkey"
[[ "${latest_engine%% *}" == "$engine" && "$latest_passkey" == "$passkey" ]] && echo "Up to date." || echo "Updates available: change the versions and SHA-256 digests in scripts/build-app.sh."
