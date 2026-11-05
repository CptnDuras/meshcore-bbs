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

- **No V TLS, no SDK.** The daemon's host has no working V TLS, so (like `wx.v` and `news.v`) HTTPS goes through
  `curl`. `sigv4.v` signs the request in V (ported from the planner service, same AWS test vectors); `ses.v` builds the
  SES v2 `SendEmail` call and hands it to `CurlSender`, which keeps the signed headers and the message in
  mode-600 temp files.
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
`scheduled_messages` directly), and the NWS alerts are not copied to a group.

## Posting by email: anyone can write to the list address

Anyone who writes to **meshbbs@xerokuhl.com** (the `list_address`) has their message passed on to everyone on the group named by
`inbound_group`, from that same address, signed "Ada Lovelace via Buffalo Mesh". A reply goes back to the list.

```
sender ──► MX (SES, us-west-2) ──► receipt rule: scan spam + viruses ──► S3 bucket (private, empties itself in 14 days)
daemon, once a minute:  list ─► fetch ─► read (mime.v) ─► decide (inbound.v) ─► queue one email per member ─► delete from the bucket
```

Because anyone can write, the rules in `inbound.v` are what keep the list from being used against its members. A message is
**turned away** (the reason is written down and shown on the web page) if it is:

| Reason | How it is told |
|---|---|
| paused | the **Pause posting** switch on the web page (people can still ask to be taken off) |
| too large / no text / no sender | over `inbound_max_bytes` (default 1 MB), empty, or no usable From address |
| the list's own mail | from the list address, or carrying our `X-Loop` header |
| automatic or bulk mail (this is how mail loops start) | `Auto-Submitted`, `Precedence: bulk/list/junk`, `X-Auto-Response-Suppress`, `List-Id`/`List-Unsubscribe`, delivery reports, empty return path, no-reply and postmaster senders |
| a blocked sender | an address or a whole `@domain` on the block list (web page) |
| not cleared by SES's scans | `X-SES-Spam-Verdict` and `X-SES-Virus-Verdict` must both be `PASS`; `FAIL` is always refused, and so is a missing or `GRAY` verdict unless `inbound_require_scan=0` |
| not shown to come from where it says | `Authentication-Results` needs `dmarc=pass`, or `dkim=pass`/`spf=pass` for the From domain; `dmarc=fail` is always refused (`inbound_require_auth=0` to relax) |
| over a limit | `inbound_per_sender_day` posts from one sender a day (3), `inbound_posts_day` in all (20), never more posts than the account's daily sending cap allows for the size of the list, and nothing while the sending queue is already full |

Only text is passed on: attachments are dropped (and the post says so), HTML is reduced to its words, and the subject gets the
tag (`[mesh]`) once. The message is deleted from the bucket as soon as it has been dealt with; the database keeps only who
sent it, the subject, what was done and why (90 days).

**STOP.** A message whose first line is just STOP / unsubscribe / remove me (or whose subject is, with nothing in the body) is
not a post: it takes that sender off the list and they get a short confirmation. This only counts from a sender that passed
the same checks, and it works while posting is paused. (The footer of every email tells people to reply STOP, and a notice's
reply would otherwise go to the whole list.)

**Handled once.** Each message gets a database row before anything is done with it, so it is never passed on twice, even if
the daemon stops half way (the row then stays `posting` for the sysop to see) or the delete from the bucket fails.

Set it up with `tools/ses-inbound-setup.sh` (`DRY_RUN=1` first). It makes the bucket, the SES receipt rule, the MX record and
the daemon's read access, and adds `list_address`, `inbound_bucket` and `inbound_group` to the settings file. It will not
replace an existing MX record, and it adds to an active SES rule set rather than switching it. Note that **the MX is for the
whole domain**: afterwards SES receives every address @xerokuhl.com and accepts only the list address.

Costs: SES charges about $0.10 per thousand messages received; the bucket holds a few kilobytes for a minute. Mail sent *out*
counts against the 200 a day.

Things to check on the first real message (the web page's **Posts by email** shows what happened to each message and why):
the exact verdict and `Authentication-Results` headers SES writes (the rules above read them as documented; if mail is being
turned away as "not cleared" or "could not be verified", look at one message in the bucket and adjust), and that SES accepts the
`List-Id`/`Precedence`/`X-Loop` headers on a send.

## Files

`sigv4.v`, `ses.v` (SES), `s3.v` (the bucket), `mime.v` (reading a message), `inbound.v` (the rules), `inbound_worker.v` (the poller),
`email_models.v`, `store_email.v` (tables), `email_groups.v` (parsing, commands, fan-out),
`email_worker.v` (queue), `email_cli.v` (`meshbbs email`), `cmd_email.v` (registration), `tools/ses-setup.sh`, `tools/ses-inbound-setup.sh`,
`emaillist/` (shared rules), `webui/email_ui.v` + `webui/templates/email.html` (the page).
Tests: `sigv4_test.v`, `ses_test.v`, `s3_test.v`, `mime_test.v`, `inbound_test.v`, `inbound_worker_test.v`, `email_groups_test.v`,
`email_worker_test.v`, `email_cli_test.v`, `email_store_test.v`, `minijson_test.v`, `emaillist/emaillist_test.v`, `webui/email_ui_test.v`.

A note for anyone writing a web UI page: `@{...}` in a veb template is HTML-escaped by the V build this was written on, so
`@{h(x)}` shows people `&amp;#39;`. `email_ui.v` escapes once in `esc()` and passes `veb.RawHtml`, which no build escapes again.
(The older pages still use `h()`; check them if a name with an apostrophe or an ampersand looks odd.)
