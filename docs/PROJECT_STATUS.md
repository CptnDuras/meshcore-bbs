# meshbbs — Project Status & Key Decisions

_Snapshot summary of what's been built and the decisions behind it._

## Environment
- FreeBSD 15.1 host `titan`; user `steve` (wheel + dialer, passwordless sudo); V 0.5.2.
- `meshbbs` project: `/home/steve/projects/meshbbs` (V language).
- `meshcore-v` module: `/home/steve/projects/meshcore-v` — **separate git repo**
  (`git@github.com:CptnDuras/meshcore-v.git`), symlinked into `~/.vmodules/meshcore`.
  This is a dependency, not part of the meshbbs repo.
- Radio: Heltec V3 / MeshCore on `/dev/cuaU0` (CP210x USB bridge, `ugen1.5`).
  Node advertised name set to `MESHBBS`.
- Tailscale up + boot-enabled; node `titan` = `100.118.159.79`.

## Services (FreeBSD rc.d, both boot-enabled)
- **meshbbs** — `/usr/local/etc/rc.d/meshbbs`. Runs `meshbbs-run.sh`, which USB-resets
  the CP210x (`usbconfig`, via sudoers rule `/usr/local/etc/sudoers.d/meshbbs`) then
  execs the daemon under `daemon(8) -r` as user `steve`. Logs `/var/log/meshbbs.log`.
  **Sole owner of the serial port.**
- **meshbbswebui** — `/usr/local/etc/rc.d/meshbbswebui`. veb web UI on
  `http://100.118.159.79:8080` (Tailscale IP, plain HTTP, no auth = tailnet-only).
  Reads/writes the shared `meshbbs.db`; **never touches the serial port**.

## Key architecture decisions
- **V TLS is broken on this box** → all outbound HTTP shells out to `curl`
  (`wx.v` / `spacewx.v` / `news.v` / `forecast.v` via `curl_get`). Web UI is plain HTTP.
- **Single-owner serial**: web UI + scheduler never touch the radio directly. They
  enqueue into `outbound_messages`; the daemon loop drains it (`send_msg` for DMs /
  `send_chan_msg` for channels) with pagination + airtime spacing.
- **V ORM `create table` never adds columns to existing tables** → use
  `store.add_column_if_missing` (PRAGMA table_info + ALTER). Applied for
  `scheduled_messages.source` and `sessions.greeted`. Remember for any future column.

## Features (all test-first; 22 test files passing)
- BBS core: boards, rooms, mail, oneliners, bulletins, last-callers, profiles, TELL,
  permissions (unverified/twit/user/aide/sysop).
- Data services: `WX`, `FORECAST/FC [days]` (1–7), `SPACEWX/SW`, `NEWS`
  (Sheridan Media + Buffalo Bulletin RSS).
- Polls, flavor commands (FORTUNE/ROLL/8BALL/JOKE), channel directory, STATS.
- Interaction audit log (`interactions`, internal/sysop-only, not exposed to callers).
- Passive mesh-health capture (`mesh_traffic`: adverts / channel msgs / DMs, SNR + path).
- `node_names` synced from the radio contact list every 15 min.
- Hidden `/advert` slash command (handled in the daemon, not in dispatch/help).
- **DB-backed scheduler** (`scheduled_messages`): onetime/interval/daily + a `source`
  field (static/wx/spacewx/news/fortune/forecast/digest) resolved live at send time.
  Seeded daily: digest 07:00, news 07:05, fortune 12:00 — **currently all disabled**
  to the public channel.
- **Auto-register**: every node gets a `user`-level account `node-<pubkey_prefix>` on
  first contact (first ever = sysop). `CLAIM`/`NEW` name it, `SETPASS`, `LOGIN` adopts
  identity on other devices. No multi-pubkey linking.
- **News aging** (`sent_headlines`): dedupes already-sent headlines; falls back to
  latest when all stale.
- 5-day forecast folded into the digest.
- UX: one-time first-contact greeting, rewritten MENU/HELP, "did you mean" suggestions.
- **/CONFIG**: user text-macro custom commands (`user_macros`; can't override builtins;
  per-owner) + preferences (`user_prefs`). No scripting — text only.
- Web UI pages: Dashboard, Nodes, Users (set perm incl. sysop + ban), Interactions,
  Messages, Macros (macros + prefs, sysop delete), Traffic, Schedules, Broadcast.
- Contact auto-accept: daemon subscribes to `new_contact` → `mc.accept_contact`.

## Backlog
- Per-user daily **digest DM delivery** (preference plumbing exists; send loop not wired).
- Web UI auth (currently tailnet-only).
- Per-schedule forecast depth.

## Note
This document is a project summary, not a chat transcript. The assistant
conversation history is not stored in this repository.
