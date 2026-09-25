# moon tuning — Mac mini "moon" (M5 Pro, 64 GB, macOS 26)

Always-on LLM box + Odd Signal hub, tailnet-only. Moderate profile: reversible `pmset` / `defaults` / launchd changes; SIP, FileVault, firewall and keys-only sshd untouched. Driven from the Air via Universal Control + SSH/mosh (no Screen Sharing).

| Part | Script | When |
|---|---|---|
| 1 | `moon-tune.sh` | Now |
| 2 | `moon-network.sh` | After Ethernet goes in (28 Sep) |

```sh
# MINI
./macos/moon-tune.sh --dry-run          # preview, changes nothing
./macos/moon-tune.sh                    # apply
./macos/moon-tune.sh --only gpu,llm     # apply some sections
```
It refuses to run on any host not named `moon`.

## Part 1 — what each section does

| Section | Change | Purpose | Undo |
|---|---|---|---|
| `power` | `sleep 0`, `disksleep 0`, `displaysleep 15`, `autorestart 1`, `powernap 0`, `ttyskeepawake 1`, power mode Automatic, restart after freeze, screen saver off | Services never go to sleep; Mini powers back on after a cut and reboots itself after a kernel hang; no maintenance wakes competing with overnight jobs; screen saver off so it can't break a Universal Control session | `sudo pmset restoredefaults` |
| `lock` | Reports screen-lock state; turns it off only if `SCREEN_LOCK=off` | Universal Control only connects to a Mac that is awake **and unlocked** | System Settings > Lock Screen |
| `ups` | `pmset -u haltlevel 20 haltremain 5` | Clean shutdown before the lead-acid UPS runs flat; `autorestart` boots when mains returns | `sudo pmset -u haltlevel 0 haltremain 0` |
| `updates` | Check + download on; auto-install macOS **off**; security responses + XProtect data on | An unattended upgrade reboots into the FileVault screen and takes everything down | Settings > General > Software Update |
| `background` | Siri off, App Nap off | Siri's background work gone; App Nap no longer throttles background GUI apps (Obsidian Sync, LM Studio app) | `defaults delete <domain> <key>` |
| `gpu` | `iogpu.wired_limit_mb=57344` now + LaunchDaemon re-applying it every boot | Metal's ceiling goes from ~48 GB to 56 GB so tier 1 + tier 0 + KV cache sit on the GPU together. A cap, not a reservation — RAM goes back to Blender/video when models unload | `sudo sysctl iogpu.wired_limit_mb=0`; `sudo launchctl bootout system/net.oddsignal.gpu-wired-limit`; delete the plist |
| `llm` | `~/.local/bin/moon-llm-up` + LaunchAgent (login, then every 5 min): `lms daemon up`, server on `:1234` if down, tier 0 pinned as `tier0` | Headless model server that restarts itself within 5 min of any crash | `launchctl bootout gui/$UID/net.oddsignal.llm-up`; delete the plist |
| `serve` | `tailscale serve --bg --https=<port> --set-path=<path> <target>` per `SERVE_MAP` line | Real HTTPS on `moon.<tailnet>.ts.net`; apps stay on 127.0.0.1; only tailnet devices can reach them. Works over Wi-Fi or Ethernet | `tailscale serve reset` |
| `backup` | Sticky `tmutil addexclusion` on models/caches/containers | Backups spent on the vault and repos, not 30 GB of weights | `tmutil removeexclusion <path>` |
| `firewall` | Application firewall on | Blocks unapproved inbound connections from the shared home network; Apple services (incl. Universal Control), Tailscale and sshd still pass | `socketfilterfw --setglobalstate off` |
| `tools` | `brew install macmon` | Live GPU/power/RAM view to watch the model ladder | `brew uninstall macmon` |

### Model ladder on LM Studio
- Tier 0: `lms load`, no TTL → always resident, never auto-evicted.
- Tier 1 / 2: loaded on first request (JIT), unloaded after 60 idle min. Auto-Evict keeps at most one JIT model loaded, so they never stack.
- Free RAM for a render: `lms unload --all` (tier 0 returns within 5 min) or `lms unload <tier-1 id>`.

### Universal Control notes
- It needs the Mini **awake and unlocked**, with Wi-Fi, Bluetooth and Handoff on (never turn the Mini's Wi-Fi radio off, even on Ethernet).
- A sleeping display often won't wake from a pushed cursor. Wake it from the Air: `ssh moon caffeinate -u -t 3` (alias `wakemoon`).
- It can't reach the FileVault unlock screen or the login window. **Keep a keyboard plugged into the Mini** for unlocking after any reboot.

### Deliberately not done
- Animation / transparency tweaks: they only helped Screen Sharing; with Universal Control the Mini renders locally and the saving is negligible.
- Spotlight: `~/.lmstudio` and `~/.cache` are dot-folders and already skipped.
- SIP, swap, system daemons: untouched.
- High Power Mode: ~5% CPU gain, less for token generation. Flip `POWER_MODE=high` for render nights.

## Part 2 — deferred until Ethernet (28 Sep)
- `womp 1` (wake on Ethernet), `tcpkeepalive 1`
- Ethernet above Wi-Fi in service order
- Verify default route on Ethernet; DHCP reservation for the Ethernet IP
- Remote-recovery checks: FileVault, Remote Login, pre-boot SSH unlock test
- Decide how to reach the login window after a remote unlock (Universal Control can't): keyboard at the desk, or Screen Sharing as a recovery-only tool

## Sources
Pre-boot SSH unlock: `man apple_ssh_and_filevault`. LM Studio headless + JIT/TTL: lmstudio.ai/docs/developer/core. GPU cap: community notes on `iogpu.wired_limit_mb`. Spotlight exclusions: Eclectic Light Co. Tailscale Serve flags: tailscale.com/kb/1311. Universal Control requirements: support.apple.com/102459.
