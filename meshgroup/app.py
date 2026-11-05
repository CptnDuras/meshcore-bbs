"""The mesh group mailing list: the rules, with no AWS in it (the clients are handed in, so tests use fakes).

Mail sent to the list address is passed on to every member; people sign themselves up on a page and confirm by email.
handler.py is the part that touches AWS.
"""
import hmac
import json
import re
import secrets
import time
from dataclasses import dataclass
from email import policy
from email.parser import BytesParser
from email.utils import formataddr, parseaddr
from html.parser import HTMLParser

import pages

ADDRESS = re.compile(r"^[a-z0-9._%+-]{1,64}@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,24}$")
NO_REPLY = ('noreply', 'no-reply', 'donotreply', 'do-not-reply', 'mailer-daemon', 'postmaster', 'bounce', 'bounces')
BULK = ('bulk', 'list', 'junk', 'auto_reply')
STOPS = ('stop', 'unsubscribe', 'remove me', 'remove', 'cancel', 'leave', 'opt out', 'optout')
DAY = 86400


@dataclass
class Config:
    list_address: str
    list_name: str = 'Mesh Group'
    tag: str = '[meshgroup]'
    site_url: str = ''  # where the sign-up page lives; empty = ask for the function's own URL
    posting: str = 'anyone'  # 'anyone', or 'members' (only people on the list)
    max_members: int = 300
    per_sender_day: int = 3
    posts_day: int = 20
    max_bytes: int = 1_000_000
    require_scan: bool = True
    require_auth: bool = True
    subscribe_hour: int = 20  # sign-ups per hour, all together
    subscribe_ip_hour: int = 5  # and from one address
    send_pause: float = 0.2  # seconds between messages (SES's sending rate)
    prefix: str = 'inbound/'

    @classmethod
    def from_env(cls, env):
        def num(key, default):
            try:
                return max(0, int(env.get(key, default)))
            except ValueError:
                return default

        def flag(key, default):
            return str(env.get(key, default)).lower() not in ('0', 'false', 'no', 'off')

        return cls(
            list_address=env['LIST_ADDRESS'].lower(),
            list_name=env.get('LIST_NAME', 'Mesh Group'),
            tag=env.get('SUBJECT_TAG', '[meshgroup]'),
            site_url=env.get('SITE_URL', '').rstrip('/'),
            posting='members' if env.get('POSTING', 'anyone') == 'members' else 'anyone',
            max_members=num('MAX_MEMBERS', 300),
            per_sender_day=num('PER_SENDER_DAY', 3),
            posts_day=num('POSTS_DAY', 20),
            max_bytes=num('MAX_BYTES', 1_000_000),
            require_scan=flag('REQUIRE_SCAN', 'true'),
            require_auth=flag('REQUIRE_AUTH', 'true'),
            subscribe_hour=num('SUBSCRIBE_HOUR', 20),
            subscribe_ip_hour=num('SUBSCRIBE_IP_HOUR', 5),
            send_pause=float(env.get('SEND_PAUSE', '0.2') or 0),
            prefix=env.get('PREFIX', 'inbound/'),
        )


def clean_address(a):
    """The address in lower case, or None if it is not one we will mail (one @, no spaces, quotes or line breaks)."""
    a = (a or '').strip().lower()
    return a if len(a) <= 254 and ADDRESS.match(a) else None


def clean_name(s):
    s = re.sub(r'[\x00-\x1f\x7f"<>]', ' ', s or '')
    return re.sub(r'\s+', ' ', s).strip()[:60]


def clean_line(s, limit=200):
    return re.sub(r'\s+', ' ', re.sub(r'[\x00-\x1f\x7f]', ' ', s or '')).strip()[:limit]


def tag_subject(subject, tag):
    """The subject with the list's tag once, after any Re:/Fwd: ("Re: [meshgroup] Net tonight")."""
    s = clean_line(subject).replace(tag, ' ')
    s = re.sub(r'\s+', ' ', s).strip() or '(no subject)'
    m = re.match(r'^((re|fwd?)\s*:\s*)*', s, re.I)
    return f'{s[:m.end()]}{tag} {s[m.end():]}'.strip()[:200]


class _Words(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.out, self.skip = [], 0

    def handle_starttag(self, tag, attrs):
        if tag in ('script', 'style', 'head'):
            self.skip += 1
        elif tag in ('br', 'p', 'div', 'li', 'tr', 'h1', 'h2', 'h3', 'blockquote'):
            self.out.append('\n')

    def handle_endtag(self, tag):
        if tag in ('script', 'style', 'head') and self.skip:
            self.skip -= 1

    def handle_data(self, data):
        if not self.skip:
            self.out.append(data)


def html_to_text(s):
    p = _Words()
    try:
        p.feed(s)
        p.close()
    except Exception:  # broken markup is not worth failing a message for
        pass
    return ''.join(p.out)


def tidy_text(s):
    s = re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', '', s.replace('\r\n', '\n').replace('\r', '\n'))
    s = re.sub(r'[ \t]+\n', '\n', s)
    return re.sub(r'\n{3,}', '\n\n', s).strip()[:20000]


def message_text(msg):
    """(the words of the message, whether anything else — attachments — was left out)."""
    text = ''
    try:
        part = msg.get_body(preferencelist=('plain', 'html'))
        if part is not None:
            try:
                text = part.get_content()
            except (LookupError, ValueError, UnicodeError):  # an unknown charset: take the bytes as they come
                text = (part.get_payload(decode=True) or b'').decode('utf-8', 'replace')
            if part.get_content_type() == 'text/html':
                text = html_to_text(text)
    except Exception:
        text = ''
    try:
        dropped = any(True for _ in msg.iter_attachments())
    except Exception:
        dropped = False
    return tidy_text(text), dropped


def is_stop(text, subject):
    """True when the message is only a request to leave: its first line that is not quoted, or the subject when there is no body."""
    for line in text.split('\n'):
        line = line.strip()
        if line and not line.startswith('>'):
            return re.sub(r'[^a-z ]', '', line.lower()).strip() in STOPS
    return re.sub(r'[^a-z ]', '', re.sub(r'^(re|fwd?)\s*:\s*', '', subject.lower().strip())).strip() in STOPS


def automatic_reason(msg, cfg):
    """Why this looks like mail sent by a machine (answering it, or passing it on, is how mail loops start); '' if it does not."""
    auto = (str(msg.get('Auto-Submitted') or '')).strip().lower()
    if auto and auto != 'no':
        return 'automatic mail'
    if str(msg.get('Precedence') or '').strip().lower() in BULK:
        return 'bulk mail'
    if msg.get('X-Auto-Response-Suppress'):
        return 'automatic mail'
    if msg.get('List-Id') or msg.get('List-Unsubscribe'):
        return 'mail from another list'
    if cfg.list_address in str(msg.get('X-Loop') or '').lower():
        return 'our own mail'
    if msg.get_content_type() == 'multipart/report':
        return 'a delivery report'
    return ''


def verdict_reason(receipt, cfg):
    """SES's scan and sender checks (the Lambda event carries them as data). Anything not clearly good is refused."""

    def status(key):
        return str((receipt.get(key) or {}).get('status') or '').upper()

    spam, virus, dmarc = status('spamVerdict'), status('virusVerdict'), status('dmarcVerdict')
    if spam == 'FAIL':
        return 'flagged as spam'
    if virus == 'FAIL':
        return 'flagged as a virus'
    if cfg.require_scan and (spam != 'PASS' or virus != 'PASS'):
        return 'not cleared by the spam and virus scan'
    if dmarc == 'FAIL':
        return 'the sender could not be verified'
    if cfg.require_auth and dmarc != 'PASS':
        if not (dmarc == 'GRAY' and 'PASS' in (status('dkimVerdict'), status('spfVerdict'))):
            return 'the sender could not be verified'
    return ''


def post_footer(cfg, who, site, unsubscribe_url):
    return (f'\n\n--\nThis message is from {who}, sent through the {cfg.list_name} list. Reply to answer everyone on the list.\n'
            f'Know someone who would like to be on it? Send them to {site}/\n'
            f'To leave the list: {unsubscribe_url}\n')


def parse_person(line):
    """One line of a list of people: an address, an address and a name, or `Name <address>`. None for a blank or comment line;
    ('', text) when the line holds no usable address; otherwise (address, name)."""
    line = line.strip()
    if not line or line.startswith('#'):
        return None
    if '<' in line and '>' in line:
        a = clean_address(line.split('<')[1].split('>')[0])
        return (a, clean_name(line.split('<')[0])) if a else ('', line)
    for sep in (',', '\t', ';'):
        line = line.replace(sep, ' ')
    first, _, rest = line.partition(' ')
    a = clean_address(first)
    return (a, clean_name(rest)) if a else ('', line)


class App:
    """store: the members and counters; mailer: sends one message; objects: the stored incoming mail; site_url: () -> str."""

    def __init__(self, cfg, store, mailer, objects, site_url=lambda: '', now=time.time, sleep=time.sleep, log=print):
        self.cfg, self.store, self.mailer, self.objects = cfg, store, mailer, objects
        self._site, self.now, self.sleep, self._log = site_url, now, sleep, log
        from console import Console  # console.py uses this module's helpers, so it is imported here, not at the top
        self.console = Console(cfg, store, now, log=self.log)

    def log(self, **kv):
        self._log(json.dumps(kv, default=str))

    def site(self):
        return self.cfg.site_url or self._site()

    def unsubscribe_url(self, member):
        from urllib.parse import quote
        return f"{self.site()}/unsubscribe?e={quote(member['email'])}"

    # ---------- mail sent to the list ----------

    def inbound(self, record):
        """One SES record (an incoming message). Returns what was done, in a word or two (also logged)."""
        mail, receipt = record['mail'], record['receipt']
        mid = mail['messageId']
        now = int(self.now())
        key = self.cfg.prefix + mid
        if not self.store.claim('p#' + mid, 30 * DAY, now):
            return self._done(mid, 'duplicate')  # SES tries again if this fails, so the same message can come twice
        try:
            return self._inbound(record, mail, receipt, mid, key, now)
        finally:
            try:
                self.objects.delete(key)
            except Exception as e:  # the bucket empties itself after a week anyway
                self.log(event='delete-failed', key=key, error=str(e))

    def _done(self, mid, what, **kv):
        self.log(event='inbound', message=mid, result=what, **kv)
        return what

    def _inbound(self, record, mail, receipt, mid, key, now):
        cfg = self.cfg
        source = str(mail.get('source') or '').strip().strip('<>')
        if not source or source.startswith('mailer-daemon'):
            return self._done(mid, 'rejected', reason='empty return path')
        if (reason := verdict_reason(receipt, cfg)):
            return self._done(mid, 'rejected', reason=reason)
        size = self.objects.size(key)
        if size is None:
            return self._done(mid, 'rejected', reason='the message is gone from the bucket')
        if size > cfg.max_bytes:
            return self._done(mid, 'rejected', reason='too large')
        msg = BytesParser(policy=policy.default).parsebytes(self.objects.get(key))
        if (reason := automatic_reason(msg, cfg)):
            return self._done(mid, 'rejected', reason=reason)
        name, addr = parseaddr(str(msg.get('From') or ''))
        sender = clean_address(addr)
        if not sender or sender == cfg.list_address or sender.split('@')[0] in NO_REPLY:
            return self._done(mid, 'rejected', reason='no usable sender')
        member = self.store.get_member(sender)
        status = (member or {}).get('status', '')
        if status == 'blocked':
            return self._done(mid, 'rejected', reason='blocked sender', sender=sender)
        subject = clean_line(str(msg.get('Subject') or ''))
        text, dropped = message_text(msg)
        if is_stop(text, subject):
            if status == 'active':
                self.store.set_status(sender, 'unsubscribed', only_from='active')
                self._tell(sender, f'You are off the {cfg.list_name} list',
                           f'You will not get any more mail from the {cfg.list_name} list. '
                           f'To come back, sign up again at {self.site()}/\n')
            return self._done(mid, 'stop', sender=sender)
        if cfg.posting == 'members' and status != 'active':
            return self._done(mid, 'rejected', reason='not a member', sender=sender)
        if not text:
            return self._done(mid, 'rejected', reason='no text', sender=sender)
        members = [m for m in self.store.list_active() if m['email'] != sender]
        if not members:
            return self._done(mid, 'rejected', reason='no one to send to', sender=sender)
        if len(members) > cfg.max_members:
            return self._done(mid, 'rejected', reason='the list is larger than the limit', sender=sender)
        day = now // DAY
        if not self.store.bump(f'ps#{sender}#{day}', cfg.per_sender_day, 2 * DAY, now):
            return self._done(mid, 'rejected', reason='too many posts from this sender today', sender=sender)
        if not self.store.bump(f'pd#{day}', cfg.posts_day, 2 * DAY, now):
            return self._done(mid, 'rejected', reason='the list has had its posts for today', sender=sender)
        who = clean_name(name) or sender.split('@')[0]
        sent = failed = 0
        site = self.site()
        for m in members:
            body = text + ('\n\n[Attachments were left out.]' if dropped else '') + post_footer(
                cfg, f'{who} <{sender}>', site, self.unsubscribe_url(m))
            try:
                self.mailer.send(
                    to=m['email'], subject=tag_subject(subject, cfg.tag), text=body,
                    sender=formataddr((f'{who} via {cfg.list_name}', cfg.list_address)),
                    reply_to=cfg.list_address, unsubscribe=self.unsubscribe_url(m))
                sent += 1
            except Exception as e:
                failed += 1
                self.log(event='send-failed', to=m['email'], error=str(e)[:200])
            self.sleep(cfg.send_pause)
        return self._done(mid, 'posted', sender=sender, sent=sent, failed=failed)

    def _tell(self, to, subject, text):
        try:
            self.mailer.send(to=to, subject=subject, text=text, sender=formataddr((self.cfg.list_name, self.cfg.list_address)),
                             reply_to=self.cfg.list_address, unsubscribe='')
        except Exception as e:
            self.log(event='notice-failed', to=to, error=str(e)[:200])

    # ---------- bounces and complaints (SES -> SNS) ----------

    def delivery_event(self, event):
        kind = event.get('eventType') or event.get('notificationType') or ''
        if kind == 'Bounce' and (event.get('bounce') or {}).get('bounceType') == 'Permanent':
            who, status = [r.get('emailAddress') for r in event['bounce'].get('bouncedRecipients', [])], 'bounced'
        elif kind == 'Complaint':
            who, status = [r.get('emailAddress') for r in event['complaint'].get('complainedRecipients', [])], 'complained'
        else:
            return 0
        n = 0
        for a in who:
            a = clean_address(a)
            if a and self.store.set_status(a, status, only_from='active'):
                n += 1
                self.log(event='suppressed', address=a, status=status)
        return n

    # ---------- the sign-up page ----------

    def web(self, method, path, query, form, ip, host):
        """(status, html). `host` is the page's own address, used for links when no SITE_URL is set."""
        site = self.cfg.site_url or (f'https://{host}' if host else self._site())
        method = method.upper()
        if path == '/' and method == 'GET':
            return 200, pages.home(self.cfg)
        if path == '/subscribe' and method == 'POST':
            self.subscribe(form.get('email', ''), form.get('name', ''), form.get('website', ''), ip, site)
            return 200, pages.notice(self.cfg, 'Check your email', 'If that address can join, a message from the list is on its way with a link to confirm. Nothing happens until you click it.')
        if path == '/unsubscribe' and method == 'GET':
            return 200, pages.leave(self.cfg, clean_address(query.get('e', '')) or '')
        if path == '/unsubscribe' and method == 'POST':
            self.leave(clean_address(form.get('e', '')), ip)
            return 200, pages.notice(self.cfg, 'You are off the list', 'If that address was on the list it is not any more, and no more mail will be sent to it.')
        if path == '/confirm':
            src = query if method == 'GET' else form
            e, t = clean_address(src.get('e', '')), src.get('t', '')
            if method == 'GET':
                return 200, pages.confirm(self.cfg, path, e or '', t)
            if method == 'POST':
                done = self.confirm(e, t)
                return (200, pages.notice(self.cfg, *done[1:])) if done[0] else (400, pages.notice(self.cfg, 'That link does not work', 'It may be old or already used. You can ask for a new one on the sign-up page.'))
        return 404, pages.notice(self.cfg, 'Not found', '')

    def subscribe(self, address, name, honeypot, ip, site):
        cfg, now = self.cfg, int(self.now())
        a = clean_address(address)
        if honeypot or not a:
            return False
        hour = now // 3600
        if not self.store.bump(f'sub#{hour}', cfg.subscribe_hour, 2 * 3600, now) \
                or not self.store.bump(f'subip#{ip}#{hour}', cfg.subscribe_ip_hour, 2 * 3600, now):
            return False
        m = self.store.get_member(a)
        if m and m['status'] in ('active', 'blocked', 'bounced', 'complained'):
            return False  # nothing is sent to someone who is already on, or who must not be mailed
        if m and m['status'] == 'pending' and now - int(m.get('sent', 0)) < DAY:
            return False  # one confirmation a day to any address
        token = secrets.token_urlsafe(24)
        self.store.put_pending(a, clean_name(name), token, now)
        from urllib.parse import quote
        link = f'{site}/confirm?e={quote(a)}&t={token}'
        self._tell(a, f'Confirm joining the {cfg.list_name} list',
                   f'Someone (hopefully you) asked to join the {cfg.list_name} list with this address.\n\n'
                   f'To join, open this link and press the button:\n{link}\n\n'
                   f'If it was not you, ignore this message and nothing will happen.\n')
        return True

    def confirm(self, address, token):
        if not address or not token:
            return False, '', ''
        m = self.store.get_member(address)
        if not m or m['status'] != 'pending' or not hmac.compare_digest(str(m.get('token', '')), token):
            return False, '', ''
        if self.store.count_active() >= self.cfg.max_members:
            return True, 'The list is full', 'This list is at its limit, so you could not be added. Ask the list owner.'
        if not self.store.activate(address, token, int(self.now())):
            return False, '', ''
        return True, 'You are on the list', f'Mail sent to {self.cfg.list_address} now reaches you. Every message has a link to leave.'

    def leave(self, address, ip):
        """Takes anyone off who asks to be, by address alone (no token: leaving must never be hard). Limited per address of the asker."""
        now = int(self.now())
        if not address or not self.store.bump(f'leave#{ip}#{now // 3600}', 30, 2 * 3600, now):
            return False
        return self.store.set_status(address, 'unsubscribed', only_from='active')
