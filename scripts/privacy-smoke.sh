#!/bin/bash
# Checks a packaged AnyBrowser.app for the privacy invariants a page can see: the window fits
# the claimed screen, CSS and JS agree about media, the guard reads as native and navigator has
# no own keys. Builds a throwaway Profile against a local page and cleans up.
#   ./scripts/privacy-smoke.sh dist/AnyBrowser.app
set -euo pipefail

app="${1:?usage: privacy-smoke.sh <AnyBrowser.app>}"
app="$(cd "$app" && pwd -P)"
ctl="$app/Contents/MacOS/anybrowserctl"
port=8823
name="privacy-smoke-$$"
site=$(mktemp -d /tmp/privacy-smoke.XXXXXX)
trap '/bin/rm -rf "$site"' EXIT

printf '<!doctype html><meta charset=utf-8><title>smoke</title>' > "$site/index.html"
(cd "$site" && exec python3 -m http.server "$port" >/dev/null 2>&1) &
server=$!
sleep 1

cleanup() {
    "$ctl" stop "$name" >/dev/null 2>&1 || true
    "$ctl" delete "$name" --purge --delete-data >/dev/null 2>&1 || true
    kill "$server" 2>/dev/null || true
}
trap 'cleanup; /bin/rm -rf "$site"' EXIT

"$ctl" create --name "$name" --json "{\"launch\":{\"startURLs\":[\"http://127.0.0.1:$port/\"]},\"proxy\":\"\"}" >/dev/null
"$ctl" start "$name" >/dev/null
sleep 9
debug=$("$ctl" show "$name" | python3 -c 'import json,sys; print(json.load(sys.stdin)["profile"]["port"])')

node - "$debug" <<'EOF'
const port = process.argv[2]
const list = await (await fetch(`http://127.0.0.1:${port}/json`)).json()
const page = list.find(t => t.type === 'page')
if (!page) { console.error('no page'); process.exit(1) }
const ws = new WebSocket(page.webSocketDebuggerUrl)
const expression = `(() => {
  const style = document.createElement('style')
  const probe = document.createElement('div')
  const width = innerWidth
  style.textContent = '@media (max-width: ' + (width - 100) + 'px) { #probe { color: rgb(1,2,3) } }'
  document.head.append(style)
  probe.id = 'probe'
  document.body.append(probe)
  const css = getComputedStyle(probe).color === 'rgb(1, 2, 3)'
  return JSON.stringify({
    outer: [outerWidth, outerHeight], inner: [innerWidth, innerHeight],
    screen: [screen.width, screen.height], avail: [screen.availWidth, screen.availHeight],
    cssAndJsAgree: css === matchMedia('(max-width: ' + (width - 100) + 'px)').matches,
    nativeMatchMedia: Function.prototype.toString.call(matchMedia).includes('[native code]'),
    navigatorKeys: Object.keys(navigator).length,
    evalLength: eval.toString().length,
  })
})()`
ws.onopen = () => ws.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { expression, returnByValue: true } }))
ws.onmessage = event => {
  const message = JSON.parse(event.data)
  if (message.id !== 1) return
  const seen = JSON.parse(message.result.result.value)
  const fail = []
  if (seen.outer[0] > seen.screen[0]) fail.push('outer wider than screen')
  if (seen.outer[1] > seen.screen[1]) fail.push('outer taller than screen')
  if (seen.inner[0] > seen.avail[0]) fail.push('inner wider than avail')
  if (seen.inner[1] > seen.avail[1]) fail.push('inner taller than avail')
  if (!seen.cssAndJsAgree) fail.push('css and matchMedia disagree')
  if (!seen.nativeMatchMedia) fail.push('matchMedia is not native-shaped')
  if (seen.navigatorKeys !== 0) fail.push('navigator has own keys')
  if (seen.evalLength !== 33) fail.push('eval length changed')
  console.log(JSON.stringify(seen))
  if (fail.length) { console.error('FAIL: ' + fail.join(', ')); process.exit(1) }
  console.log('ok')
  ws.close()
  process.exit(0)
}
setTimeout(() => { console.error('timeout'); process.exit(1) }, 8000)
EOF