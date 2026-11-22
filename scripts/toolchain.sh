# shellcheck shell=bash
# Sourced by build-app.sh and test.sh. Fills two gaps of a setup with only the Command Line Tools;
# with Xcode, or an SDKROOT the caller already chose, nothing changes.

# The toolchain behind `swift`. The Command Line Tools keep their SDKs beside usr/, Xcode does not.
toolchain="$(/usr/bin/xcrun -f swift)"
toolchain="${toolchain%/usr/bin/swift}"
if [[ -d "$toolchain/SDKs" ]]; then command_line_tools=true; else command_line_tools=false; fi

# swift-testing's macro plugin, which `swift test` does not always find under these tools.
testing_plugins="$toolchain/usr/lib/swift/host/plugins/testing"

compiles_swiftui() {
    /usr/bin/xcrun swiftc -typecheck -sdk "$1" -target arm64-apple-macos12 - >/dev/null 2>&1 <<'SWIFT'
import SwiftUI
struct Probe: View {
    @State private var on = false
    var body: some View { Toggle("", isOn: $on) }
}
SWIFT
}

# Newer SDKs declare SwiftUI's @State as a macro whose plugin only Xcode ships, so the default SDK
# may not build the app. Picks the newest installed SDK that still can; fails when none does.
select_swiftui_sdk() {
    [[ "$command_line_tools" == true && -z "${SDKROOT:-}" ]] || return 0
    if compiles_swiftui "$(/usr/bin/xcrun --show-sdk-path)"; then return 0; fi
    local sdk
    while IFS= read -r sdk; do
        if [[ ! -L "$sdk" ]] && compiles_swiftui "$sdk"; then
            export SDKROOT="$sdk"
            printf 'Using %s: the default SDK cannot compile SwiftUI without Xcode.\n' "${sdk##*/}"
            return 0
        fi
    done < <(printf '%s\n' "$toolchain"/SDKs/MacOSX[0-9]*.sdk | /usr/bin/sort -V -r)
    return 1
}
