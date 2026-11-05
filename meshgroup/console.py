"""The owner's page (/admin): see the list, add and remove people by hand, block and unblock.

Two things are needed to log in: a password, kept in the table as a salted hash, and the six-digit code from an authenticator app (TOTP, RFC 6238);
`admin.py passwd` sets both. A code works once. Logging in gives a signed cookie that lasts eight hours.
Every change is a POST carrying a token that only a page shown to that session contains, and the cookie is SameSite=Strict, so another
site cannot make the owner's browser change the list. Failed logins are limited per address and in all.
"""
import base64
import hashlib
import hmac
import secrets
import struct
from dataclasses import dataclass

import app
import pages

COOKIE = '__Host-mg'  # __Host- makes the browser insist on Secure, Path=/ and no Domain
SESSION = 8 * 3600
ROUNDS = 200_000


@dataclass
class Reply:
    status: int
    html: str
    cookie: str = ''  # a Set-Cookie value
    location: str = ''  # where to go next (a redirect)


def new_login(password):
    """The record kept for the owner: the password only as a salted hash, the authenticator secret, and the key that signs sessions
    (a new one ends every session)."""
    salt = secrets.token_bytes(16)
    return {'salt': salt.hex(), 'hash': _hash(password, salt).hex(), 'key': secrets.token_hex(32),
            'totp': base64.b32encode(secrets.token_bytes(20)).decode()}


def totp(secret, step):
    """The six-digit code for the 30-second `step` (RFC 6238 with HMAC-SHA1, as every authenticator app does it)."""
    digest = hmac.new(base64.b32decode(secret), struct.pack('>Q', step), hashlib.sha1).digest()
    offset = digest[-1] & 15
    return f'{(struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7fffffff) % 10**6:06d}'


def otp_uri(secret, name):
    """What an authenticator app takes to set itself up (shown as a QR code by tools that can; the secret can also be typed in)."""
    return f'otpauth://totp/{name}:owner?secret={secret}&issuer={name}'


def _hash(password, salt):
    return hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), salt, ROUNDS)


def _sign(key, text):
    return hmac.new(bytes.fromhex(key), text.encode(), hashlib.sha256).hexdigest()


def _cookie(value, age):
    return f'{COOKIE}={value}; Max-Age={age}; Path=/; Secure; HttpOnly; SameSite=Strict'


class Console:
    def __init__(self, cfg, store, now, log=print):
        self.cfg, self.store, self.now, self.log = cfg, store, now, log

    def session(self, cookies, login):
        """The session's cookie value if it is genuine and has not run out, else ''."""
        value = (cookies or {}).get(COOKIE, '')
        parts = value.split('.')
        if len(parts) != 3 or not login or not parts[0].isdigit() or int(parts[0]) < int(self.now()):
            return ''
        return value if hmac.compare_digest(_sign(login['key'], 's|' + '.'.join(parts[:2])), parts[2]) else ''

    def handle(self, method, path, form, ip, cookies):
        method = method.upper()
        login = self.store.get_login()
        if not login or 'totp' not in login:
            return Reply(503, pages.admin_notice('Not set up yet', 'Set the password and the authenticator code first by running: python3 meshgroup/admin.py passwd'))
        if path == '/admin/login' and method == 'POST':
            return self._login(form, ip, login)
        session = self.session(cookies, login)
        if not session:
            return Reply(200, pages.admin_login())
        csrf = _sign(login['key'], 'c|' + session)
        if path == '/admin' and method == 'GET':
            return self._page(csrf)
        if method != 'POST' or not hmac.compare_digest(str(form.get('c', '')), csrf):
            return Reply(404, pages.admin_notice('Not found', ''))
        if path == '/admin/logout':
            return Reply(200, pages.admin_login(), cookie=_cookie('', 0))
        action = {'/admin/add': self._add, '/admin/remove': self._remove, '/admin/block': self._block,
                  '/admin/unblock': self._unblock}.get(path)
        if not action:
            return Reply(404, pages.admin_notice('Not found', ''))
        return self._page(csrf, action(form))

    def _login(self, form, ip, login):
        now = int(self.now())
        hour = now // 3600
        if not self.store.bump(f'login#{ip}#{hour}', 10, 2 * 3600, now) or not self.store.bump(f'login#{hour}', 100, 2 * 3600, now):
            return Reply(429, pages.admin_login('Too many tries. Wait an hour.'))
        right = hmac.compare_digest(_hash(str(form.get('password', '')), bytes.fromhex(login['salt'])), bytes.fromhex(login['hash']))
        step = self._step(login['totp'], str(form.get('code', '')).replace(' ', ''), now)
        # both are always checked, and one message covers either being wrong; a code that was used once never works again
        if not (right and step is not None and self.store.claim(f'totp#{step}', 120, now)):
            self.log(event='admin-login-failed', ip=ip)
            return Reply(401, pages.admin_login('The password or the code is wrong.'))
        body = f'{now + SESSION}.{secrets.token_hex(8)}'
        self.log(event='admin-login', ip=ip)
        return Reply(303, '', cookie=_cookie(f'{body}.{_sign(login["key"], "s|" + body)}', SESSION), location='/admin')

    @staticmethod
    def _step(secret, code, now):
        """Which 30-second step `code` is the code for (the one before and after count, for clocks that differ), or None."""
        found = None
        for step in range(now // 30 - 1, now // 30 + 2):
            if hmac.compare_digest(totp(secret, step), code):
                found = step
        return found

    def _page(self, csrf, message=''):
        members = sorted(self.store.list_all(), key=lambda m: (m.get('status', ''), m['email']))
        return Reply(200, pages.admin_page(self.cfg, members, csrf, message))

    def _add(self, form):
        cfg, now = self.cfg, int(self.now())
        added = skipped = 0
        bad = []
        room = cfg.max_members - self.store.count_active()
        for line in str(form.get('people', '')).splitlines()[:500]:
            p = app.parse_person(line)
            if p is None:
                continue
            if not p[0]:
                bad.append(p[1][:40])
                continue
            m = self.store.get_member(p[0])
            if m and m['status'] in ('active', 'blocked'):
                skipped += 1
            elif room <= 0:
                return f'{added} added; stopped because the list is at its limit of {cfg.max_members}.'
            else:
                self.store.add_active(p[0], p[1], now, note='added by the list owner')
                self.log(event='admin-add', address=p[0])
                added += 1
                room -= 1
        said = f'{added} added, {skipped} already on the list or blocked.'
        return said + (f' Not addresses, skipped: {"; ".join(bad[:5])}.' if bad else '')

    def _remove(self, form):
        a = app.clean_address(form.get('e', ''))
        if not a:
            return 'That is not an address.'
        self.store.remove(a)
        self.log(event='admin-remove', address=a)
        return f'{a} removed.'

    def _block(self, form):
        a = app.clean_address(form.get('e', ''))
        if not a:
            return 'That is not an address.'
        if not self.store.set_status(a, 'blocked'):
            self.store.put_blocked(a, int(self.now()))
        self.log(event='admin-block', address=a)
        return f'{a} blocked: no mail goes to them and their posts are refused.'

    def _unblock(self, form):
        a = app.clean_address(form.get('e', ''))
        if not a:
            return 'That is not an address.'
        done = self.store.set_status(a, 'unsubscribed', only_from='blocked')
        return f'{a} unblocked (they can sign up again).' if done else f'{a} was not blocked.'
