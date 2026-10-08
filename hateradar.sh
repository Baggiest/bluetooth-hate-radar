#!/usr/bin/env bash
# =====================================================================
# hateradar — simple bash/zsh bluetooth proximity radar client
#
#  * Takes live bluetooth data from the local adapter (via bluetoothctl)
#    and ranks devices closest -> farthest by RSSI.
#  * Simple menu: toggle "danger" on a bluetooth MAC, set a nickname,
#    pick a custom alert sound.
#  * Stays open; plays your alert sound (+ optional OS notify) when a
#    danger-marked device gets close (RSSI >= threshold).
#  * Neon cyberpunk UI (disable with --no-color).
#
# Usage:
#   bash hateradar.sh              # live mode (needs bluetooth + BlueZ)
#   bash hateradar.sh --demo       # fake devices, no bluetooth needed
#   bash hateradar.sh --help
#
# Works under both bash and zsh. No dependencies besides BlueZ
# (bluetoothctl). Alert audio: your custom file via paplay/aplay/ffplay
# if present, else the terminal bell. OS alerts use notify-send if
# present (disable with flags).
#
# Data files:
#   ~/.config/hateradar/known      MAC|nickname|danger(0/1)  (persisted)
#   ~/.config/hateradar/config     CLOSE_RSSI / SOUND_FILE   (persisted)
#   /tmp/hateradar-$USER/devices.live|devices.demo
#                                  MAC|name|RSSI|last_epoch   (live state,
#                                  one file per mode — never mixed)
# =====================================================================

APP="hateradar"
VERSION="0.2.0"

# ---------- defaults (overridable by flags / config file) ----------
MODE="live"            # live | demo
INTERVAL=1             # UI refresh seconds
CLOSE_RSSI=-70         # danger is "close" when RSSI >= this (dBm)
VERY_CLOSE_RSSI=-55   # faster alerting when RSSI >= this
STALE_AFTER=45        # seconds without sighting -> marked STALE
PRUNE_AFTER=300       # seconds without sighting -> dropped on 'clear'
DO_BEEP=1
DO_NOTIFY=1
SOUND_FILE=""         # custom alert audio (wav/oga/ogg/mp3); "" = bell
CLOSE_FROM_FLAG=0     # set when --close passed (beats saved config)
SOUND_FROM_FLAG=0     # set when --sound passed (beats saved config)
COLOR_REQ="auto"      # auto | on | off  (--color / --no-color)
NOTIFY_EVERY=15       # min seconds between OS alerts per MAC
IFACE=""              # reserved: bluetooth adapter name (default adapter)

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hateradar"
KNOWN_FILE="$CONFIG_DIR/known"
CONFIG_FILE="$CONFIG_DIR/config"
RUNTIME_DIR="/tmp/hateradar-${USER:-$(whoami)}"
DEVICES_FILE="$RUNTIME_DIR/devices.live"  # reassigned per MODE after arg parsing
SCAN_LOG="$RUNTIME_DIR/scan.log"
SCAN_PID_FILE="$RUNTIME_DIR/scan.pid"
MON_PID_FILE="$RUNTIME_DIR/mon.pid"
NOTIFY_DIR="$RUNTIME_DIR/lastnotify"
USE_COLOR=1            # resolved after arg parsing (tty/NO_COLOR/flags)

# ---------- helpers ----------
is_zsh() { [ -n "${ZSH_VERSION:-}" ]; }

# kill PID only if it is really ours (stale pidfiles + recycled PIDs
# must never nuke a stranger). Pattern must appear in /proc/PID/cmdline.
safe_kill() { # $1=pid $2=expected cmdline fragment
  local pid="$1" pat="$2" cmd
  [ -z "$pid" ] && return 0
  [ "$pid" = "$$" ] && return 0
  cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
  case "$cmd" in *"$pat"*) kill "$pid" 2>/dev/null || true;; *) :;; esac
}

# c CODE — print an ANSI escape, or nothing when color is off.
# Keeps row alignment intact: callers wrap WHOLE lines, never cells.
c() { [ "$USE_COLOR" = "1" ] && printf '\033[%sm' "$1"; }

# theme palette
C_TITLE="" C_HEAD="" C_DIM="" C_ROW="" C_DANGER="" C_WARN="" C_CLOSE="" C_OK="" C_OFF=""
theme_init() {
  if [ "$USE_COLOR" = "1" ]; then
    C_TITLE="$(c '1;95')"    # bold bright magenta
    C_HEAD="$(c '1;36')"     # bold bright cyan
    C_DIM="$(c '2;37')"      # dim white
    C_ROW="$(c '36')"        # cyan
    C_DANGER="$(c '1;91')"   # bold bright red
    C_WARN="$(c '1;33')"      # bold yellow
    C_CLOSE="$(c '1;93')"    # bold bright yellow
    C_OK="$(c '92')"         # bright green
    C_OFF="$(c '0')"         # reset
  fi
  # when off, all stay "" — plain text, same layout, pipe-safe
}

# ---------- flicker-free terminal handling ----------
# The old full-screen clear (\033[2J) every second is what flickers.
# Instead: draw once onto the terminal's ALTERNATE screen, then repaint
# in place each frame (cursor home + paint + clear-to-end). Cursor stays
# hidden except while reading input. All of it only on a real terminal —
# piped output keeps the plain scrolling log.
USE_TUI=0
tui_enter() { # switch to alt screen, hide cursor
  [ "$USE_TUI" = "1" ] || return 0
  printf '\033[?1049h\033[?25l' >&2
}
tui_leave() { # restore normal screen + cursor (always safe to call)
  [ "$USE_TUI" = "1" ] || return 0
  printf '\033[?25h\033[?1049l' >&2
}
cursor_show() { [ "$USE_TUI" = "1" ] && printf '\033[?25h' >&2 || true; }
cursor_hide() { [ "$USE_TUI" = "1" ] && printf '\033[?25l' >&2 || true; }
press_enter() { # "Enter to continue" — cursor visible while waiting
  cursor_show
  IFS= read -r _ || true
  cursor_hide
}

# persisted settings: CLOSE_RSSI + SOUND_FILE (flags win over file).
# Stored raw, one KEY=value per line (values may contain spaces or '=').
load_config() {
  [ -f "$CONFIG_FILE" ] || return 0
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      CLOSE_RSSI) if [ "$CLOSE_FROM_FLAG" != "1" ]; then case "$v" in ''|*[!0-9-]*) : ;; *) CLOSE_RSSI="$v";; esac; fi;;
      SOUND_FILE) if [ "$SOUND_FROM_FLAG" != "1" ]; then [ -z "$v" ] && SOUND_FILE="" || { [ -r "$v" ] && SOUND_FILE="$v"; }; fi;;
    esac
  done < "$CONFIG_FILE"
}
save_config() {
  {
    printf '# hateradar settings (written by the app — threshold + alert sound)\n'
    printf 'CLOSE_RSSI=%s\n' "$CLOSE_RSSI"
    printf 'SOUND_FILE=%s\n' "$SOUND_FILE"
  } > "$CONFIG_FILE"
}

usage() {
  cat <<EOF
$APP v$VERSION — bluetooth proximity radar

Usage:
  bash $0 [options]

Options:
  --demo               fake devices for testing (no bluetooth needed)
  --live               live bluetooth mode (default)
  --interval N         UI refresh seconds (default 1)
  --close RSSI         danger counts as "close" at/above this dBm (default -70)
  --sound FILE         custom alert sound (wav/oga/ogg/mp3); played on proximity
  --no-beep            disable audible alerts entirely
  --no-notify          disable notify-send OS alerts
  --stale N            mark devices STALE after N sec unseen (default 45)
  --color / --no-color force neon UI on/off (default: on in terminal, off piped)
  -h, --help           this help

Keys (while running):
  d  toggle danger on a device (prompts for # or MAC)
  n  set nickname for a device (prompts for # or MAC)
  s  set/change the custom alert sound (or 'off' for the bell)
  t  change close-threshold RSSI (saved)
  c  clear stale devices from the list
  l  toggle: show all / danger-marked only
  q  quit (also Ctrl-C)

Files:
  known labels persist in: $KNOWN_FILE
  threshold + sound persist in: $CONFIG_DIR/config

Device names: the grid shows each device's broadcast Name when it sends
one. Privacy-conscious gadgets (e.g. iPhones with random addresses)
broadcast no name — the grid then shows the adapter Alias instead, and
your nickname (n) always wins when set.
EOF
}

# normalize MAC to uppercase AA:BB:CC:DD:EE:FF, echo "" if invalid
norm_mac() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | grep -E -o '[0-9A-F]{2}(:[0-9A-F]{2}){5}' | head -n1
}

ensure_dirs() {
  mkdir -p "$CONFIG_DIR" "$RUNTIME_DIR" "$NOTIFY_DIR" 2>/dev/null
  touch "$KNOWN_FILE" "$DEVICES_FILE" 2>/dev/null
}

now_epoch() { date +%s; }

# ---------- known labels (persisted) ----------
# known file: MAC|nickname|danger
get_nick() {
  local mac="$1" line
  line=$(grep -F -m1 "$mac|" "$KNOWN_FILE" 2>/dev/null || true)
  [ -z "$line" ] && return 0
  printf '%s' "$line" | cut -d'|' -f2
}
is_danger() {
  local mac="$1" line d
  line=$(grep -F -m1 "$mac|" "$KNOWN_FILE" 2>/dev/null || true)
  [ -z "$line" ] && return 1
  d=$(printf '%s' "$line" | cut -d'|' -f3)
  [ "$d" = "1" ]
}
upsert_known() { # $1=MAC $2=nick $3=danger
  local mac="$1" nick="$2" danger="$3" tmp
  tmp="$KNOWN_FILE.tmp.$$.${RANDOM:-0}"
  grep -F -v "$mac|" "$KNOWN_FILE" 2>/dev/null > "$tmp" || true
  printf '%s|%s|%s\n' "$mac" "$nick" "$danger" >> "$tmp"
  mv "$tmp" "$KNOWN_FILE"
}
toggle_danger() {
  local mac="$1" nick danger line
  mac=$(norm_mac "$mac")
  [ -z "$mac" ] && { echo "bad MAC"; return 1; }
  line=$(grep -F -m1 "$mac|" "$KNOWN_FILE" 2>/dev/null || true)
  if [ -z "$line" ]; then nick=""; danger=1
  else
    nick=$(printf '%s' "$line" | cut -d'|' -f2)
    danger=$(printf '%s' "$line" | cut -d'|' -f3)
    danger=$([ "$danger" = "1" ] && echo 0 || echo 1)
  fi
  upsert_known "$mac" "$nick" "$danger"
  echo "$mac danger=$danger"
}
set_nick() {
  local mac="$1" nick="$2" danger line
  mac=$(norm_mac "$mac")
  [ -z "$mac" ] && { echo "bad MAC"; return 1; }
  nick=$(printf '%s' "$nick" | tr '|' ' ' | cut -c1-32)
  line=$(grep -F -m1 "$mac|" "$KNOWN_FILE" 2>/dev/null || true)
  danger=$(printf '%s' "$line" | cut -d'|' -f3)
  [ -z "$danger" ] && danger=0
  upsert_known "$mac" "$nick" "$danger"
}

# ---------- live device state ----------
# devices file: MAC|name|RSSI|last_epoch
update_device() { # $1=MAC $2=name $3=rssi
  local mac="$1" name="$2" rssi="$3" ts tmp old oldname oldrssi oldts
  [ -z "$mac" ] && return 0
  [ -z "$rssi" ] && return 0
  ts=$(now_epoch)
  name=$(printf '%s' "$name" | tr '|' ' ' | cut -c1-40)
  [ -z "$name" ] && name="(unknown)"
  tmp="$DEVICES_FILE.tmp.$$.${RANDOM:-0}"
  touch "$DEVICES_FILE"
  # keep every other line, then append fresh record (atomic-ish)
  grep -F -v "$mac|" "$DEVICES_FILE" 2>/dev/null > "$tmp" || true
  # preserve name if new one is unknown but old was known
  old=$(grep -F -m1 "$mac|" "$DEVICES_FILE" 2>/dev/null || true)
  if [ -n "$old" ]; then
    oldname=$(printf '%s' "$old" | cut -d'|' -f2)
    if { [ "$name" = "(unknown)" ] || [ -z "$name" ]; } && [ "$oldname" != "(unknown)" ] && [ -n "$oldname" ]; then
      name="$oldname"
    fi
  fi
  printf '%s|%s|%s|%s\n' "$mac" "$name" "$rssi" "$ts" >> "$tmp"
  mv "$tmp" "$DEVICES_FILE"
}
prune_devices() { # drop records older than $1 seconds
  local maxage="${1:-$PRUNE_AFTER}" ts cutoff tmp
  ts=$(now_epoch); cutoff=$((ts - maxage)); tmp="$DEVICES_FILE.tmp.$$.${RANDOM:-0}"
  awk -F'|' -v c="$cutoff" '$4 >= c' "$DEVICES_FILE" 2>/dev/null > "$tmp" || true
  mv "$tmp" "$DEVICES_FILE" 2>/dev/null || true
}

# ---------- bluetooth input ----------
have_bt() { command -v bluetoothctl >/dev/null 2>&1; }

start_live_scan() {
  have_bt || { echo "!! bluetoothctl not found — install BlueZ or run with --demo"; return 1; }
  # power on + start discovery. NOTE: the `scan on` session is BOTH the
  # discovery holder AND the event source — device NEW/CHG lines only
  # appear on the session that started discovery, so we parse its log.
  bluetoothctl power on >/dev/null 2>&1 || true
  # stop any previous scan loop
  stop_scan 2>/dev/null || true
  # keep discovery running in background, logging everything.
  # NB: stdbuf -oL is REQUIRED — redirected to a file, bluetoothctl's
  # stdio would otherwise block-buffer (~4K) and our tail would see
  # nothing for minutes.
  : > "$SCAN_LOG"
  # drop fossils from a previous (e.g. demo) session so the grid starts clean
  prune_devices "$STALE_AFTER" 2>/dev/null || true
  ( stdbuf -oL -eL bluetoothctl scan on >"$SCAN_LOG" 2>&1 & echo $! > "$SCAN_PID_FILE" )
  printf '0' > "$RUNTIME_DIR/scan.offset"
  sleep 1
}

stop_scan() {
  local pid
  [ -f "$SCAN_PID_FILE" ] || return 0
  pid=$(cat "$SCAN_PID_FILE" 2>/dev/null)
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  rm -f "$SCAN_PID_FILE"
  pkill -f "bluetoothctl scan on" 2>/dev/null || true
  # timeout: never let a wedged bluetoothd hang the quit path
  if have_bt; then timeout 5 bluetoothctl scan off >/dev/null 2>&1 || true; fi
}

# Parse one bluetoothctl line. Echoes "MAC|name|RSSI" or nothing.
# Handles:
#   [NEW] Device AA:BB:CC:DD:EE:FF Name...
#   [CHG] Device AA:BB:CC:DD:EE:FF RSSI: -67
#   [CHG] Device AA:BB:CC:DD:EE:FF Name: Foo
parse_bt_line() {
  local line="$1" rawmac mac rest rssi name
  rawmac=$(printf '%s' "$line" | grep -E -o '[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}' | head -n1)
  [ -z "$rawmac" ] && return 1
  mac=$(norm_mac "$rawmac")
  rest=$(printf '%s' "$line" | sed -E 's/.*'"$rawmac"'[[:space:]]*//')
  rssi=$(printf '%s' "$line" | grep -E -o 'RSSI:[[:space:]]*-?[0-9]+' | grep -E -o -- '-?[0-9]+' | head -n1)
  # name may appear after MAC ("[NEW] Device MAC Name") or as "Name: X".
  # Anything else after the MAC (RSSI/TxPower/ManufacturerData/...) is a
  # property report, NOT a name — never let it clobber the real name.
  if printf '%s' "$line" | grep -q 'Name:'; then
    name=$(printf '%s' "$line" | sed -E 's/.*Name:[[:space:]]*//')
  else
    name=$(printf '%s' "$rest" | sed -E 's/^RSSI:[[:space:]]*-?[0-9]+[[:space:]]*//; s/TxPower.*//; s/^[[:space:]]+//')
    case "$name" in
      ""|RSSI*|TxPower*|ManufacturerData*|ServiceData*|UUIDs*|Paired*|Connected*|LegacyPairing*|Icon*|Class*|Appearance*|Modalias*|CablePairing*|WakeAllowed*|Bonded*|Trusted*|Blocked*|Battery*|Advertising*)
        name="(unknown)";;
    esac
    # a bare "[NEW] Device MAC" with no name -> unknown
    case "$name" in "[NEW]"*"Device"|"Device"|"") name="(unknown)";; esac
  fi
  [ -z "$rssi" ] && rssi=""
  printf '%s|%s|%s' "$mac" "$name" "$rssi"
}

# Strip bluetoothctl TTY noise (ANSI colors, \r, control chars) so the
# parser sees plain "[CHG] Device MAC ..." lines.
clean_bt_line() {
  printf '%s' "$1" \
    | sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' -e 's/\x1b[()][0-9A-B]//g' \
    | tr -d '\000-\010\013\014\016-\037\177\r'
}

remove_device() { # $1=MAC — drop it from live state (got a [DEL] line)
  local mac="$1" tmp
  [ -z "$mac" ] && return 0
  tmp="$DEVICES_FILE.tmp.$$.${RANDOM:-0}"
  grep -F -v "$mac|" "$DEVICES_FILE" 2>/dev/null > "$tmp" || true
  mv "$tmp" "$DEVICES_FILE" 2>/dev/null || true
}

# Drain new scan-session output into device state (non-blocking tail).
drain_monitor() {
  local log="$SCAN_LOG" parsed mac name rssi cur size old line clean
  [ -f "$log" ] || return 0
  # remember offset between calls (empty/missing -> 0)
  cur=$(cat "$RUNTIME_DIR/scan.offset" 2>/dev/null || echo 0)
  [ -z "$cur" ] && cur=0
  case "$cur" in ''|*[!0-9]*) cur=0;; esac
  size=$(wc -c < "$log" 2>/dev/null || echo 0)
  [ "$size" -lt "$cur" ] && cur=0  # log rotated/truncated
  [ "$size" -eq "$cur" ] && return 0
  tail -c +"$((cur + 1))" "$log" 2>/dev/null | while IFS= read -r line; do
    clean=$(clean_bt_line "$line")
    case "$clean" in *Device*) ;;
      *) continue;;
    esac
    # gone devices: drop from the list instead of re-adding
    # (NB: brackets escaped — "[DEL]" unescaped would be a glob class
    # matching any D/E/L and eat every Device line!)
    case "$clean" in
      *\[DEL\]*)
        mac=$(printf '%s' "$clean" | grep -E -o '[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}' | head -n1)
        mac=$(norm_mac "$mac")
        remove_device "$mac"
        continue;;
    esac
    parsed=$(parse_bt_line "$clean" || true)
    [ -z "$parsed" ] && continue
    mac=$(printf '%s' "$parsed" | cut -d'|' -f1)
    name=$(printf '%s' "$parsed" | cut -d'|' -f2)
    rssi=$(printf '%s' "$parsed" | cut -d'|' -f3)
    # brand-new signal on the grid? resolve its broadcast name now (bg)
    if ! grep -F -q "$mac|" "$DEVICES_FILE" 2>/dev/null; then lookup_name_bg "$mac"; fi
    # RSSI-less NEW lines still register the device (keep old RSSI if any)
    if [ -z "$rssi" ]; then
      old=$(grep -F -m1 "$mac|" "$DEVICES_FILE" 2>/dev/null | cut -d'|' -f3 || true)
      rssi="$old"
      [ -z "$rssi" ] && rssi=-90
    fi
    update_device "$mac" "$name" "$rssi"
  done
  printf '%s' "$size" > "$RUNTIME_DIR/scan.offset"
}

# Periodic refresh via `bluetoothctl info` so RSSI stays fresh even
# when CHG events are quiet. Every ~5 ticks.
#
# Best-known name, in order: broadcast Name > adapter Alias > "".
# (Random-address Apple devices publish no Name — Alias is a
# MAC-derived stand-in, and nicknames always win at display time.)
name_from_info() { # $1 = `bluetoothctl info` text -> name or ""
  local n
  n=$(printf '%s' "$1" | grep -m1 '^[[:space:]]*Name:' | sed -E 's/.*Name:[[:space:]]*//')
  [ -z "$n" ] && n=$(printf '%s' "$1" | grep -m1 '^[[:space:]]*Alias:' | sed -E 's/.*Alias:[[:space:]]*//')
  printf '%s' "$n"
}
poll_info_refresh() {
  local mac
  cut -d'|' -f1 "$DEVICES_FILE" 2>/dev/null | while IFS= read -r mac; do
    [ -z "$mac" ] && continue
    info=$(timeout 3 bluetoothctl info "$mac" 2>/dev/null || true)
    rssi=$(printf '%s' "$info" | grep -E -o 'RSSI:[[:space:]]*-?[0-9]+' | grep -E -o -- '-?[0-9]+' | head -n1)
    name=$(name_from_info "$info")
    [ -z "$rssi" ] && continue
    [ -z "$name" ] && name="(unknown)"
    update_device "$mac" "$name" "$rssi"
  done
}

# Immediate name lookup for a just-discovered MAC (the 5-tick poll would
# get there eventually — this just makes names pop in faster).
# Rate-limited to one lookup per MAC per 2 minutes.
lookup_name_bg() { # $1=MAC
  local mac="$1" mark now last
  [ -z "$mac" ] && return 0
  command -v bluetoothctl >/dev/null 2>&1 || return 0
  mark="$RUNTIME_DIR/lookedup-$mac"
  now=$(now_epoch); last=$(cat "$mark" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0;; esac
  [ $((now - last)) -lt 120 ] && return 0
  printf '%s' "$now" > "$mark"
  ( info=$(timeout 5 bluetoothctl info "$mac" 2>/dev/null || true)
    name=$(name_from_info "$info")
    [ -z "$name" ] && exit 0
    # keep the live RSSI — info may not have one yet for fresh devices
    cur=$(grep -F -m1 "$mac|" "$DEVICES_FILE" 2>/dev/null || true)
    [ -z "$cur" ] && exit 0
    rssi=$(printf '%s' "$cur" | cut -d'|' -f3)
    update_device "$mac" "$name" "$rssi"
  ) </dev/null &
}

# ---------- demo generator (no bluetooth needed) ----------
demo_generator() {
  # background loop writing fake nearby devices with wandering RSSI
  (
  r1=-48; r2=-72; r3=-83; r4=-65
  while true; do
    # random walk
    step() { awk -v v="$1" 'BEGIN{srand(); v+=int(rand()*7)-3; if(v>-30)v=-30; if(v<-95)v=-95; print v}'; }
    r1=$(step "$r1"); r2=$(step "$r2"); r3=$(step "$r3"); r4=$(step "$r4")
    update_device "AA:BB:CC:11:22:33" "Demo Phone" "$r1"
    update_device "DE:AD:BE:EF:00:01" "Neighbor Speaker" "$r2"
    update_device "12:34:56:78:9A:BC" "Suspicious Van" "$r3"
    update_device "FE:DC:BA:98:76:54" "Smart Watch" "$r4"
    sleep 2
  done
  ) </dev/null &
  echo $! > "$MON_PID_FILE"
}
stop_demo() {
  local pid
  [ -f "$MON_PID_FILE" ] || return 0
  pid=$(cat "$MON_PID_FILE" 2>/dev/null)
  safe_kill "$pid" "hateradar.sh"
  rm -f "$MON_PID_FILE"
}

# ---------- alerts ----------
# Custom alert sound when SOUND_FILE is set, terminal bell otherwise.
# Supported players are probed in order; anything paplay/aplay/ffplay
# can decode (wav/oga/ogg/mp3/…) works. All best-effort, always silent.
play_custom() { # $1=file [$2=wait] — try each player, true if launched
  local f="$1" mode="${2:-nowait}" pid=""
  [ -r "$f" ] || return 1
  if command -v paplay >/dev/null 2>&1; then
    paplay "$f" 2>/dev/null & pid=$!
  elif command -v aplay >/dev/null 2>&1; then
    aplay -q "$f" 2>/dev/null & pid=$!
  elif command -v ffplay >/dev/null 2>&1; then
    ffplay -nodisp -autoexit -loglevel quiet "$f" 2>/dev/null & pid=$!
  elif command -v play >/dev/null 2>&1; then
    play -q "$f" 2>/dev/null & pid=$!
  else
    return 1
  fi
  # alerts fire-and-forget (never stall the radar loop); the sound
  # picker passes "wait" so the preview is fully heard
  [ "$mode" = "wait" ] && [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  return 0
}
play_bell_once() {
  printf '\a'              # terminal bell (works everywhere)
  if command -v paplay >/dev/null 2>&1; then
    (paplay /usr/share/sounds/freedesktop/stereo/bell.oga 2>/dev/null || paplay /usr/share/sounds/ubuntu/stereo/bell.ogg 2>/dev/null || true) &
  elif command -v aplay >/dev/null 2>&1; then
    (aplay -q /usr/share/sounds/alsa/Front_Center.wav 2>/dev/null || true) &
  elif command -v beep >/dev/null 2>&1; then
    (beep -f 880 -l 120 2>/dev/null || true) &
  fi
}
play_alert() { # $1 = urgency (close|very)
  local urg="$1" i n=1
  [ "$DO_BEEP" != "1" ] && return 0
  [ "$urg" = "very" ] && n=3
  for i in $(seq 1 "$n"); do
    if [ -n "$SOUND_FILE" ]; then
      play_custom "$SOUND_FILE" || play_bell_once
    else
      play_bell_once
    fi
    [ "$i" -lt "$n" ] && sleep 0.18
  done
}
# one-shot preview used by the sound picker
test_sound() {
  if [ -n "$SOUND_FILE" ]; then play_custom "$SOUND_FILE" wait || play_bell_once; else play_bell_once; fi
}
sound_status() { # short label for the HUD: bell | off | filename
  if [ "$DO_BEEP" != "1" ]; then printf 'off'
  elif [ -n "$SOUND_FILE" ]; then basename "$SOUND_FILE" 2>/dev/null || printf '%s' "$SOUND_FILE"
  else printf 'bell'; fi
}

os_notify() { # $1=mac $2=label $3=rssi
  local mac="$1" label="$2" rssi="$3" ts last
  [ "$DO_NOTIFY" != "1" ] && return 0
  command -v notify-send >/dev/null 2>&1 || return 0
  ts=$(now_epoch)
  last=$(cat "$NOTIFY_DIR/$mac" 2>/dev/null || echo 0)
  [ $((ts - last)) -lt "$NOTIFY_EVERY" ] && return 0
  printf '%s' "$ts" > "$NOTIFY_DIR/$mac"
  notify-send -u critical "Hateradar: DANGER device close" "$label ($mac) RSSI $rssi dBm" 2>/dev/null || true
  # TODO/future: replace/augment with richer OS alert (actions, persistence)
}

# ---------- distance / bars ----------
# rough distance in meters from RSSI (measured power -59 @1m, n=2)
est_meters() {
  awk -v r="$1" 'BEGIN{ tx=-59; n=2.0; d=10^((tx-r)/(10*n)); if(d<0.2)d=0.2; if(d>80)d=80; printf "%.1f", d }'
}
bar_for_rssi() { # 10-cell neon bar, more fill = closer
  awk -v r="$1" 'BEGIN{ n=int((r+100)/7); if(n<0)n=0; if(n>10)n=10; s=""; for(i=0;i<n;i++)s=s"█"; for(i=n;i<10;i++)s=s"░"; print s }'
}
ago() {
  local t=$1 ts; ts=${DRAW_NOW:-$(now_epoch)}; t=$((ts - t))
  [ "$t" -lt 0 ] && t=0
  if [ "$t" -lt 5 ]; then printf 'now'; elif [ "$t" -lt 60 ]; then printf '%ss' "$t"; else printf '%sm' "$((t/60))"; fi
}

# one grep per row instead of three (nick + 2x danger) — fewer forks,
# steadier frame timing with many devices around
known_line() { # $1=MAC -> "nick|danger" or ""
  local line
  line=$(grep -F -m1 "$1|" "$KNOWN_FILE" 2>/dev/null || true)
  [ -z "$line" ] && return 0
  printf '%s' "$line" | cut -d'|' -f2,3
}

# ---------- TUI ----------
SHOW_DANGER_ONLY=0
TICK=0
SORTED_CACHE="$RUNTIME_DIR/sorted"

rebuild_sorted() {
  # closest first (RSSI desc). keep full record + computed fields in cache.
  sort -t'|' -k3 -nr "$DEVICES_FILE" 2>/dev/null > "$SORTED_CACHE" || true
}

resolve_row_mac() { # $1 = row number (1-based in current view) -> MAC
  local n="$1"
  if [ "$SHOW_DANGER_ONLY" = "1" ]; then
    awk -F'|' '{print}' "$SORTED_CACHE" 2>/dev/null | while IFS='|' read -r mac name rssi ts; do
      is_danger "$mac" && printf '%s\n' "$mac"
    done | sed -n "${n}p"
  else
    sed -n "${n}p" "$SORTED_CACHE" 2>/dev/null | cut -d'|' -f1
  fi
}

# spinner frames for the radar sweep indicator
spinner() { # $1=tick -> one char, cycles ◢◣◤◥
  case $(( $1 % 4 )) in
    0) printf '◢';; 1) printf '◣';; 2) printf '◤';; *) printf '◥';; esac
}

draw_screen() {
  local ts i=0 count=0 close_count=0 line rowc swipe view snd kl nick dg isdg
  ts=$(date '+%H:%M:%S')
  DRAW_NOW=$(now_epoch)   # one clock read per frame, not per row
  rebuild_sorted
  # repaint in place: cursor home, paint, clear-to-end-of-screen.
  # No full clear -> no flash; stale rows from a shrinking list get wiped
  # by the trailing \033[J. Piped output keeps the scrolling separator.
  if [ "$USE_TUI" = "1" ]; then printf '\033[H'; else printf '\n--- %s ---\n' "$ts"; fi
  swipe=$(spinner "$TICK")
  view="ALL SIGNALS"; [ "$SHOW_DANGER_ONLY" = "1" ] && view="HOSTILES ONLY"
  snd=$(sound_status)
  # Whole lines get ONE color each — column alignment stays exact.
  printf "%s╔═▓▒░  H A T E R A D A R  ░▒▓═╗  v%s  :: NEON PROXIMITY GRID ::${C_OFF}\n" "$C_TITLE" "$VERSION"
  printf "%s╟─ MODE:%s  SECTOR:%s  %s %s  CLOSE≥%sdBm  SND:%s  [%s]${C_OFF}\n" \
    "$C_HEAD" "$MODE" "$ts" "$swipe" "SCANNING" "$CLOSE_RSSI" "$snd" "$view"
  printf "%s─────────────────────────────────────────────────────────────────────${C_OFF}\n" "$C_DIM"
  printf "%s %-3s %-10s %-6s %-17s %-24s %-8s %s${C_OFF}\n" \
    "$C_HEAD" "#" "PWR" "RSSI" "MAC" "DESIGNATION" "STATUS" "SEEN"
  printf "%s─────────────────────────────────────────────────────────────────────${C_OFF}\n" "$C_DIM"
  if [ ! -s "$SORTED_CACHE" ]; then
    printf "%s  // NO SIGNALS ON THE GRID — %s${C_OFF}\n" "$C_DIM" \
      "$([ "$MODE" = demo ] && echo 'ghost protocol warming up…' || echo 'check bluetooth is ON and devices are advertising…')"
  fi
  while IFS='|' read -r mac name rssi lts; do
    [ -z "$mac" ] && continue
    if [ "$SHOW_DANGER_ONLY" = "1" ]; then is_danger "$mac" || continue; fi
    i=$((i + 1)); count=$((count + 1))
    [ "$i" -gt 30 ] && break
    kl=$(known_line "$mac")
    nick=""; dg=""
    if [ -n "$kl" ]; then nick="${kl%|*}"; dg="${kl##*|}"; fi
    label="$name"; [ -n "$nick" ] && [ "$nick" != "$name" ] && label="$nick [$name]"
    [ -n "$nick" ] && [ "$nick" = "$name" ] && label="$nick"
    [ "$label" = "(unknown)" ] && label="UNKNOWN SIGNAL"
    flags="·······"
    rowc="$C_ROW"
    isdg=0; [ "$dg" = "1" ] && { flags="HOSTILE"; rowc="$C_WARN"; isdg=1; }
    age=$((DRAW_NOW - lts))
    seen=$(ago "$lts")
    stale=""
    [ "$age" -gt "$STALE_AFTER" ] && { stale="GHOST"; rowc="$C_DIM"; }
    close=""
    if [ "$isdg" = "1" ] && [ "$rssi" -ge "$CLOSE_RSSI" ] 2>/dev/null; then
      close=">> PROXIMITY"; close_count=$((close_count+1)); rowc="$C_DANGER"; stale=""
    fi
    meters=$(est_meters "$rssi")
    bar=$(bar_for_rssi "$rssi")
    line=$(printf ' %-3s %-10s %-6s %-17s %-24s %-8s %s %s %s' \
      "$i" "${bar} ${meters}m" "$rssi" "$mac" "$(printf '%.24s' "$label")" "$flags" "$seen" "$stale" "$close")
    printf "%s%s${C_OFF}\n" "$rowc" "$line"
  done < "$SORTED_CACHE"
  # clear any leftover rows below the list (shrinking device count)
  if [ "$USE_TUI" = "1" ]; then printf '\033[J'; fi
  printf "%s─────────────────────────────────────────────────────────────────────${C_OFF}\n" "$C_DIM"
  printf "%s contacts:%s  proximity alerts:%s${C_OFF}\n" "$C_OK" "$count" "$close_count"
  printf "%s [D]anger  [N]ick  [S]ound  [T]hreshold  [C]lear ghosts${C_OFF}\n" "$C_TITLE"
  printf "%s [L] all/hostiles  [Q] jack out${C_OFF}\n" "$C_TITLE"
}

prompt_line() { # $1=prompt text -> echoes answer; restores screen after
  local p="$1" ans
  # NOTE: prompt goes to stderr — callers capture stdout via $(...)
  cursor_show
  printf '\n%s ' "$p" >&2
  # canonical read (needs Enter) — works in bash and zsh
  IFS= read -r ans || ans=""
  cursor_hide
  printf '%s' "$ans"
}

do_toggle_flow() {
  local sel mac out
  sel=$(prompt_line "Toggle danger — row # or MAC (empty=cancel):")
  [ -z "$sel" ] && return 0
  case "$sel" in
    ''|*[!0-9]*) mac=$(norm_mac "$sel") ;;
    *) mac=$(resolve_row_mac "$sel"); [ -z "$mac" ] && mac=$(norm_mac "$sel");;
  esac
  if [ -z "$mac" ]; then printf '\n ?? no such row/device. Enter to continue.'; press_enter; return 0; fi
  out=$(toggle_danger "$mac")
  printf '\n %s. Enter to continue.' "$out"; press_enter
}

do_nick_flow() {
  local sel mac nick
  sel=$(prompt_line "Nickname — row # or MAC (empty=cancel):")
  [ -z "$sel" ] && return 0
  case "$sel" in
    ''|*[!0-9]*) mac=$(norm_mac "$sel") ;;
    *) mac=$(resolve_row_mac "$sel"); [ -z "$mac" ] && mac=$(norm_mac "$sel");;
  esac
  if [ -z "$mac" ]; then printf '\n ?? no such row/device. Enter to continue.'; press_enter; return 0; fi
  nick=$(prompt_line "Nickname for $mac (empty=clear):")
  set_nick "$mac" "$nick"
  printf '\n ok. Enter to continue.'; press_enter
}

do_threshold_flow() {
  local v
  v=$(prompt_line "Close threshold dBm (now $CLOSE_RSSI, e.g. -70):")
  case "$v" in ''|*[!0-9-]*) : ;; *) CLOSE_RSSI="$v"; save_config;; esac
}

do_sound_flow() {
  local cur p expanded
  cur="${SOUND_FILE:-<terminal bell>}"
  p=$(prompt_line "Alert sound file (now: $cur) — path, 'off' for bell, empty=cancel:")
  [ -z "$p" ] && return 0
  if [ "$p" = "off" ]; then
    SOUND_FILE=""; save_config
    printf '\n alert sound: terminal bell. Enter to continue.'; press_enter
    return 0
  fi
  # expand ~ and $HOME, keep the rest literal
  case "$p" in "~"*) expanded="$HOME${p#\~}";; *) expanded="$p";; esac
  if [ ! -r "$expanded" ]; then
    printf '\n ?? cannot read that file. Enter to continue.'; press_enter
    return 0
  fi
  SOUND_FILE="$expanded"; save_config
  printf '\n alert sound set — previewing…\n' >&2
  test_sound
  printf ' Enter to continue.'; press_enter
}

# single-key non-blocking read, bash+zsh compatible. echoes key or "".
read_key() { # $1=timeout secs
  local t="$1" k=""
  if is_zsh; then
    # shellcheck disable=SC2162
    if read -t "$t" -k 1 k 2>/dev/null; then printf '%s' "$k"; fi
  else
    if IFS= read -t "$t" -n 1 -s -r k 2>/dev/null; then printf '%s' "$k"; fi
  fi
}

check_alerts() {
  local worst="" worst_rssi=-999 mac name rssi lts nick label
  while IFS='|' read -r mac name rssi lts; do
    [ -z "$mac" ] && continue
    is_danger "$mac" || continue
    if [ "$rssi" -ge "$CLOSE_RSSI" ] 2>/dev/null; then
      if [ "$rssi" -ge "$worst_rssi" ] 2>/dev/null; then worst="$mac"; worst_rssi="$rssi"; fi
    fi
  done < "$SORTED_CACHE"
  if [ -n "$worst" ]; then
    if [ "$worst_rssi" -ge "$VERY_CLOSE_RSSI" ] 2>/dev/null; then play_alert very; else play_alert close; fi
    nick=$(get_nick "$worst"); label="$worst"; [ -n "$nick" ] && label="$nick ($worst)"
    os_notify "$worst" "$label" "$worst_rssi"
  fi
}

CLEANED=0
cleanup() {
  [ "$CLEANED" = "1" ] && return 0
  CLEANED=1
  tui_leave   # restore terminal FIRST so goodbye text lands on solid ground
  printf '\n stopping scan…\n'
  if [ "$MODE" = "demo" ]; then
    stop_demo || true
  else
    stop_scan || true
  fi
  printf 'labels + settings saved in %s. jacked out. bye.\n' "$CONFIG_DIR"
  trap - EXIT INT TERM
  exit 0
}

# ---------- args ----------
while [ $# -gt 0 ]; do
  case "$1" in
    --demo) MODE="demo"; shift;;
    --live) MODE="live"; shift;;
    --interval) INTERVAL="$2"; shift 2;;
    --close) CLOSE_RSSI="$2"; CLOSE_FROM_FLAG=1; shift 2;;
    --sound) SOUND_FILE="$2"; SOUND_FROM_FLAG=1; shift 2;;
    --no-beep) DO_BEEP=0; shift;;
    --no-notify) DO_NOTIFY=0; shift;;
    --stale) STALE_AFTER="$2"; shift 2;;
    --color) COLOR_REQ="on"; shift;;
    --no-color) COLOR_REQ="off"; shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown flag: $1 (try --help)"; exit 1;;
  esac
done

# ---------- main ----------
# demo and live keep SEPARATE state files — fake signals can never bleed
# into the real grid (or vice versa). Resolve before ensure_dirs touches it.
DEVICES_FILE="$RUNTIME_DIR/devices.$MODE"
ensure_dirs
load_config             # saved threshold/sound fill in whatever flags didn't set
trap cleanup INT TERM EXIT

# Shut down any leftover scanner from the other mode first
# (stale pidfile from a killed run).
stop_demo 2>/dev/null || true
stop_scan 2>/dev/null || true
touch "$DEVICES_FILE" 2>/dev/null

# a --sound path that can't be read falls back to the bell (loud complaint)
if [ -n "$SOUND_FILE" ] && [ ! -r "$SOUND_FILE" ]; then
  printf '!! alert sound unreadable: %s — falling back to bell\n' "$SOUND_FILE"
  SOUND_FILE=""
fi

# resolve neon UI: forced off > NO_COLOR env > non-terminal stdout
if [ "$COLOR_REQ" = "off" ] || [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then USE_COLOR=0; else USE_COLOR=1; fi
[ "$COLOR_REQ" = "on" ] && USE_COLOR=1
theme_init
# alt-screen TUI only on a real terminal (never on pipes — see USE_TUI).
# --color forces COLORS, not the alt screen: logs stay scrollable.
if [ -t 1 ] && [ -t 0 ]; then USE_TUI=1; else USE_TUI=0; fi

printf '0' > "$RUNTIME_DIR/scan.offset" 2>/dev/null || true

if [ "$MODE" = "demo" ]; then
  : > "$DEVICES_FILE"
  demo_generator
else
  if ! have_bt; then
    echo "bluetoothctl not found. Install BlueZ (sudo apt install bluez) or run with --demo."
    exit 1
  fi
  start_live_scan || exit 1
fi

printf 'Hateradar starting (%s mode)… press q to quit.\n' "$MODE"
sleep 1
tui_enter

while true; do
  if [ "$MODE" = "live" ]; then
    drain_monitor
    TICK=$((TICK + 1))
    # refresh RSSI via info every ~5 redraws so quiet devices stay fresh
    # (backgrounded + stdin closed so prompts never block on it)
    if [ $((TICK % 5)) -eq 0 ]; then poll_info_refresh </dev/null & fi
  fi
  draw_screen
  check_alerts
  key=$(read_key "$INTERVAL")
  case "$key" in
    q|Q) cleanup;;
    d|D) do_toggle_flow;;
    n|N) do_nick_flow;;
    s|S) do_sound_flow;;
    t|T) do_threshold_flow;;
    c|C) prune_devices "$STALE_AFTER"; printf '\n cleared. Enter to continue.'; press_enter;;
    l|L) if [ "$SHOW_DANGER_ONLY" = "1" ]; then SHOW_DANGER_ONLY=0; else SHOW_DANGER_ONLY=1; fi;;
    "") : ;; # timeout — just redraw
    *) : ;;
  esac
done
