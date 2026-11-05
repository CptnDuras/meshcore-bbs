"""Tests for the list's rules (python3 -m unittest in this directory). No AWS: the store, mailer and bucket are in-memory fakes."""
import unittest
from email.message import EmailMessage

import app
import pages

NOW = 1_800_000_000
LIST = 'meshgroup@xerokuhl.com'
GOOD = {'spamVerdict': {'status': 'PASS'}, 'virusVerdict': {'status': 'PASS'}, 'dmarcVerdict': {'status': 'PASS'},
        'dkimVerdict': {'status': 'PASS'}, 'spfVerdict': {'status': 'PASS'}}


class FakeStore:
    def __init__(self):
        self.members, self.counts, self.claimed = {}, {}, set()

    def get_member(self, a):
        m = self.members.get(a)
        return dict(m) if m else None

    def put_pending(self, a, name, token, now):
        self.members[a] = {'email': a, 'name': name, 'token': token, 'status': 'pending', 'sent': now}

    def activate(self, a, token, now):
        m = self.members.get(a)
        if m and m['status'] == 'pending' and m['token'] == token:
            m['status'] = 'active'
            return True
        return False

    def add_active(self, a, name='', now=0, note=''):
        self.members[a] = {'email': a, 'name': name, 'token': 'tok-' + a.split('@')[0], 'status': 'active'}

    def set_status(self, a, status, only_from=None):
        m = self.members.get(a)
        if not m or (only_from and m['status'] != only_from):
            return False
        m['status'] = status
        return True

    def list_active(self):
        return [dict(m) for m in self.members.values() if m['status'] == 'active']

    def count_active(self):
        return len(self.list_active())

    def bump(self, key, limit, ttl, now):
        if self.counts.get(key, 0) >= limit:
            return False
        self.counts[key] = self.counts.get(key, 0) + 1
        return True

    def claim(self, key, ttl, now):
        if key in self.claimed:
            return False
        self.claimed.add(key)
        return True


class FakeMailer:
    def __init__(self):
        self.sent = []
        self.fail_for = set()

    def send(self, **kw):
        if kw['to'] in self.fail_for:
            raise RuntimeError('SES said no')
        self.sent.append(kw)


class FakeObjects:
    def __init__(self):
        self.items, self.deleted = {}, []

    def size(self, key):
        return len(self.items[key]) if key in self.items else None

    def get(self, key):
        return self.items[key]

    def delete(self, key):
        self.deleted.append(key)
        self.items.pop(key, None)


def make_app(**cfg):
    c = app.Config(list_address=LIST, site_url='https://lists.example', send_pause=0, **cfg)
    a = app.App(c, FakeStore(), FakeMailer(), FakeObjects(), now=lambda: NOW, sleep=lambda s: None, log=lambda s: None)
    return a


def raw(frm='Ada Lovelace <ada@example.com>', subject='Net tonight', body='See you at 8.', **headers):
    m = EmailMessage()
    m['From'], m['To'], m['Subject'] = frm, LIST, subject
    for k, v in headers.items():
        m[k.replace('_', '-')] = v
    m.set_content(body)
    return m.as_bytes()


def post(a, data, mid='m1', receipt=None, source='ada@example.com'):
    a.objects.items[a.cfg.prefix + mid] = data
    return a.inbound({'mail': {'messageId': mid, 'source': source}, 'receipt': receipt or GOOD})


def with_members(a, *names):
    for n in names:
        a.store.add_active(f'{n}@example.com', n.title())


class Helpers(unittest.TestCase):
    def test_an_address_is_lower_cased_and_must_look_like_one(self):
        self.assertEqual(app.clean_address(' Ada@Example.COM '), 'ada@example.com')
        for bad in ['', 'ada', 'ada@', '@example.com', 'a b@example.com', 'a@b', 'ada@example.com\nBcc: x@y.zz',
                    '"ada"@example.com', 'ada@example..com', 'a' * 65 + '@example.com', 'a@b.c']:
            self.assertIsNone(app.clean_address(bad), bad)

    def test_the_tag_goes_in_once_and_after_re(self):
        self.assertEqual(app.tag_subject('Net tonight', '[mg]'), '[mg] Net tonight')
        self.assertEqual(app.tag_subject('Re: [mg] Net tonight', '[mg]'), 'Re: [mg] Net tonight')
        self.assertEqual(app.tag_subject('RE: Fwd: Net', '[mg]'), 'RE: Fwd: [mg] Net')
        self.assertEqual(app.tag_subject('', '[mg]'), '[mg] (no subject)')
        self.assertNotIn('\n', app.tag_subject('a\r\nBcc: x@y.zz', '[mg]'))

    def test_a_request_to_leave_is_recognised(self):
        self.assertTrue(app.is_stop('STOP', 'hi'))
        self.assertTrue(app.is_stop('\n> quoted\n  Unsubscribe.  \nThanks', 'x'))
        self.assertTrue(app.is_stop('', 'Re: unsubscribe'))
        self.assertFalse(app.is_stop('Please do not stop the net', 'x'))
        self.assertFalse(app.is_stop('Net tonight', 'stop'))

    def test_html_is_reduced_to_its_words(self):
        t = app.html_to_text('<p>Hello <b>there</b></p><script>alert(1)</script><style>p{}</style><div>Bye</div>')
        self.assertIn('Hello there', t)
        self.assertIn('Bye', t)
        self.assertNotIn('alert', t)
        self.assertNotIn('p{}', t)

    def test_settings_are_read_from_the_environment(self):
        c = app.Config.from_env({'LIST_ADDRESS': 'Mesh@X.com', 'POSTING': 'members', 'REQUIRE_SCAN': 'false', 'POSTS_DAY': 'x'})
        self.assertEqual((c.list_address, c.posting, c.require_scan, c.posts_day), ('mesh@x.com', 'members', False, 20))


class Posting(unittest.TestCase):
    def test_a_post_goes_to_everyone_else_with_the_list_as_sender(self):
        a = make_app()
        with_members(a, 'ada', 'bob', 'cy')
        self.assertEqual(post(a, raw()), 'posted')
        self.assertEqual(sorted(m['to'] for m in a.mailer.sent), ['bob@example.com', 'cy@example.com'])
        m = a.mailer.sent[0]
        self.assertEqual(m['subject'], '[meshgroup] Net tonight')
        self.assertEqual(m['sender'], 'Ada Lovelace via Mesh Group <meshgroup@xerokuhl.com>')
        self.assertEqual(m['reply_to'], LIST)
        self.assertIn('See you at 8.', m['text'])
        self.assertIn('ada@example.com', m['text'])
        self.assertIn('https://lists.example/unsubscribe?e=' + m['to'].replace('@', '%40'), m['text'])
        self.assertIn('&t=tok-' + m['to'].split('@')[0], m['text'])
        self.assertEqual(a.objects.deleted, ['inbound/m1'])

    def test_each_person_gets_their_own_leave_link(self):
        a = make_app()
        with_members(a, 'ada', 'bob', 'cy')
        post(a, raw())
        links = {m['to']: m['unsubscribe'] for m in a.mailer.sent}
        self.assertEqual(len(set(links.values())), 2)

    def test_the_same_message_is_not_passed_on_twice(self):
        a = make_app()
        with_members(a, 'ada', 'bob')
        self.assertEqual(post(a, raw()), 'posted')
        self.assertEqual(post(a, raw()), 'duplicate')
        self.assertEqual(len(a.mailer.sent), 1)

    def test_one_failed_send_does_not_stop_the_rest(self):
        a = make_app()
        with_members(a, 'ada', 'bob', 'cy', 'dee')
        a.mailer.fail_for = {'bob@example.com'}
        self.assertEqual(post(a, raw()), 'posted')
        self.assertEqual(sorted(m['to'] for m in a.mailer.sent), ['cy@example.com', 'dee@example.com'])

    def test_a_non_member_may_post_unless_the_list_is_members_only(self):
        a = make_app()
        with_members(a, 'bob')
        self.assertEqual(post(a, raw()), 'posted')
        b = make_app(posting='members')
        with_members(b, 'bob')
        self.assertEqual(post(b, raw()), 'rejected')
        with_members(b, 'ada')
        self.assertEqual(post(b, raw(), mid='m2'), 'posted')

    def test_html_only_mail_is_sent_as_text_and_attachments_are_left_out(self):
        a = make_app()
        with_members(a, 'bob')
        m = EmailMessage()
        m['From'], m['Subject'] = 'ada@example.com', 'Pic'
        m.set_content('x')
        m.clear_content()
        m.set_content('<p>Hello <b>mesh</b></p><script>bad()</script>', subtype='html')
        m.add_attachment(b'\x00\x01', maintype='application', subtype='octet-stream', filename='a.bin')
        post(a, m.as_bytes())
        t = a.mailer.sent[0]['text']
        self.assertIn('Hello mesh', t)
        self.assertNotIn('bad()', t)
        self.assertIn('Attachments were left out', t)

    def test_a_name_that_could_break_a_header_is_made_safe(self):
        a = make_app()
        with_members(a, 'bob')
        hostile = (b'From: "Ev\\" <x@y.zz>\r\n Bcc: z@y.zz" <eve@example.com>\r\nTo: meshgroup@xerokuhl.com\r\n'
                   b'Subject: Hi\r\n Bcc: z@y.zz\r\n\r\nhello\r\n')
        post(a, hostile)
        m = a.mailer.sent[0]
        self.assertNotIn('\n', m['sender'])
        self.assertNotIn('\n', m['subject'])
        self.assertEqual(m['sender'].count('<'), 1)

    def test_a_name_with_accents_is_encoded_for_the_header(self):
        a = make_app()
        with_members(a, 'bob')
        post(a, raw(frm='"José Núñez" <jose@example.com>'), source='jose@example.com')
        self.assertTrue(a.mailer.sent[0]['sender'].isascii())


class Refusals(unittest.TestCase):
    def refused(self, data=None, receipt=None, source='ada@example.com', a=None, mid='m1'):
        a = a or make_app()
        with_members(a, 'bob')
        out = post(a, data or raw(), receipt=receipt, source=source, mid=mid)
        self.assertEqual(out, 'rejected')
        self.assertEqual(a.mailer.sent, [])
        self.assertEqual(a.objects.deleted, ['inbound/' + mid])  # whatever the answer, the message does not stay in the bucket

    def test_mail_the_scan_did_not_clear_is_refused(self):
        self.refused(receipt={**GOOD, 'spamVerdict': {'status': 'FAIL'}})
        self.refused(receipt={**GOOD, 'virusVerdict': {'status': 'FAIL'}})
        self.refused(receipt={**GOOD, 'spamVerdict': {'status': 'GRAY'}})
        self.refused(receipt={k: v for k, v in GOOD.items() if k != 'virusVerdict'})

    def test_gray_is_allowed_only_if_the_scan_is_switched_off(self):
        a = make_app(require_scan=False)
        with_members(a, 'bob')
        self.assertEqual(post(a, raw(), receipt={**GOOD, 'spamVerdict': {'status': 'GRAY'}}), 'posted')

    def test_a_sender_who_cannot_be_verified_is_refused(self):
        self.refused(receipt={**GOOD, 'dmarcVerdict': {'status': 'FAIL'}})
        self.refused(receipt={**GOOD, 'dmarcVerdict': {'status': 'GRAY'}, 'dkimVerdict': {'status': 'FAIL'}, 'spfVerdict': {'status': 'FAIL'}})

    def test_gray_dmarc_is_accepted_with_a_passing_dkim_or_spf(self):
        a = make_app()
        with_members(a, 'bob')
        self.assertEqual(post(a, raw(), receipt={**GOOD, 'dmarcVerdict': {'status': 'GRAY'}}), 'posted')

    def test_machine_mail_is_refused(self):
        for h in [{'Auto_Submitted': 'auto-replied'}, {'Precedence': 'bulk'}, {'X_Auto_Response_Suppress': 'All'},
                  {'List_Id': '<x.example>'}, {'List_Unsubscribe': '<mailto:x@y.zz>'}, {'X_Loop': LIST}]:
            self.refused(raw(**h))

    def test_mail_with_no_return_path_or_from_a_no_reply_sender_is_refused(self):
        self.refused(source='')
        self.refused(source='mailer-daemon@example.com')
        self.refused(raw(frm='noreply@example.com'))
        self.refused(raw(frm=LIST))

    def test_too_large_or_empty_is_refused(self):
        self.refused(raw(body='x' * 2000), a=make_app(max_bytes=1000))
        self.refused(raw(body='   \n\n'))

    def test_a_blocked_address_is_refused(self):
        a = make_app()
        a.store.members['ada@example.com'] = {'email': 'ada@example.com', 'status': 'blocked', 'token': 't'}
        self.refused(a=a)

    def test_limits(self):
        a = make_app(per_sender_day=2, posts_day=3)
        with_members(a, 'bob')
        self.assertEqual(post(a, raw(), mid='a'), 'posted')
        self.assertEqual(post(a, raw(), mid='b'), 'posted')
        self.assertEqual(post(a, raw(), mid='c'), 'rejected')  # too many from this sender
        self.assertEqual(post(a, raw(frm='cy@example.com'), mid='d', source='cy@example.com'), 'posted')
        self.assertEqual(post(a, raw(frm='dee@example.com'), mid='e', source='dee@example.com'), 'rejected')  # the list's own limit

    def test_a_list_over_its_size_limit_sends_nothing(self):
        a = make_app(max_members=2)
        with_members(a, 'bob', 'cy', 'dee')
        self.assertEqual(post(a, raw()), 'rejected')

    def test_a_message_that_has_gone_missing_is_dealt_with(self):
        a = make_app()
        with_members(a, 'bob')
        self.assertEqual(a.inbound({'mail': {'messageId': 'zz', 'source': 'a@b.cc'}, 'receipt': GOOD}), 'rejected')


class Leaving(unittest.TestCase):
    def test_a_member_who_writes_stop_is_taken_off_and_told(self):
        a = make_app()
        with_members(a, 'ada', 'bob')
        self.assertEqual(post(a, raw(body='STOP')), 'stop')
        self.assertEqual(a.store.members['ada@example.com']['status'], 'unsubscribed')
        self.assertEqual([m['to'] for m in a.mailer.sent], ['ada@example.com'])  # the notice, to them only
        self.assertEqual(post(a, raw(), mid='m2'), 'posted')  # they are no longer on the list, but may still write
        self.assertEqual([m['to'] for m in a.mailer.sent[1:]], ['bob@example.com'])

    def test_stop_from_someone_not_on_the_list_does_nothing(self):
        a = make_app()
        with_members(a, 'bob')
        self.assertEqual(post(a, raw(body='unsubscribe')), 'stop')
        self.assertEqual(a.mailer.sent, [])

    def test_stop_never_goes_to_the_list(self):
        a = make_app()
        with_members(a, 'ada', 'bob', 'cy')
        post(a, raw(body='stop'))
        self.assertTrue(all(m['to'] == 'ada@example.com' for m in a.mailer.sent))


class Bounces(unittest.TestCase):
    def test_a_permanent_bounce_or_a_complaint_stops_the_mail(self):
        a = make_app()
        with_members(a, 'ada', 'bob', 'cy')
        n = a.delivery_event({'eventType': 'Bounce', 'bounce': {'bounceType': 'Permanent', 'bouncedRecipients': [{'emailAddress': 'Ada@example.com'}]}})
        self.assertEqual((n, a.store.members['ada@example.com']['status']), (1, 'bounced'))
        n = a.delivery_event({'eventType': 'Complaint', 'complaint': {'complainedRecipients': [{'emailAddress': 'bob@example.com'}]}})
        self.assertEqual((n, a.store.members['bob@example.com']['status']), (1, 'complained'))
        self.assertEqual([m['email'] for m in a.store.list_active()], ['cy@example.com'])

    def test_a_temporary_bounce_or_other_event_changes_nothing(self):
        a = make_app()
        with_members(a, 'ada')
        self.assertEqual(a.delivery_event({'eventType': 'Bounce', 'bounce': {'bounceType': 'Transient', 'bouncedRecipients': [{'emailAddress': 'ada@example.com'}]}}), 0)
        self.assertEqual(a.delivery_event({'eventType': 'Delivery'}), 0)
        self.assertEqual(a.store.members['ada@example.com']['status'], 'active')


class SigningUp(unittest.TestCase):
    def join(self, a, email='ada@example.com', ip='1.2.3.4', name='Ada', hp=''):
        return a.web('POST', '/subscribe', {}, {'email': email, 'name': name, 'website': hp}, ip, 'x.lambda-url.us-west-2.on.aws')

    def token(self, a, email='ada@example.com'):
        return a.store.members[email]['token']

    def test_signing_up_sends_a_link_and_changes_nothing_until_it_is_used(self):
        a = make_app()
        status, html = self.join(a)
        self.assertEqual(status, 200)
        self.assertEqual(a.store.members['ada@example.com']['status'], 'pending')
        self.assertEqual(len(a.mailer.sent), 1)
        self.assertIn('https://lists.example/confirm?e=ada%40example.com&t=' + self.token(a), a.mailer.sent[0]['text'])
        self.assertEqual(a.store.list_active(), [])

    def test_opening_the_link_only_shows_a_button_and_the_button_joins(self):
        a = make_app()
        self.join(a)
        t = self.token(a)
        status, html = a.web('GET', '/confirm', {'e': 'ada@example.com', 't': t}, {}, '1.1.1.1', '')
        self.assertEqual(status, 200)
        self.assertIn('<button', html)
        self.assertEqual(a.store.members['ada@example.com']['status'], 'pending')  # a mail scanner opening it joins no one
        status, html = a.web('POST', '/confirm', {}, {'e': 'ada@example.com', 't': t}, '1.1.1.1', '')
        self.assertEqual((status, a.store.members['ada@example.com']['status']), (200, 'active'))
        self.assertEqual(a.web('POST', '/confirm', {}, {'e': 'ada@example.com', 't': t}, '1.1.1.1', '')[0], 400)  # not twice

    def test_a_wrong_token_does_nothing(self):
        a = make_app()
        self.join(a)
        for t in ['', 'nope', self.token(a)[:-1]]:
            self.assertEqual(a.web('POST', '/confirm', {}, {'e': 'ada@example.com', 't': t}, '1.1.1.1', '')[0], 400)
        self.assertEqual(a.web('POST', '/confirm', {}, {'e': 'bob@example.com', 't': 'x'}, '1.1.1.1', '')[0], 400)
        self.assertEqual(a.store.members['ada@example.com']['status'], 'pending')

    def test_the_page_says_the_same_thing_whoever_the_address_is(self):
        a = make_app()
        with_members(a, 'bob')
        first = self.join(a, 'new@example.com')
        again = self.join(a, 'bob@example.com')
        junk = self.join(a, 'not an address')
        bot = self.join(a, 'bot@example.com', hp='http://spam')
        self.assertEqual({first, again, junk, bot}, {first})
        self.assertEqual([m['to'] for m in a.mailer.sent], ['new@example.com'])  # a member, junk and a bot get no mail

    def test_an_address_gets_one_confirmation_a_day_and_the_page_cannot_be_used_to_flood(self):
        a = make_app(subscribe_ip_hour=3, subscribe_hour=5)
        self.join(a)
        self.join(a)
        self.assertEqual(len(a.mailer.sent), 1)
        for i in range(6):
            self.join(a, f'p{i}@example.com', ip='9.9.9.9')
        # the page allows 5 sign-ups an hour in all (two were used by the first address), and 3 from one place
        self.assertEqual(len(a.mailer.sent), 4)
        for i in range(6):
            self.join(a, f'q{i}@example.com', ip=f'8.8.8.{i}')
        self.assertEqual(len(a.mailer.sent), 4)  # the hour's allowance is spent whoever asks

    def test_leaving_by_the_link(self):
        a = make_app()
        with_members(a, 'ada')
        t = a.store.members['ada@example.com']['token']
        self.assertEqual(a.web('GET', '/unsubscribe', {'e': 'ada@example.com', 't': t}, {}, '', '')[0], 200)
        self.assertEqual(a.store.members['ada@example.com']['status'], 'active')
        self.assertEqual(a.web('POST', '/unsubscribe', {}, {'e': 'ada@example.com', 't': 'bad'}, '', '')[0], 400)
        self.assertEqual(a.web('POST', '/unsubscribe', {}, {'e': 'ada@example.com', 't': t}, '', '')[0], 200)
        self.assertEqual(a.store.members['ada@example.com']['status'], 'unsubscribed')

    def test_someone_who_left_can_sign_up_again_and_a_blocked_one_cannot(self):
        a = make_app()
        a.store.members['ada@example.com'] = {'email': 'ada@example.com', 'status': 'unsubscribed', 'token': 'old'}
        a.store.members['bad@example.com'] = {'email': 'bad@example.com', 'status': 'blocked', 'token': 'x'}
        self.join(a)
        self.join(a, 'bad@example.com')
        self.assertEqual(a.store.members['ada@example.com']['status'], 'pending')
        self.assertEqual(a.store.members['bad@example.com']['status'], 'blocked')

    def test_a_full_list_does_not_add_more(self):
        a = make_app(max_members=1)
        with_members(a, 'bob')
        self.join(a)
        status, html = a.web('POST', '/confirm', {}, {'e': 'ada@example.com', 't': self.token(a)}, '1.1.1.1', '')
        self.assertIn('full', html)
        self.assertEqual(a.store.members['ada@example.com']['status'], 'pending')

    def test_what_people_type_is_escaped_in_the_pages(self):
        a = make_app()
        evil = '"><script>alert(1)</script>'
        html = a.web('GET', '/confirm', {'e': 'ada@example.com', 't': evil}, {}, '', '')[1]
        self.assertNotIn('<script>', html)
        self.assertIn('&lt;script&gt;', html)
        self.assertNotIn('<script>', pages.notice(a.cfg, '<b>t</b>', '<i>x</i>'))

    def test_the_home_page_and_unknown_paths(self):
        a = make_app()
        status, html = a.web('GET', '/', {}, {}, '', '')
        self.assertEqual(status, 200)
        self.assertIn(LIST, html)
        self.assertIn('name="website"', html)
        self.assertEqual(a.web('GET', '/admin', {}, {}, '', '')[0], 404)
        self.assertEqual(a.web('GET', '/subscribe', {}, {}, '', '')[0], 404)

    def test_links_use_the_pages_own_address_when_no_site_url_is_set(self):
        c = app.Config(list_address=LIST, send_pause=0)
        a = app.App(c, FakeStore(), FakeMailer(), FakeObjects(), now=lambda: NOW, sleep=lambda s: None, log=lambda s: None)
        self.join(a)
        self.assertIn('https://x.lambda-url.us-west-2.on.aws/confirm?e=', a.mailer.sent[0]['text'])


if __name__ == '__main__':
    unittest.main()
