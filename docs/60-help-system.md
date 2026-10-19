# 60 — Guided help and the command registry

`HELP` used to print one long command list, which a 160-byte radio splits into many pages. It is now a short
numbered menu, one small screen per topic, and one entry per command.

| Send | Gets |
|------|------|
| `HELP` | the menu: `1 Rooms … 8 People` (moderators also see `9 Staff`) |
| `HELP 2`, or just `2` | the Mail screen: its commands as `usage = summary`, then `Try: …` |
| `HELP MAIL` | one command: usage, aliases, an example |
| `HELP ALL` | every command you may use, by topic (generated) |

A bare digit is treated as a menu pick only when it has no arguments, so `VOTE 1 2` and the rest are
unaffected. If a word is both a command and a topic key, the command wins; digits always mean topics.
First contact gets a three-step start (`K`, `C general`, `N`) that points at `HELP`.

## Every command is its own function

`bbs/commands.v` defines `Command` (names + a `CommandHandler` function) and a `CommandRegistry`.
Each feature registers its commands in its own file, one small named function per command:

| File | Commands |
|------|----------|
| `cmd_core.v` | HELP MENU WHO STATS |
| `cmd_rooms.v` | KNOWN CHANGE NEW GOTO READ ENTER LIST POST |
| `cmd_mail.v` | MAIL MAILBOX CHECKMAIL THREAD TELL |
| `cmd_info.v` | WX FORECAST ALERTS SPACEWX NEWS CHANNELS CHANADD |
| `cmd_fun.v` | FORTUNE ROLL 8BALL JOKE ONELINER BULLETIN POLL VOTE RESULTS POLLCLOSE |
| `cmd_account.v` | REGISTER CLAIM LOGIN LOGOUT SETPASS SETBIO CONFIG LASTCALLERS PROFILE |
| `cmd_admin.v` | VERIFY PROMOTE DEMOTE TWIT BAN UNBAN DELETE BULLET ALERTTEST HELPRELOAD HELPIMPORT |

`Engine.dispatch` only looks the name up in `Engine.commands` (a `CommandSource` interface) and calls the
handler. A test can register just one feature into an empty registry (`register_room_commands`) and exercise
it alone; registering a name twice panics at startup.

## Help text is data, not code

No help wording is in the V source. It is loaded from, in order:

1. **the database** (`help_topics`, `help_commands`, `help_messages`) — `HELPIMPORT` (sysop) copies a file in;
2. **`./help.txt`** next to the daemon — edit and send `HELPRELOAD`, no rebuild;
3. **`bbs/help.txt`** compiled in as an asset, so a bare binary still has help.

A source that exists but fails validation is skipped and named in the startup log / `HELPRELOAD` reply,
so a typo never leaves users without help. `HELPIMPORT` validates the file first and refuses a bad one.

The file format (see the comments at the top of `bbs/help.txt`):

- `[message name]` — `menu_header`, `menu_footer`, `no_topic`, `welcome`;
- `[topic N key]` — one menu screen (`title`, `aliases`, `perm`, `try`, `note`);
- `[command NAME]` — the help entry for one command: `names`, `topic`, `usage`, `summary`, `example`, `perm`.

A topic's screen is composed from the entries of its commands, so a command's help lives with that command.

## Structure (SOLID, dependency injection)

`bbs/help.v`, `bbs/help_catalog.v`:

- `HelpCatalog` (interface) — topics, command entries and messages. `HelpData` is the in-memory
  implementation, built by `parse_help_text` (file / embedded) or `help_data_from_rows` (database).
- `HelpViewer` (interface) — all help knows about the asker: permission level and newness. It never sees the
  Engine, Store or Session.
- `HelpRenderer` (interface) — what the Engine depends on; `HelpService` is the default, built with
  `new_help_service(catalog)`.
- `Engine.help`, `Engine.commands` and `Engine.help_file` are fields with production defaults; tests and
  other front ends assign their own.

## Keeping help accurate

`bbs/help_test.v` fails `v test bbs` if help drifts from the code:

- every registered command has a help entry whose `names` equal the registered names, and every entry
  names a real command (so adding a command without its help entry fails);
- `HELP ALL` lists every command;
- every `Try:` example runs without an unknown-command or usage error, and the documented room, post and
  mail flows work as written;
- every user screen and the menu fit one radio message (the staff screen may span two);
- the parser rejects bad files (unknown topic, bad perm, duplicate numbers or names, missing messages);
- the file → database → reload path, and the fall-back from a broken file, work.
