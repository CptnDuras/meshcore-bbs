# meshgroup — a very small mailing list

`meshgroup@xerokuhl.com`: anyone can write to it and the message goes to everyone on the list; anyone can sign their address up on a
web page. About the size of a groups.io list with none of the extras: no archive, no digests, no moderation queue.

```
sign-up page (Lambda function URL) ──► DynamoDB (members, counters)
sender ─► MX ─► SES ─► S3 (7 days) + the same Lambda ─► checks ─► one SES message per member ─► bounces/complaints back (SNS) ─► the Lambda
```

One Lambda (`handler.py`, Python 3.13) answers all three: mail SES received, bounce/complaint reports, and the web page. The rules are in
`app.py` and know nothing about AWS; `store.py` is the DynamoDB table; `template.yaml` is everything else (one CloudFormation stack).

## Deploy

```
DRY_RUN=1 meshgroup/deploy.sh      # checks the template, shows each step, changes nothing
meshgroup/deploy.sh                # packages the code, deploys the stack, prints the sign-up page's address
```

Then, by hand (they are your domain and your account): activate the SES rule set (the script prints the command), add the MX record
`10 inbound-smtp.us-west-2.amazonaws.com` for `xerokuhl.com` (mail for the whole domain goes to SES; it accepts only the list address),
and **request SES production access** (SES console → Account dashboard). In the sandbox SES delivers only to addresses you have verified, so
the public cannot receive the list or its confirmation mails until that is granted. The domain identity needs its DNS records first
(`tools/ses-setup.sh` in the repo root does that).

Put your own people on without making them confirm: `python3 meshgroup/admin.py add people.txt` (one a line: an address, or an address and
a name). Also `list`, `remove`, `block`, `unblock`.

## What it does

- **Sign-up** takes an address and optional name, then mails a link. Opening the link shows a button; pressing it joins (so a mail scanner that
  opens links joins no one). The page gives the same answer for every address, so it cannot be used to find out who is on the list. One
  confirmation a day per address; 5 per hour from one place and 20 an hour in all; a hidden field catches bots.
- **Posting**: the message goes to every active member except the sender, one email each, from the list address as "Ada Lovelace via Mesh
  Group", subject tagged `[meshgroup]`, text only (attachments are dropped and the post says so), with a footer and `List-Unsubscribe`. A reply
  goes to the whole list. `POSTING=members` makes it members-only.
- **Leaving**: the footer link (same button page), or replying with just STOP.
- **Turned away** (logged, never answered, so the list cannot be used to send mail to someone): automatic or bulk mail (Auto-Submitted, Precedence,
  List-Id…), delivery reports, no-reply senders, the list's own mail, blocked people, anything SES's spam/virus scan did not pass
  (a missing or GRAY verdict counts as not passed), senders that fail DMARC, messages over 1 MB or with no text, more than 3 posts a day from
  one sender, 20 a day in all, or a list over 300 people.
- **Bounces and complaints** switch the member off (`bounced` / `complained`) so the account's reputation is protected.
- Each message is claimed in the table before anything is sent, so SES retrying the Lambda cannot send it twice.

## Settings (stack parameters / Lambda environment)

`LIST_ADDRESS`, `LIST_NAME`, `SUBJECT_TAG`, `POSTING` (anyone | members), `SITE_URL` (if the page sits behind your own domain), `SEND_PAUSE`
(seconds between messages: 1.05 in the sandbox), and optional `MAX_MEMBERS`, `PER_SENDER_DAY`, `POSTS_DAY`, `MAX_BYTES`, `REQUIRE_SCAN`,
`REQUIRE_AUTH`, `SUBSCRIBE_HOUR`, `SUBSCRIBE_IP_HOUR` (see `Config` in `app.py`).

## With meshbbs

Deliberately light. The BBS can send to the list by being a member of an email group whose only person is the list address
(`meshbbs email import list file`, then `GSEND list <text>`): the mail goes out from the BBS's SES address and arrives like any other post.
(Not tried against the live list yet.) Nothing in AWS knows about the BBS, and the BBS does not read the list.

## Cost

A few cents a month: DynamoDB on-demand, Lambda for seconds a day, SES at $0.10 per thousand messages, S3 holding a message for a week.

## Tests

```
python3 -I -m unittest discover -s meshgroup          # the rules (no AWS needed)
python -m venv v && v/bin/pip install "moto[dynamodb,s3,ses]" boto3
PYTHONPATH=meshgroup v/bin/python -m unittest test_aws  # the DynamoDB/S3/Lambda wiring against moto
```

Not yet checked against the real services: that SES accepts the custom headers on `SendEmail` (moto does), and the shape of the receipt
verdicts in a live event (taken from AWS's documentation). The first real post will show both in CloudWatch Logs (`/aws/lambda/meshgroup`).
