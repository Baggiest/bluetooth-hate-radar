# hateradar — bluetooth proximity radar

A tiny `bash`/`zsh` client with a neon cyberpunk UI that watches your
Bluetooth adapter's **live** data and ranks nearby devices
**closest → farthest** by signal strength (RSSI). Mark a device as
**danger**, give it a **nickname**, pick a **custom alert sound**, and
the app keeps running and raises hell when that device gets close.

```
╔═▓▒░  H A T E R A D A R  ░▒▓═╗  v0.2.0  :: NEON PROXIMITY GRID ::
╟─ MODE:live  SECTOR:12:00:01  ◢ SCANNING  CLOSE≥-70dBm  SND:sonar.ogg
 #   PWR        RSSI   MAC               DESIGNATION              STATUS   SEEN
 1   ███████░░░ 0.4m -50   AA:BB:CC:11:22:33  Scary [Pixel 8]  HOSTILE  now  >> PROXIMITY
 [D]anger  [N]ick  [S]ound  [T]hreshold  [C]lear ghosts
 [L] all/hostiles  [Q] jack out
```

Row colors: **red** = hostile + close (alerting), **yellow** = hostile,
**cyan** = tracked, **dim** = ghost (stale). `--no-color` (or piping,
or `NO_COLOR=1`) falls back to plain text; `--color` forces neon on.

## Requirements

- Linux with BlueZ (`bluetoothctl`) — check with `bluetoothctl list`
- Alert audio: any of `paplay` / `aplay` / `ffplay` / `play` (sox) for
  custom sounds, else the terminal bell. Desktop alerts via
  `notify-send` if present.

## Run

```bash
bash hateradar.sh                                   # live mode (default)
bash hateradar.sh --demo                            # simulated devices
bash hateradar.sh --sound ~/sounds/airhorn.wav      # custom alert sound
bash hateradar.sh --help                            # all flags
```

Demo and live keep **separate** device lists (`devices.demo` vs
`devices.live` under `/tmp/hateradar-$USER/`) — the simulator's fake
signals can never leak into your real grid, and starting one mode stops
a leftover scanner from the other.

Useful flags: `--close -70` (RSSI at/above which a danger device counts
as "close"), `--no-beep`, `--no-notify`, `--interval 2`, `--stale 45`,
`--color` / `--no-color`.

## Keys (while running)

| key | action |
|-----|--------|
| `d` | toggle **danger** on a device (row `#` or `MAC`) → shown as `HOSTILE` |
| `n` | set a **nickname** for a device (row `#` or `MAC`) |
| `s` | set the **alert sound**: file path, `off` for the bell (previews + saves) |
| `t` | change the close-threshold in dBm, e.g. `-70` (saved) |
| `c` | clear stale (`GHOST`) devices |
| `l` | toggle all-devices vs hostiles-only view |
| `q` | quit (also `Ctrl-C`) |

## Custom alert sound

Pass `--sound FILE` or press `s` inside the app. Any audio your player
understands works (`wav`/`oga`/`ogg`/`mp3`…). The choice is saved to
`~/.config/hateradar/config` and auto-loaded next launch; `off` (or an
unreadable file) falls back to the terminal bell. Triple-play when very
close (≥ `-55` dBm). Try `/usr/share/sounds/gnome/default/alerts/` —
`sonar.ogg` fits the theme suspiciously well.

## Device names

The grid shows each device's broadcast **Name** when it sends one, the
adapter **Alias** otherwise, and your **nickname** always wins when set.
Honest limitation: privacy-conscious gadgets (iPhones etc. with rotating
random addresses) broadcast *no* name at all — there BlueZ only knows
the alias (often just the MAC with dashes) plus signal data. The app
looks names up the moment a new signal appears and refreshes them on
every poll, so anything that *does* identify itself shows up within
seconds. When in doubt: `n` it and name the ghost yourself.

## How it works

- On start: `bluetoothctl power on` + background `bluetoothctl scan on`,
  whose output is parsed for `[NEW]`/`[CHG]` `MAC`, `Name`/`Alias` and
  `RSSI` lines (device events only appear on the session that started
  discovery, so that session is both the scanner and the event source;
  `stdbuf -oL` keeps its output line-buffered so the UI sees it instantly,
  and ANSI/color noise is stripped before parsing). Every ~5 redraws,
  `info <MAC>` is polled so quiet devices stay fresh.
- Distance is a rough estimate from RSSI
  (`10^((-59-RSSI)/20)` m) — good for ranking, not measuring.
- Labels persist in `~/.config/hateradar/known` as
  `MAC|nickname|danger(0/1)`; threshold + sound in
  `~/.config/hateradar/config`; live state lives under
  `/tmp/hateradar-$USER/`.
- Runs under both `bash` and `zsh` (single-key input adapts:
  `read -n` vs `read -k`).

## Files

- `hateradar.sh` — the whole app (one file)
