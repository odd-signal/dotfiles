#!/usr/bin/env bash
# moon-tune.sh — PART 1 of the Mac mini "moon" tuning: everything except Wi-Fi/Ethernet.
# (Part 2, moon-network.sh, follows once Ethernet is in on 28 Sep.)
# Idempotent: every step checks current state and only changes drift. Safe to re-run.
# Usage: ./moon-tune.sh [--dry-run] [--only power,gpu,...] [--list] [--force]
# Rationale + undo commands: README.md in this folder.
set -euo pipefail

# ============================== CONFIG ==============================
GPU_WIRED_LIMIT_MB=57344      # 56 GiB of 64 for Metal. 0 = macOS default (~75%)
POWER_MODE=auto               # auto | high  (high = louder fans, small gain; LLM decode is bandwidth-bound)
DISPLAY_SLEEP_MIN=15          # 0 = display never sleeps (Universal Control always connects, monitor always on)
SCREEN_LOCK=leave             # leave | off  (off = no password after display sleep; Universal Control can't reach a locked Mac)
UPS_HALT_LEVEL=20             # shut down cleanly at this UPS battery %
UPS_HALT_REMAIN=5             # ...or at this many minutes of runtime left
LMS_PORT=1234
TIER0_MODEL="qwen/qwen3.6-35b-a3b"
TIER0_ID="qwen/qwen3.6-35b-a3b"
# Tailscale Serve map: "https_port|path|local_target". Services must bind 127.0.0.1.
# Path mounts (/x) only work for apps that support a base path; otherwise give the app its own port.
SERVE_MAP=(
  "443|/|http://127.0.0.1:4870"   # add at the dashboard cutover
  "8443|/|http://127.0.0.1:1234"     # LM Studio API (the Air's dispatcher can use it now)
  "10000|/|http://127.0.0.1:8787"    # invoice
  "10001|/|http://127.0.0.1:8020"    # stockwatch
  "10002|/|http://127.0.0.1:8420"    # dimmer
)

# Kept out of Time Machine (re-downloadable or regenerable). Skipped if missing.
TM_EXCLUDE=(
  "$HOME/.lmstudio/models"
  "$HOME/.cache/huggingface"
  "$HOME/Library/Caches"
  "$HOME/.orbstack"
  "$HOME/Library/Containers/com.docker.docker"
)
# ====================================================================

SECTIONS="power lock ups updates background gpu llm serve backup firewall tools"
DRY=0; ONLY=""; FORCE=0
LABEL_PREFIX="net.oddsignal"
LOG_DIR="$HOME/Library/Logs/oddsignal"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
chg()  { printf '    \033[33m↻\033[0m %s\n' "$*"; }
warn() { printf '    \033[31m!\033[0m %s\n' "$*"; }
run()  { if [[ $DRY == 1 ]]; then printf '      [dry] %s\n' "$*"; else "$@" || warn "failed: $*"; fi; }
want() { [[ -z $ONLY || ",$ONLY," == *",$1,"* ]]; }

while (($#)); do
  case $1 in
    --dry-run) DRY=1 ;;
    --only)    ONLY=${2:?--only needs a list}; shift ;;
    --force)   FORCE=1 ;;
    --list)    echo "$SECTIONS"; exit 0 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac; shift
done

[[ $(uname) == Darwin ]] || { echo "macOS only" >&2; exit 1; }
HOST=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
if [[ $HOST != moon && $FORCE != 1 ]]; then
  echo "This is '$HOST', not 'moon'. Refusing (use --force if you mean it)." >&2; exit 1
fi

# One sudo prompt, kept alive for the run
sudo -v
while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &

# ---------- helpers ----------
pm() { # pmset key value (all power sources); skips keys this Mac doesn't support
  local k=$1 v=$2 cur
  pmset -g cap | grep -qw "$k" || { warn "pmset $k not supported here — skipped"; return 0; }
  cur=$(pmset -g | awk -v k="$k" '$1==k{print $2; exit}')
  if [[ $cur == "$v" ]]; then ok "pmset $k=$v"
  else chg "pmset $k: ${cur:-unset} -> $v"
  run sudo pmset -a "$k" "$v" || warn "pmset rejected $k=$v — skipped"; fi
}

dw() { # domain key type value   (user defaults)
  local dom=$1 key=$2 typ=$3 val=$4 want=$4 cur
  if [[ $typ == bool ]]; then [[ $val == true ]] && want=1 || want=0; fi
  cur=$(defaults read "$dom" "$key" 2>/dev/null || echo "unset")
  if [[ $cur == "$want" ]]; then ok "$dom $key=$val"
  else chg "$dom $key: $cur -> $val"
    run defaults write "$dom" "$key" -"$typ" "$val" || warn "write blocked (TCC) — set it in System Settings"; fi
}

dws() { # same, as root (system-wide prefs)
  local dom=$1 key=$2 typ=$3 val=$4 want=$4 cur
  if [[ $typ == bool ]]; then [[ $val == true ]] && want=1 || want=0; fi
  cur=$(sudo defaults read "$dom" "$key" 2>/dev/null || echo "unset")
  if [[ $cur == "$want" ]]; then ok "$dom $key=$val"
  else chg "$dom $key: $cur -> $val"
    run sudo defaults write "$dom" "$key" -"$typ" "$val" || warn "write failed — set it in System Settings"; fi
}

install_plist() { # scope(system|gui) path content
  local scope=$1 path=$2 content=$3 label tmp
  label=$(basename "$path" .plist); tmp=$(mktemp)
  printf '%s\n' "$content" > "$tmp"
  if [[ -f $path ]] && cmp -s "$tmp" "$path"; then ok "$label up to date"; rm -f "$tmp"; return 0; fi
  chg "installing $path"
  if [[ $scope == system ]]; then
    run sudo cp "$tmp" "$path"; run sudo chown root:wheel "$path"; run sudo chmod 644 "$path"
    [[ $DRY == 1 ]] || sudo launchctl bootout "system/$label" 2>/dev/null || true
    run sudo launchctl bootstrap system "$path" || warn "bootstrap failed for $label"
  else
    run mkdir -p "$(dirname "$path")" "$LOG_DIR"; run cp "$tmp" "$path"
    [[ $DRY == 1 ]] || launchctl bootout "gui/$UID/$label" 2>/dev/null || true
    run launchctl bootstrap "gui/$UID" "$path" \
      || warn "bootstrap failed — is broto logged in on the Mini? It will load at next login"
  fi
  rm -f "$tmp"
}

# ---------- sections ----------
sec_power() {
  log "Power: never sleep, restart after power loss/freeze, no screen saver"
  pm sleep 0
  pm disksleep 0
  pm displaysleep "$DISPLAY_SLEEP_MIN"
  pm autorestart 1
  pm powernap 0
  pm ttyskeepawake 1
  if [[ $POWER_MODE == high ]]; then
    if pmset -g cap | grep -qw powermode; then pm powermode 2
    elif pmset -g cap | grep -qw highpowermode; then pm highpowermode 1
    else warn "no power-mode key on this Mac — skipped"; fi
  else
    ok "power mode left on Automatic (macOS default)"
  fi
  if sudo systemsetup -getrestartfreeze 2>/dev/null | grep -q "On"; then ok "restart after freeze on"
  else chg "restart after freeze -> on"
    run sudo systemsetup -setrestartfreeze on >/dev/null 2>&1 \
      || warn "systemsetup blocked — give Terminal Full Disk Access, then re-run --only power"
  fi
  local ss; ss=$(defaults -currentHost read com.apple.screensaver idleTime 2>/dev/null || echo unset)
  if [[ $ss == 0 ]]; then ok "screen saver off"
  else chg "screen saver idleTime: $ss -> 0"; run defaults -currentHost write com.apple.screensaver idleTime -int 0; fi
}

sec_lock() {
  log "Screen lock vs Universal Control"
  local st; st=$(sysadminctl -screenLock status 2>&1 || true)
  if grep -qi "off" <<<"$st"; then ok "screen lock off — Universal Control can always connect"; return 0; fi
  if [[ $SCREEN_LOCK == off ]]; then
    chg "screen lock -> off (you'll be asked for your macOS password)"
    run sysadminctl -screenLock off -password - || warn "failed — set Lock Screen > 'Require password' to Never in System Settings"
  else
    warn "screen lock is ON (${st##*: }). If Universal Control won't connect after the display sleeps, set SCREEN_LOCK=off"
  fi
}

sec_ups() {
  log "UPS: clean shutdown before the battery dies (autorestart brings it back)"
  if pmset -g ps | grep -q '^ -'; then ok "UPS detected: $(pmset -g ps | awk -F'\t' '/^ -/{print $1; exit}' | sed 's/^ -//')"
  else warn "no UPS seen — connect its USB data cable; thresholds applied anyway"; fi
  chg "pmset -u haltlevel $UPS_HALT_LEVEL haltremain $UPS_HALT_REMAIN (always re-applied)"
  run sudo pmset -u haltlevel "$UPS_HALT_LEVEL" haltremain "$UPS_HALT_REMAIN"
}

sec_updates() {
  log "Updates: no surprise macOS installs/reboots; security responses stay automatic"
  local d=/Library/Preferences/com.apple.SoftwareUpdate
  dws "$d" AutomaticCheckEnabled bool true
  dws "$d" AutomaticDownload bool true
  dws "$d" AutomaticallyInstallMacOSUpdates bool false
  dws "$d" CriticalUpdateInstall bool true
  dws "$d" ConfigDataInstall bool true
}

sec_background() {
  log "Background: Siri off, App Nap off"
  dw com.apple.assistant.support "Assistant Enabled" bool false
  dw com.apple.Siri StatusMenuVisible bool false
  dw NSGlobalDomain NSAppSleepDisabled bool true
}

sec_gpu() {
  log "GPU wired-memory cap: ${GPU_WIRED_LIMIT_MB} MB (ceiling, not a reservation)"
  local cur; cur=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo "?")
  if [[ $cur == "$GPU_WIRED_LIMIT_MB" ]]; then ok "live value already $cur"
  else chg "live iogpu.wired_limit_mb: $cur -> $GPU_WIRED_LIMIT_MB"
    run sudo sysctl iogpu.wired_limit_mb="$GPU_WIRED_LIMIT_MB" >/dev/null; fi
  install_plist system "/Library/LaunchDaemons/$LABEL_PREFIX.gpu-wired-limit.plist" "$(cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL_PREFIX.gpu-wired-limit</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/sbin/sysctl</string>
    <string>iogpu.wired_limit_mb=$GPU_WIRED_LIMIT_MB</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
)"
}

sec_llm() {
  log "LLM: llmster headless daemon + server, tier-0 pinned, self-healing every 5 min"
  local lms="$HOME/.lmstudio/bin/lms" up="$HOME/.local/bin/moon-llm-up" tmp
  if [[ ! -x $lms ]]; then
    warn "lms not found. Install llmster first:  curl -fsSL https://lmstudio.ai/install.sh | bash"
    return 0
  fi
  tmp=$(mktemp)
  cat > "$tmp" <<EOF
#!/bin/bash
# Generated by moon-tune.sh — edit the config there, not here.
# Idempotent: start llmster + API server, keep tier-0 pinned (no TTL, immune to JIT auto-evict).
LMS="$lms"; PORT=$LMS_PORT; TIER0_MODEL="$TIER0_MODEL"; TIER0_ID="$TIER0_ID"
"\$LMS" daemon up >/dev/null 2>&1 || true
curl -sf "http://127.0.0.1:\$PORT/v1/models" >/dev/null || "\$LMS" server start --port "\$PORT"
if [ -n "\$TIER0_MODEL" ] && ! "\$LMS" ps 2>/dev/null | grep -q "\$TIER0_ID"; then
  "\$LMS" load "\$TIER0_MODEL" --identifier "\$TIER0_ID" -y
fi
EOF
  if [[ -f $up ]] && cmp -s "$tmp" "$up"; then ok "moon-llm-up up to date"
  else chg "writing $up"; run mkdir -p "$(dirname "$up")"; run cp "$tmp" "$up"; run chmod +x "$up"; fi
  rm -f "$tmp"
  [[ -z $TIER0_MODEL ]] && warn "TIER0_MODEL empty — server runs, nothing pinned (JIT only)"
  install_plist gui "$HOME/Library/LaunchAgents/$LABEL_PREFIX.llm-up.plist" "$(cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL_PREFIX.llm-up</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$up</string></array>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>$HOME/.lmstudio/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>300</integer>
  <key>StandardOutPath</key><string>$LOG_DIR/llm-up.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/llm-up.log</string>
</dict>
</plist>
EOF
)"
}

sec_serve() {
  log "Tailscale Serve: tailnet-only HTTPS for the hub's web apps (works over any link)"
  local ts="" entry port path target
  if command -v tailscale >/dev/null; then ts=$(command -v tailscale)
  elif [[ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]]; then ts=/Applications/Tailscale.app/Contents/MacOS/Tailscale
  else warn "tailscale CLI not found — skipped"; return 0; fi
  if [[ ${#SERVE_MAP[@]} -eq 0 ]]; then warn "SERVE_MAP is empty — add your dashboard/app ports in the config"; return 0; fi
  for entry in ${SERVE_MAP[@]+"${SERVE_MAP[@]}"}; do
    IFS='|' read -r port path target <<<"$entry"
    chg "serve https:$port$path -> $target (re-applied; same config = no-op)"
    run "$ts" serve --bg --https="$port" --set-path="$path" "$target" \
      || warn "serve failed — is HTTPS enabled in the Tailscale admin console?"
  done
  [[ $DRY == 1 ]] || "$ts" serve status || true
}

sec_backup() {
  log "Time Machine: exclude models/caches/containers"
  local p
  for p in ${TM_EXCLUDE[@]+"${TM_EXCLUDE[@]}"}; do
    [[ -e $p ]] || continue
    if tmutil isexcluded "$p" 2>/dev/null | grep -q '\[Excluded\]'; then ok "excluded: $p"
    else chg "excluding $p"; run tmutil addexclusion "$p"; fi
  done
  if tmutil destinationinfo 2>/dev/null | grep -q "Name"; then ok "Time Machine destination set"
  else warn "no Time Machine destination yet — your vault backup plan needs one"; fi
}

sec_firewall() {
  log "Application firewall on (Apple services, Tailscale, sshd keep working)"
  local fw=/usr/libexec/ApplicationFirewall/socketfilterfw
  if $fw --getglobalstate | grep -q enabled; then ok "firewall enabled"
  else chg "firewall -> on"; run sudo $fw --setglobalstate on >/dev/null; fi
}

sec_tools() {
  log "Monitoring: macmon (sudoless Apple Silicon power/GPU/RAM monitor)"
  command -v brew >/dev/null || { warn "brew missing"; return 0; }
  if brew list macmon >/dev/null 2>&1; then ok "macmon installed"
  else chg "installing macmon"; run brew install macmon; fi
}

# ---------- main ----------
[[ $DRY == 1 ]] && echo "DRY RUN — nothing will change."
for s in $SECTIONS; do want "$s" && "sec_$s"; done
log "Done. Re-run any time; only drift gets changed. Network items wait for moon-network.sh (28 Sep)."
