#!/usr/bin/env bash
# cdp.sh — drive a live Chrome via the DevTools Protocol (CDP) using websocat.
#
# Context: a headful/headless Chrome is listening for CDP on :9222 on THIS host.
# The Tavazon dashboard (127.0.0.1:8081 on the remote) is SSH-forwarded to this
# laptop, so a Chrome tab pointed at http://localhost:8081/ is really looking at
# the remote service. This script talks to that tab.
#
# Transport model: each subcommand opens its OWN short-lived websocket to the
# page target, sends exactly one CDP request (always id=1, unique within that
# fresh connection), then reads until the reply with id==1 arrives. Async CDP
# events (which carry no ".id") are filtered out by jq. No domain enabling is
# needed for Runtime.evaluate / Page.navigate / Page.captureScreenshot.
#
# Config via env:
#   CDP_HOST     host:port of the Chrome CDP endpoint   (default localhost:9222)
#   CDP_WS       force a specific page ws:// URL         (default: auto-pick)
#   CDP_MATCH    substring to pick the page target by URL (default: 8081)
#   CDP_WAIT     seconds to keep the socket open for the reply (default 2)
#   CDP_TIMEOUT  hard ceiling on any single call, seconds (default 15)
set -euo pipefail

CDP_HOST="${CDP_HOST:-localhost:9222}"
CDP_MATCH="${CDP_MATCH:-8081}"
CDP_WAIT="${CDP_WAIT:-2}"
CDP_TIMEOUT="${CDP_TIMEOUT:-15}"
BUF=20000000  # max CDP message size (screenshots / big DOM dumps)

die() { echo "cdp.sh: $*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }
need websocat; need jq; need curl

# --- discover the page target's websocket URL -----------------------------
page_ws() {
  if [ -n "${CDP_WS:-}" ]; then printf '%s\n' "$CDP_WS"; return; fi
  local list
  list=$(curl -fsS --max-time 5 "http://${CDP_HOST}/json/list") \
    || die "cannot reach Chrome CDP at http://${CDP_HOST} (is --remote-debugging-port up?)"
  # Prefer a 'page' whose URL matches CDP_MATCH; else the first page.
  printf '%s' "$list" | jq -r --arg m "$CDP_MATCH" '
      ( [ .[] | select(.type=="page" and (.url|test($m))) ] +
        [ .[] | select(.type=="page") ] )
      | .[0].webSocketDebuggerUrl // empty' 2>/dev/null \
    | { read -r ws || true; [ -n "$ws" ] || die "no page target found (open a tab first)"; printf '%s\n' "$ws"; }
}

# --- core: send one CDP request, return the matching reply object ----------
# usage: cdp_call <method> <params-json>   -> prints the full reply JSON
cdp_call() {
  local method="$1" params="${2:-}" ws
  [ -n "$params" ] || params='{}'
  ws=$(page_ws)
  local msg
  msg=$(jq -cn --arg m "$method" --argjson p "$params" '{id:1,method:$m,params:$p}')
  # Keep stdin open for CDP_WAIT so the reply arrives, then EOF lets websocat
  # close cleanly (no -n). jq --unbuffered flushes the match immediately so
  # head can take the first id==1 reply; timeout is a hard backstop.
  { printf '%s\n' "$msg"; sleep "$CDP_WAIT"; } \
    | timeout "$CDP_TIMEOUT" websocat -t -B "$BUF" "$ws" 2>/dev/null \
    | jq -c --unbuffered 'select(.id==1)' \
    | head -n1
}

# Fail loudly if CDP returned an error object.
cdp_check() {
  local reply="$1"
  [ -n "$reply" ] || die "no reply from Chrome (timeout after ${CDP_TIMEOUT}s)"
  if printf '%s' "$reply" | jq -e '.error' >/dev/null 2>&1; then
    die "CDP error: $(printf '%s' "$reply" | jq -c '.error')"
  fi
}

# --- subcommands -----------------------------------------------------------
cmd_version()  { curl -fsS --max-time 5 "http://${CDP_HOST}/json/version" | jq .; }
cmd_targets()  { curl -fsS --max-time 5 "http://${CDP_HOST}/json/list" \
                   | jq -r '.[] | "\(.type)\t\(.url)\t\(.webSocketDebuggerUrl)"'; }
cmd_ws()       { page_ws; }

# send <method> [params-json]  — raw escape hatch, prints .result
cmd_send() {
  [ $# -ge 1 ] || die "usage: cdp.sh send <method> [params-json]"
  local reply; reply=$(cdp_call "$1" "${2:-}"); cdp_check "$reply"
  printf '%s' "$reply" | jq '.result'
}

# eval <js>  — Runtime.evaluate, prints the (JSON) return value
cmd_eval() {
  [ $# -ge 1 ] || die "usage: cdp.sh eval <javascript>"
  local params reply
  params=$(jq -n --arg e "$*" '{expression:$e,returnByValue:true,awaitPromise:true}')
  reply=$(cdp_call "Runtime.evaluate" "$params"); cdp_check "$reply"
  if printf '%s' "$reply" | jq -e '.result.exceptionDetails' >/dev/null 2>&1; then
    die "JS exception: $(printf '%s' "$reply" | jq -r '.result.exceptionDetails.text // .result.exceptionDetails.exception.description')"
  fi
  printf '%s' "$reply" | jq -r '.result.result.value'
}

cmd_nav() {
  [ $# -ge 1 ] || die "usage: cdp.sh nav <url>"
  local reply; reply=$(cdp_call "Page.navigate" "$(jq -n --arg u "$1" '{url:$u}')")
  cdp_check "$reply"; printf '%s' "$reply" | jq -c '.result'
}

cmd_reload() { local r; r=$(cdp_call "Page.reload" '{}'); cdp_check "$r"; echo reloaded; }
cmd_title()  { cmd_eval 'document.title'; }
cmd_url()    { cmd_eval 'location.href'; }
cmd_html()   { cmd_eval 'document.documentElement.outerHTML'; }
cmd_text()   { cmd_eval 'document.body.innerText'; }

# screenshot [file.png]  — full-page PNG
cmd_screenshot() {
  local out="${1:-screenshot.png}" reply data
  reply=$(cdp_call "Page.captureScreenshot" '{"format":"png","captureBeyondViewport":true}')
  cdp_check "$reply"
  data=$(printf '%s' "$reply" | jq -r '.result.data')
  [ -n "$data" ] && [ "$data" != null ] || die "empty screenshot data"
  printf '%s' "$data" | base64 -d > "$out"
  echo "wrote $out ($(wc -c < "$out") bytes)"
}

usage() {
  cat >&2 <<'EOF'
cdp.sh — drive live Chrome over CDP (websocat)

  cdp.sh version                 Chrome/protocol version (/json/version)
  cdp.sh targets                 list open targets (type / url / ws)
  cdp.sh ws                      print the chosen page's ws:// URL
  cdp.sh eval <js>               evaluate JS in the page, print return value
  cdp.sh nav <url>               navigate the page
  cdp.sh reload                  reload the page
  cdp.sh title | url | html | text
  cdp.sh screenshot [file.png]   capture a PNG (default screenshot.png)
  cdp.sh send <method> [params]  raw CDP call, e.g.
                                 cdp.sh send Runtime.evaluate '{"expression":"1+1","returnByValue":true}'

Env: CDP_HOST(=localhost:9222) CDP_MATCH(=8081) CDP_WS CDP_WAIT(=2) CDP_TIMEOUT(=15)
EOF
  exit 1
}

[ $# -ge 1 ] || usage
sub="$1"; shift
case "$sub" in
  version)     cmd_version "$@" ;;
  targets)     cmd_targets "$@" ;;
  ws)          cmd_ws "$@" ;;
  send)        cmd_send "$@" ;;
  eval)        cmd_eval "$@" ;;
  nav)         cmd_nav "$@" ;;
  reload)      cmd_reload "$@" ;;
  title)       cmd_title "$@" ;;
  url)         cmd_url "$@" ;;
  html)        cmd_html "$@" ;;
  text)        cmd_text "$@" ;;
  screenshot)  cmd_screenshot "$@" ;;
  -h|--help|help) usage ;;
  *)           die "unknown command: $sub (try: cdp.sh help)" ;;
esac
