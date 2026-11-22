#!/bin/bash
# Runs `swift test --arch arm64` and passes every other argument through, for example
# `--filter LibraryTests`. --engine <AnyBrowser.app> also runs the real-browser suites against
# that packaged app by setting ANYBROWSER_TEST_APP.
#
# With only the Command Line Tools installed it picks an SDK that compiles SwiftUI and points the
# compiler at swift-testing's macro plugin; otherwise builds randomly fail with
# "plugin for module 'TestingMacros' not found".
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

fail() {
    printf 'AnyBrowser tests: %s\n' "$*" >&2
    exit 1
}

engine=''
arguments=()
while (($#)); do
    case "$1" in
    --engine)
        (($# >= 2)) || fail "--engine needs the path of a packaged AnyBrowser.app"
        engine="$2"
        shift 2
        ;;
    --engine=*)
        engine="${1#--engine=}"
        shift
        ;;
    *)
        arguments+=("$1")
        shift
        ;;
    esac
done

if [[ -n "$engine" ]]; then
    [[ -x "$engine/Contents/Frameworks/Chromium.app/Contents/MacOS/Chromium" ]] ||
        fail "$engine is not a packaged AnyBrowser.app; build one with scripts/build-app.sh"
    ANYBROWSER_TEST_APP="$(cd "$engine" && pwd -P)"
    export ANYBROWSER_TEST_APP
fi

cd "$root"
# shellcheck source=scripts/toolchain.sh
source "$root/scripts/toolchain.sh"
select_swiftui_sdk || fail "no installed SDK can compile SwiftUI; install Xcode 16 or later"
if [[ "$command_line_tools" == true && -d "$testing_plugins" ]]; then
    arguments=(-Xswiftc -plugin-path -Xswiftc "$testing_plugins" ${arguments[@]+"${arguments[@]}"})
fi
exec swift test --arch arm64 ${arguments[@]+"${arguments[@]}"}
