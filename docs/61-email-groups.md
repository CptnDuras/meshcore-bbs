# 61 — Email groups

People who are not (yet) on the radio mesh can be put on an **email group**. The BBS emails them what it would
otherwise say on the air: a message from the sysop, a scheduled digest, later the weather alerts. Delivery is by
Amazon SES. Everything is opt-in and sysop-run: there is no sign-up page, and the sysop writes down in each
member's `note` where their consent came from.

## How it fits

```
sysop DM  ──GSEND / GROUP──►  engine ──► email_outbox ──► EmailWorker ──► Mailer ──► curl ──► SES
scheduler ──target_kind=email──► outbound queue ─┘            (1 a second)   (SigV4)
shell     ──meshbbs email import / test──────────────────────────────────────────┘
```

- **No SDK.** `sigv4.v` signs the request in V (ported from the planner service, same AWS test vectors); `ses.v` builds
  the SES v2 `SendEmail` call and hands it to `HttpsSender` (`httpclient.v`), which speaks HTTPS with V's `net.mbedtls`
  and checks the certificate against the same CA bundle as MQTT. It exists instead of `net.http` because V's dial has no
  connect timeout, and these calls run in the loop that also drives the radio: here the connect is non-blocking and
  polled (8 s), the whole request has a 30 s deadline, and SIGPIPE is ignored so a connection the server already closed
  cannot end the process. (The older pollers still use `curl`; the notes in `wx.v` about V's TLS crashing no longer
  reproduce on V 0.5.2 / FreeBSD 15.)
- **No x.json2.** It crashed on FreeBSD (see `minijson.v`), so JSON is written by `json_str` (ses.v) and read by
  `minijson`. (Fixing this also fixed `\uXXXX` escapes in `minijson`, which used to fail the whole document.)
- **One message a second**, which is SES's sending rate in the sandbox. The main loop already ticks once a second
  and `EmailWorker.tick` sends at most one queued message per call.
- **Failures are sorted by what they mean** (`classify_ses_reply`):

  | SES says | Outcome | What the worker does |
  |---|---|---|
  | 200 | sent | marks it sent |
  | the recipient is not verified, or another per-message refusal | rejected | marks it failed, marks that member `rejected` |
  | 429, 5xx, no answer | retry | tries again after 1 min, 5 min, 30 min, 2 h, 6 h, 12 h, then gives up |
  | bad credentials, the sender or domain is not verified, account paused | halt | keeps *everything* queued and rests 15 minutes; the reason shows in the log |

- **A daily cap** (150, under the account's 200) stops a long list from running into SES's limit; the rest waits.
- **Finished mail** is kept 30 days and then removed. The queue is not an archive.

## Setting it up

1. `tools/ses-setup.sh` (run `DRY_RUN=1 tools/ses-setup.sh` first to see every change). It makes the SES identity for
   `xerokuhl.com`, adds the DKIM / MAIL FROM / DMARC records in Route 53, makes an IAM user that may only
   `ses:SendEmail` from that identity, and writes its key to `~/.config/meshbbs/ses.conf` (mode 600).
2. Copy `ses.conf` to the machine that runs the daemon, to the same path (or set `MESHBBS_SES`). Set `reply_to` in it
   to the address that should receive replies, because people stop by replying (the footer says so).
3. **Sandbox:** a new SES account only delivers to *verified* addresses. For each person, verify the address once
   (`aws sesv2 create-email-identity --email-identity them@example.com` sends them a link to click). Or ask AWS for
   production access, which removes this. An address that is not verified is refused and the member is marked
   `rejected`, which `GROUP <name> LIST` shows.
4. Without the settings file the daemon runs as before: email is off, group mail waits in the queue, and the log says so.

## Putting people in

From a shell (nothing touches the radio):

```
meshbbs email import family list.txt "asked at the club meeting"
meshbbs email groups
meshbbs email members family
meshbbs email test you@example.com
```

A list file has one person a line, any of: `ada@example.com`, `ada@example.com Ada Lovelace`,
`ada@example.com, Ada Lovelace`, `Ada Lovelace <ada@example.com>`. Blank lines and `#` lines are ignored, duplicates
are dropped (case-insensitively), and lines with no usable address are listed back. Importing twice changes nothing,
and **never brings back someone who was unsubscribed.**

From the web UI (**Email** in the nav, `/email`): make a group, paste a list into **Add people** (the same formats and the
same rules as the shell import, at most 500 at a time; lines that are not addresses are reported back), and for each person
**Stop mailing** / **Start again** (also the way to try a `rejected` address once it has been verified in SES) or **Remove**. A
person already in a group is never changed by adding them again, so pasting the whole list twice is safe and cannot revive
someone who unsubscribed. The page also shows what is queued, sent in the last 24 hours and failed, with the latest failures.
Like the other pages it has no sign-in (it is for the tailnet); a form post that says it came from another site is refused.

The page and the daemon are separate programs sharing the database, so they share the rules through the `emaillist` module
(what an address is, how a list is read, the table columns). `bbs/email_store_test.v` checks those columns against the real
tables, so changing the tables without the page fails a test.

From the radio (sysop only):

| Command | Does |
|---|---|
| `GROUPS` | the groups and how many people in each get mail |
| `GROUP NEW <g> [about]` / `GROUP DROP <g>` | make or remove a group |
| `GROUP <g> LIST` | members with their state |
| `GROUP <g> ADD <email> [name]` | add one person |
| `GROUP <g> STOP <email>` / `START` | unsubscribe / put back (`DEL` removes the row) |
| `GSEND <g> [subject]` | then the message, ended by `.` alone; one email per active member |
| `EMAILSTATUS` | queued / sent / failed, sent in the last 24 h, the last failures |

## Scheduled and automatic mail

A scheduled message (or anything put in the outbound queue) whose `target_kind` is `email` and whose `target` is a
group name is emailed to that group instead of sent on the air; its first line becomes the subject. So the existing
digest/news/fortune sources can go to a group.

**Not done yet:** the web UI's schedule form does not offer `email` as a target (rows can be added to
`scheduled_messages` directly), and the NWS alerts are not copied to a group. Inbound email (replying to post or to
unsubscribe automatically) needs SES receiving and a poller; today the sysop handles STOP replies with `GROUP <g> STOP`.

## The public mailing list is separate

Letting anyone write to a list address, and letting people sign themselves up, is **not** done by the daemon. That is
`meshgroup/` (Python Lambdas, DynamoDB and SES, deployed with `meshgroup/deploy.sh`; see `meshgroup/README.md`). The two
share nothing but SES: a BBS notice can go to the list by emailing its address from the sysop's address.

## Files

`sigv4.v`, `ses.v` (SES), `email_models.v`, `store_email.v` (tables), `email_groups.v` (parsing, commands, fan-out),
`email_worker.v` (queue), `email_cli.v` (`meshbbs email`), `cmd_email.v` (registration), `tools/ses-setup.sh`,
`emaillist/` (shared rules), `webui/email_ui.v` + `webui/templates/email.html` (the page).
Tests: `sigv4_test.v`, `ses_test.v`, `email_groups_test.v`, `email_worker_test.v`, `email_cli_test.v`, `email_store_test.v`,
`minijson_test.v`, `emaillist/emaillist_test.v`, `webui/email_ui_test.v`.

A note for anyone writing a web UI page: `@{...}` in a veb template is HTML-escaped by the V build this was written on, so
`@{h(x)}` shows people `&amp;#39;`. `email_ui.v` escapes once in `esc()` and passes `veb.RawHtml`, which no build escapes again.
(The older pages still use `h()`; check them if a name with an apostrophe or an ampersand looks odd.)
