"""The owner's page (/admin): see the list, add and remove people by hand, block and unblock.

Nobody logs in here. The "Sign in" button sends the browser to the identity provider (Cognito, which hands the sign-in to AWS IAM Identity
Center, where the hardware key is checked); it comes back to /admin/callback with a one-time code, which this page swaps for the person's
address. Only the addresses in the OWNER_EMAILS setting get in. The result is a signed cookie that lasts eight hours.
Every change is a POST carrying a token that only a page shown to that session contains, and the cookie is SameSite=Strict, so another
site cannot make the owner's browser change the list. Sign-in attempts are limited per address and in all.

`idp` is whatever turns the provider's code into an address: `login_url(state)` and `email(code)` (None when the code is no good).
"""
import hashlib
import hmac
import secrets
from dataclasses import dataclass

import app
import pages

COOKIE = '__Host-mg'  # __Host- makes the browser insist on Secure, Path=/ and no Domain
STATE = '__Host-mgs'  # the sign-in in progress; Lax, because the provider's redirect back to us is a cross-site navigation
SESSION = 8 * 3600
SIGN_IN = 600


@dataclass
class Reply:
    status: int
    html: str
    cookie: str = ''  # a Set-Cookie value
    location: str = ''  # where to go next (a redirect)


def _sign(key, text):
    return hmac.new(key.encode(), text.encode(), hashlib.sha256).hexdigest()


def _cookie(name, value, age, same_site='Strict'):
    return f'{name}={value}; Max-Age={age}; Path=/; Secure; HttpOnly; SameSite={same_site}'


class Console:
    def __init__(self, cfg, store, now, idp=None, log=print):
        self.cfg, self.store, self.now, self.idp, self.log = cfg, store, now, idp, log

    def session(self, cookies):
        """The session's cookie value if it is genuine and has not run out, else ''."""
        value = (cookies or {}).get(COOKIE, '')
        parts = value.split('.')
        if len(parts) != 3 or not parts[0].isdigit() or int(parts[0]) < int(self.now()):
            return ''
        return value if hmac.compare_digest(_sign(self.cfg.session_key, 's|' + '.'.join(parts[:2])), parts[2]) else ''

    def handle(self, method, path, form, ip, cookies):
        method = method.upper()
        if not (self.idp and self.cfg.owner_emails and self.cfg.session_key):
            return Reply(503, pages.admin_notice('Not set up yet', 'Sign-in for the owner page has not been set up (see the README).'))
        if path == '/admin/login' and method == 'GET':
            return self._start(ip)
        if path == '/admin/callback' and method == 'GET':
            return self._finish(form, ip, cookies)
        session = self.session(cookies)
        if not session:
            return Reply(200, pages.admin_login())
        csrf = _sign(self.cfg.session_key, 'c|' + session)
        if path == '/admin' and method == 'GET':
            return self._page(csrf)
        if method != 'POST' or not hmac.compare_digest(str(form.get('c', '')), csrf):
            return Reply(404, pages.admin_notice('Not found', ''))
        if path == '/admin/logout':
            return Reply(200, pages.admin_login(), cookie=_cookie(COOKIE, '', 0))
        action = {'/admin/add': self._add, '/admin/remove': self._remove, '/admin/block': self._block,
                  '/admin/unblock': self._unblock}.get(path)
        if not action:
            return Reply(404, pages.admin_notice('Not found', ''))
        return self._page(csrf, action(form))

    def _allowed(self, ip):
        now = int(self.now())
        hour = now // 3600
        return self.store.bump(f'login#{ip}#{hour}', 10, 2 * 3600, now) and self.store.bump(f'login#{hour}', 100, 2 * 3600, now)

    def _start(self, ip):
        """Sends the browser to the provider, remembering (in a cookie it will bring back) which sign-in this is."""
        if not self._allowed(ip):
            return Reply(429, pages.admin_login('Too many tries. Wait an hour.'))
        nonce = secrets.token_urlsafe(18)
        return Reply(303, '', cookie=_cookie(STATE, f'{nonce}.{_sign(self.cfg.session_key, "n|" + nonce)}', SIGN_IN, 'Lax'),
                     location=self.idp.login_url(nonce))

    def _finish(self, form, ip, cookies):
        """The provider sent the browser back: the state must be the one this browser was given, used once, and the person must be an owner."""
        now = int(self.now())
        if not self._allowed(ip):
            return Reply(429, pages.admin_login('Too many tries. Wait an hour.'))
        nonce, _, tag = (cookies or {}).get(STATE, '').partition('.')
        fine = nonce and hmac.compare_digest(_sign(self.cfg.session_key, 'n|' + nonce), tag) and hmac.compare_digest(str(form.get('state', '')), nonce)
        if not (fine and self.store.claim(f'oauth#{nonce}', SIGN_IN, now)):
            self.log(event='admin-login-failed', ip=ip, why='state')
            return Reply(401, pages.admin_login('That sign-in did not start here. Try again.'))
        who = (self.idp.email(str(form.get('code', ''))) or '').strip().lower()
        if who not in self.cfg.owner_emails:
            self.log(event='admin-login-failed', ip=ip, why='not an owner' if who else 'no code')
            return Reply(403, pages.admin_login('That account is not allowed here.'))
        body = f'{now + SESSION}.{secrets.token_hex(8)}'
        self.log(event='admin-login', ip=ip)
        # A redirect would carry the cross-site origin of the provider along and the browser would then withhold the Strict cookie, so
        # this is a page that moves on by itself instead.
        return Reply(200, pages.admin_continue(), cookie=_cookie(COOKIE, f'{body}.{_sign(self.cfg.session_key, "s|" + body)}', SESSION))

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
