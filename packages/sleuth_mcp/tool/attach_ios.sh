#!/usr/bin/env bash
# attach_ios.sh — one-command iOS real-device attach for sleuth_mcp.
#
# No Dart runtime required. Behavior mirrors:
#   sleuth_mcp attach-ios <udid> [--bundle <id>] [--port <n>] [--auth <c>]
#
# Use this when `sleuth_mcp` isn't pub-activated (CI bootstrap scripts,
# ad-hoc shell). The Dart subcommand remains the canonical entry; this
# wrapper exists as a no-Dart fallback + readable reference for the
# devicectl → dns-sd → iproxy pipeline.
#
# Prerequisite (one-time): brew install libimobiledevice  (provides iproxy)
#
# Bash 3.2+ (macOS default). No coreutils dependency — uses /usr/bin/perl
# for the dns-sd timeout (perl ships with macOS).

set -euo pipefail

usage() {
  cat <<EOF
usage: $(basename "$0") <udid> [--bundle <bundle-id>] [--port <host-port>] [--auth <code>]

Launches the installed app on <udid>, resolves the Dart VM service via
Bonjour, spawns iproxy as a child to tunnel the device port to 127.0.0.1,
and prints the wsUri for attach_app(debugUrl:). Ctrl-C tears everything
down cleanly.

Flags:
  --bundle <id>     iOS bundle identifier (default: com.example.example)
  --port <n>        Host-side iproxy port (default: same as device port)
  --auth <code>     Pin Bonjour authCode (required when >1 pairing is
                    announced — iproxy only accepts the USB-bridged
                    token and interface ordering is not contractual)
  -h, --help        Print this message

Prerequisite: brew install libimobiledevice
EOF
}

UDID=""
BUNDLE="com.example.example"
HOST_PORT=""
AUTH_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --bundle) BUNDLE="${2:-}"; shift 2 ;;
    --port)   HOST_PORT="${2:-}"; shift 2 ;;
    --auth)   AUTH_OVERRIDE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "unknown flag: $1" >&2; usage >&2; exit 64 ;;
    *)  if [ -z "$UDID" ]; then UDID="$1"; shift; else
          echo "unexpected positional arg: $1" >&2; usage >&2; exit 64
        fi ;;
  esac
done

if [ -z "$UDID" ]; then
  usage >&2
  exit 64
fi

# Doctor — check required binaries are on PATH.
missing=0
for tool in xcrun dns-sd iproxy perl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "missing required tool: $tool" >&2
    case "$tool" in
      iproxy)
        echo "  install via: brew install libimobiledevice" >&2
        ;;
      xcrun|dns-sd)
        echo "  attach-ios is macOS-only (requires Xcode CLI tools)" >&2
        ;;
    esac
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  exit 65
fi

echo "Launching $BUNDLE on $UDID..."
if ! xcrun devicectl device process launch \
      --device "$UDID" \
      --terminate-existing \
      "$BUNDLE" >/dev/null 2>&1; then
  echo "devicectl launch failed — is the app installed on $UDID?" >&2
  echo "  build + install once via: fvm flutter run --profile -d $UDID" >&2
  exit 66
fi

# After --terminate-existing, Bonjour caches the prior service port for
# ~2s. Sleep so we don't pin the dead port.
sleep 3

echo "Resolving VM service via Bonjour (max 15s)..."

# dns-sd never exits on its own, so we wrap it with a perl alarm to
# bound wall-time. The pipeline ends as soon as we have one
# reached-at + authCode pair; perl kills dns-sd when alarm fires.
#
# Bonjour line shapes:
#   14:23:51  com\.example\.example._dartVmService._tcp.local. can be reached at Pengen.local.:53172 (interface 25) Flags: 1
#    authCode=fiEVCvhg6Qg=
PAIR_FILE=$(mktemp -t sleuth_attach_ios.XXXXXX)
cleanup_pairfile() { rm -f "$PAIR_FILE"; }
trap cleanup_pairfile EXIT

# Stream dns-sd output through sed to parse pairs. Each pair lands as a
# `<port> <iface> <auth>` row. We collect everything seen within the
# perl alarm window then disambiguate below.
set +e
perl -e 'alarm 15; exec @ARGV' script -q /dev/null dns-sd -L "$BUNDLE" _dartVmService._tcp local. 2>/dev/null \
  | while IFS= read -r line; do
      reach=$(printf '%s' "$line" | sed -nE 's/.*can be reached at [^:]+:([0-9]+) \(interface ([0-9]+)\).*/\1 \2/p')
      if [ -n "$reach" ]; then
        PENDING_REACH="$reach"
        continue
      fi
      auth=$(printf '%s' "$line" | sed -nE 's/.*authCode=([A-Za-z0-9_=+/-]+).*/\1/p')
      if [ -n "$auth" ] && [ -n "${PENDING_REACH:-}" ]; then
        # Strip trailing `=` from authCode (we re-add one in the wsUri).
        auth_stripped=$(printf '%s' "$auth" | sed -E 's/=+$//')
        printf '%s %s\n' "$PENDING_REACH" "$auth_stripped" >> "$PAIR_FILE"
        PENDING_REACH=""
      fi
    done
set -e

if [ ! -s "$PAIR_FILE" ]; then
  echo "timeout waiting for Bonjour announcement — is the app actually running?" >&2
  echo "  re-check via: dns-sd -L $BUNDLE _dartVmService._tcp local." >&2
  exit 67
fi

# Print every collected pairing so the user can see what was on offer
# and re-run with `--auth <code>` if the auto-pick is ambiguous.
echo "Collected pairings:"
awk '{print "  iface " $2 ": port=" $1 " authCode=" $3}' "$PAIR_FILE"

NUM_PAIRS=$(wc -l < "$PAIR_FILE" | tr -d ' ')
DISTINCT_AUTHS=$(awk '{print $3}' "$PAIR_FILE" | sort -u | wc -l | tr -d ' ')

# Strip trailing `=` from any user-supplied --auth so it matches the
# stripped tokens in PAIR_FILE.
if [ -n "$AUTH_OVERRIDE" ]; then
  AUTH_OVERRIDE=$(printf '%s' "$AUTH_OVERRIDE" | sed -E 's/=+$//')
fi

# Disambiguate.
#   1. --auth supplied  → carry that row's port + iface + auth as a unit;
#                         if no row matches, exit 67 with available authCodes.
#   2. exactly one      → auto-pick.
#   3. >=2 distinct     → refuse to guess; require --auth.
if [ -n "$AUTH_OVERRIDE" ]; then
  SELECTED=$(awk -v a="$AUTH_OVERRIDE" '$3 == a {print; exit}' "$PAIR_FILE")
  if [ -z "$SELECTED" ]; then
    echo "no announcement matched --auth $AUTH_OVERRIDE" >&2
    echo "  observed authCodes: $(awk '{print $3}' "$PAIR_FILE" | paste -sd ',' -)" >&2
    exit 67
  fi
elif [ "$DISTINCT_AUTHS" -le 1 ]; then
  SELECTED=$(head -1 "$PAIR_FILE")
else
  echo "ambiguous Bonjour pairings: $DISTINCT_AUTHS distinct authCodes were announced." >&2
  echo "  iproxy only accepts the USB-bridged token; interface ordering is not contractual." >&2
  echo "  re-run with --auth <code> using one of:" >&2
  awk '{print "    " $3}' "$PAIR_FILE" | sort -u >&2
  exit 67
fi

DEVICE_PORT=$(printf '%s' "$SELECTED" | awk '{print $1}')
IFACE=$(printf '%s' "$SELECTED" | awk '{print $2}')
AUTH=$(printf '%s' "$SELECTED" | awk '{print $3}')
HOST_PORT="${HOST_PORT:-$DEVICE_PORT}"

echo "Device port: $DEVICE_PORT (interface $IFACE), auth: $AUTH"

# Stale-pid cleanup. If a previous attach was killed before its trap
# could fire (terminal closed under a wrapper whose default SIGHUP
# disposition pre-empted the trap), the orphan iproxy is still holding
# $HOST_PORT. Reclaim it before re-binding.
SAFE_UDID=$(printf '%s' "$UDID" | tr -c 'A-Za-z0-9-' '_')
PIDFILE="/tmp/sleuth_mcp_iproxy_${SAFE_UDID}_${HOST_PORT}.pid"
if [ -f "$PIDFILE" ]; then
  STALE_PID=$(cat "$PIDFILE" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$STALE_PID" ] && [ "$STALE_PID" -gt 1 ] 2>/dev/null \
      && kill -0 "$STALE_PID" 2>/dev/null; then
    STALE_ARGS=$(ps -o args= -p "$STALE_PID" 2>/dev/null)
    if printf '%s' "$STALE_ARGS" \
        | grep -q "iproxy $HOST_PORT $DEVICE_PORT --udid $UDID"; then
      echo "removed stale iproxy from prior session (pid $STALE_PID, port $HOST_PORT)" >&2
      kill -TERM "$STALE_PID" 2>/dev/null || true
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        sleep 0.2
        kill -0 "$STALE_PID" 2>/dev/null || break
      done
      kill -0 "$STALE_PID" 2>/dev/null && kill -KILL "$STALE_PID" 2>/dev/null || true
    else
      echo "pidfile $PIDFILE points at pid $STALE_PID but argv does not match — leaving alone" >&2
    fi
  fi
  rm -f "$PIDFILE"
fi

echo "Spawning iproxy $HOST_PORT -> device:$DEVICE_PORT..."

# Buffer iproxy stderr so a port-collision diagnostic ("Address already
# in use") survives long enough to be replayed if iproxy bails inside
# the readiness window.
IPROXY_ERR=$(mktemp -t sleuth_attach_ios_iproxy_err.XXXXXX)
# `nohup` + `disown` so iproxy survives a parent SIGHUP and the OS
# reaps it via launchd / init instead of leaving an orphan holding
# $HOST_PORT. Pidfile + stale-pid sweep above covers the case where
# the parent dies before the trap can fire.
nohup iproxy "$HOST_PORT" "$DEVICE_PORT" --udid "$UDID" >/dev/null 2>"$IPROXY_ERR" &
IPROXY_PID=$!
disown "$IPROXY_PID" 2>/dev/null || true
printf '%s\n' "$IPROXY_PID" > "$PIDFILE"

cleanup_iproxy() {
  echo ""
  echo "Tearing down iproxy (pid $IPROXY_PID)..."
  kill "$IPROXY_PID" 2>/dev/null || true
  # `wait` only works for non-disowned children; fall back to polling.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.2
    kill -0 "$IPROXY_PID" 2>/dev/null || break
  done
  rm -f "$IPROXY_ERR" 2>/dev/null || true
  rm -f "$PIDFILE" 2>/dev/null || true
  cleanup_pairfile
}
# Cover SIGINT (Ctrl-C), SIGTERM (`kill <pid>`), SIGHUP (terminal close)
# and normal EXIT. SIGKILL is untrappable — best-effort cleanup only.
trap cleanup_iproxy INT TERM HUP EXIT

# Readiness window — if iproxy exits inside ~300ms it failed to bind
# (port already taken, device disconnect, etc.). Replay the captured
# stderr instead of printing a dead wsUri.
sleep 0.3
if ! kill -0 "$IPROXY_PID" 2>/dev/null; then
  echo "iproxy exited inside readiness window — tunnel never came up." >&2
  if [ -s "$IPROXY_ERR" ]; then
    echo "iproxy stderr:" >&2
    cat "$IPROXY_ERR" >&2
  fi
  exit 68
fi

WS_URI="ws://127.0.0.1:$HOST_PORT/$AUTH=/ws"

cat <<EOF

wsUri: $WS_URI

Paste into your agent: attach_app(debugUrl: '$WS_URI')

iproxy running (pid $IPROXY_PID). Press Ctrl-C to tear down.
EOF

# Block until iproxy exits (or a signal trips the trap). `wait` only
# works for non-disowned jobs, so poll on liveness instead.
while kill -0 "$IPROXY_PID" 2>/dev/null; do
  sleep 1
done
