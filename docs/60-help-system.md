# 60 — Guided help

`HELP` used to print one long command list, which a 160-byte radio splits into many pages. It is now a
short numbered menu with one small screen per topic.

| Send | Gets |
|------|------|
| `HELP` | the menu: `1 Rooms & posts … 6 All commands` (moderators also see 7, sysops 8) |
| `HELP 2`, `HELP mail`, or just `2` | one topic, under 150 bytes, ending in something to try |
| `HELP ALL` / `HELP 6` | every command |

A bare digit is treated as a menu pick only when it has no arguments, so `VOTE 1 2` and the rest are
unaffected. First contact gets a three-step start (`K`, `C general`, `R`) that points at `HELP`.

## Structure (dependency injection)

`bbs/help.v`:

- `HelpCatalog` (interface) — the content. `StaticHelpCatalog` is the built-in one; a different catalog
  (from a file, translated) can be injected without touching any logic. Adding a topic is a data change.
- `HelpViewer` (interface) — all help knows about the asker: permission level and whether they are new.
  The Engine adapts a session into a `SessionViewer`; help never sees the Engine, Store or Session.
- `HelpRenderer` (interface) — what the Engine depends on. `HelpService` is the default, built with
  `new_help_service(catalog)`.
- `Engine.help` is a field with the production default (`default_help_renderer()`); tests and other front
  ends assign their own.

Tests (`bbs/help_test.v`) use a fake catalog, a fake viewer and a stub renderer, and check that every
built-in screen fits one radio message.
