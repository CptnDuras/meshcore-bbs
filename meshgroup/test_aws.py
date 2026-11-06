"""The parts that talk to AWS (store.py, handler.py), run against moto's emulation of DynamoDB, S3 and SES.
Needs `pip install "moto[dynamodb,s3,ses]" boto3`; skipped when moto is not installed."""
import os
import unittest

try:
    import boto3
    from moto import mock_aws
except ImportError:  # pragma: no cover
    boto3 = mock_aws = None

from test_meshgroup import GOOD, LIST, raw

NOW = 1_800_000_000


class FakeToken:
    """What Cognito's token endpoint answers: a JSON body whose id_token carries the person's address (unsigned here; the code never reads the signature)."""

    def __init__(self, email, aud='cid', **claims):
        import base64
        import io
        import json
        part = lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).decode().rstrip('=')
        claims = {'aud': aud, **({'email': email} if email else {}), **claims}
        self.body = io.BytesIO(json.dumps({'id_token': f'{part({"alg": "RS256"})}.{part(claims)}.sig'}).encode())

    def __enter__(self):
        return self.body

    def __exit__(self, *a):
        return False


class CognitoTests(unittest.TestCase):
    def cognito(self, opener):
        import handler
        return handler.Cognito('auth.example', 'cid', 'sec', 'https://lists.example/admin/callback', opener)

    def test_the_token_request_is_the_code_exchange_with_the_client_secret(self):
        seen = []
        self.cognito(lambda req, timeout: seen.append(req) or FakeToken('steve@example.com')).email('abc')
        req = seen[0]
        self.assertEqual(req.full_url, 'https://auth.example/oauth2/token')
        self.assertIn('grant_type=authorization_code&code=abc', req.data.decode())
        self.assertEqual(req.get_header('Authorization'), 'Basic Y2lkOnNlYw==')  # cid:sec

    def test_the_address_comes_back_only_for_our_own_client(self):
        self.assertEqual(self.cognito(lambda r, timeout: FakeToken('steve@example.com')).email('abc'), 'steve@example.com')
        self.assertIsNone(self.cognito(lambda r, timeout: FakeToken('steve@example.com', aud='someone-else')).email('abc'))

    def test_with_no_email_attribute_the_signed_in_subject_is_the_address(self):
        who = [{'providerName': 'IdentityCenter', 'userId': 'steve@example.com'}]
        self.assertEqual(self.cognito(lambda r, timeout: FakeToken(None, identities=who)).email('abc'), 'steve@example.com')
        self.assertEqual(self.cognito(lambda r, timeout: FakeToken('a@example.com', identities=who)).email('abc'), 'a@example.com')  # an attribute wins
        other = [{'providerName': 'Google', 'userId': 'eve@example.com'}]
        self.assertIsNone(self.cognito(lambda r, timeout: FakeToken(None, identities=other)).email('abc'))  # only our provider counts
        self.assertIsNone(self.cognito(lambda r, timeout: FakeToken(None)).email('abc'))

    def test_a_refused_or_broken_exchange_is_nobody(self):
        def refused(req, timeout):
            raise OSError('HTTP Error 400')
        self.assertIsNone(self.cognito(refused).email('abc'))
        self.assertIsNone(self.cognito(lambda r, timeout: FakeToken('x')).email(''))  # no code, no request

        class Junk:
            def __enter__(self):
                import io
                return io.BytesIO(b'<html>')

            def __exit__(self, *a):
                return False
        self.assertIsNone(self.cognito(lambda r, timeout: Junk()).email('abc'))


@unittest.skipIf(mock_aws is None, 'moto is not installed')
class AwsTests(unittest.TestCase):
    def setUp(self):
        for k, v in {'AWS_ACCESS_KEY_ID': 'x', 'AWS_SECRET_ACCESS_KEY': 'x', 'AWS_DEFAULT_REGION': 'us-west-2',
                     'LIST_ADDRESS': LIST, 'TABLE': 'meshgroup', 'BUCKET': 'mail', 'SITE_URL': 'https://lists.example',
                     'SEND_PAUSE': '0', 'AWS_LAMBDA_FUNCTION_NAME': 'meshgroup'}.items():
            os.environ[k] = v
        self.mock = mock_aws()
        self.mock.start()
        ddb = boto3.resource('dynamodb')
        ddb.create_table(TableName='meshgroup', KeySchema=[{'AttributeName': 'pk', 'KeyType': 'HASH'}],
                         AttributeDefinitions=[{'AttributeName': 'pk', 'AttributeType': 'S'}], BillingMode='PAY_PER_REQUEST')
        self.s3 = boto3.client('s3')
        self.s3.create_bucket(Bucket='mail', CreateBucketConfiguration={'LocationConstraint': 'us-west-2'})
        self.ses = boto3.client('ses')
        self.ses.verify_domain_identity(Domain='xerokuhl.com')
        import handler
        handler._app = None
        self.handler = handler
        from store import DynamoStore
        self.store = DynamoStore(ddb.Table('meshgroup'))

    def tearDown(self):
        self.mock.stop()

    def test_the_store_counts_claims_and_changes_members(self):
        s = self.store
        self.assertTrue(s.claim('p#1', 100, NOW))
        self.assertFalse(s.claim('p#1', 100, NOW))
        self.assertEqual([s.bump('k', 2, 100, NOW) for _ in range(3)], [True, True, False])
        s.put_pending('ada@example.com', 'Ada', 'tok', NOW)
        self.assertFalse(s.activate('ada@example.com', 'wrong', NOW))
        self.assertTrue(s.activate('ada@example.com', 'tok', NOW))
        self.assertFalse(s.activate('ada@example.com', 'tok', NOW))  # not twice
        m = s.get_member('ada@example.com')
        self.assertEqual((m['status'], m['name'], 'expires' in m), ('active', 'Ada', False))  # no longer expires
        s.add_active('bob@example.com', 'Bob', NOW, 'asked at the meeting')
        self.assertEqual(sorted(x['email'] for x in s.list_active()), ['ada@example.com', 'bob@example.com'])
        self.assertTrue(s.set_status('bob@example.com', 'bounced', only_from='active'))
        self.assertFalse(s.set_status('bob@example.com', 'bounced', only_from='active'))
        self.assertFalse(s.set_status('nobody@example.com', 'blocked'))
        self.assertEqual(s.count_active(), 1)
        s.remove('ada@example.com')
        self.assertIsNone(s.get_member('ada@example.com'))

    def ses_event(self, mid, source='ada@example.com', receipt=None):
        return {'Records': [{'eventSource': 'aws:ses', 'ses': {'mail': {'messageId': mid, 'source': source}, 'receipt': receipt or GOOD}}]}

    def test_a_message_goes_through_the_whole_lambda(self):
        self.store.add_active('ada@example.com', 'Ada', NOW)  # only members may post
        self.store.add_active('bob@example.com', 'Bob', NOW)
        self.store.add_active('cy@example.com', 'Cy', NOW)
        self.s3.put_object(Bucket='mail', Key='inbound/abc', Body=raw())
        out = self.handler.lambda_handler(self.ses_event('abc'), None)
        self.assertEqual(out, {'results': ['posted']})
        self.s3.put_object(Bucket='mail', Key='inbound/xyz', Body=raw(frm='Eve <eve@example.com>'))
        stranger = self.handler.lambda_handler(self.ses_event('xyz', source='eve@example.com'), None)
        self.assertEqual(stranger, {'results': ['rejected']})
        self.assertEqual(self.handler.lambda_handler(self.ses_event('abc'), None), {'results': ['duplicate']})
        self.assertEqual(self.s3.list_objects_v2(Bucket='mail').get('KeyCount'), 0)  # the message was deleted from the bucket

    def test_the_sign_up_page_through_the_function_url_shape(self):
        ev = lambda m, p, q='', body='': {'requestContext': {'http': {'method': m, 'path': p, 'sourceIp': '1.2.3.4'}, 'domainName': 'x.lambda-url.us-west-2.on.aws'},
                                          'rawQueryString': q, 'body': body, 'isBase64Encoded': False}
        r = self.handler.lambda_handler(ev('GET', '/'), None)
        self.assertEqual(r['statusCode'], 200)
        self.assertIn("default-src 'none'", r['headers']['Content-Security-Policy'])
        self.assertIn('Join the list', r['body'])
        r = self.handler.lambda_handler(ev('POST', '/subscribe', body='email=ada%40example.com&name=Ada&website='), None)
        self.assertEqual(r['statusCode'], 200)
        token = self.store.get_member('ada@example.com')['token']
        r = self.handler.lambda_handler(ev('POST', '/confirm', body=f'e=ada%40example.com&t={token}'), None)
        self.assertEqual(r['statusCode'], 200)
        self.assertEqual(self.store.get_member('ada@example.com')['status'], 'active')
        r = self.handler.lambda_handler(ev('POST', '/subscribe', body='x' * 9000), None)
        self.assertEqual(r['statusCode'], 413)

    def test_the_owner_page_through_the_api_shape(self):
        from urllib.parse import quote
        os.environ.update({'OWNER_EMAILS': 'steve@example.com', 'COGNITO_DOMAIN': 'auth.example', 'COGNITO_CLIENT_ID': 'cid', 'COGNITO_CLIENT_SECRET': 'sec'})
        who = {'good': 'steve@example.com', 'stranger': 'eve@example.com'}
        self.handler.build().console.idp.opener = lambda req, timeout: FakeToken(who[req.data.decode().split('code=')[1].split('&')[0]])
        ev = lambda m, p, body='', cookies=None, query='': {
            'requestContext': {'http': {'method': m, 'path': p, 'sourceIp': '1.2.3.4'}, 'domainName': 'groups.example'},
            'rawQueryString': query, 'body': body, 'cookies': cookies or [], 'isBase64Encoded': False}
        r = self.handler.lambda_handler(ev('GET', '/admin/login'), None)
        self.assertEqual(r['statusCode'], 303)
        self.assertTrue(r['headers']['Location'].startswith('https://auth.example/oauth2/authorize?response_type=code&client_id=cid&redirect_uri=https%3A%2F%2Flists.example%2Fadmin%2Fcallback'))
        state_cookie = r['cookies'][0].split(';')[0]
        state = r['headers']['Location'].split('state=')[1]
        r = self.handler.lambda_handler(ev('GET', '/admin/callback', cookies=[state_cookie], query=f'code=stranger&state={state}'), None)
        self.assertEqual((r['statusCode'], 'cookies' in r), (403, False))
        r = self.handler.lambda_handler(ev('GET', '/admin/login'), None)
        state_cookie, state = r['cookies'][0].split(';')[0], r['headers']['Location'].split('state=')[1]
        r = self.handler.lambda_handler(ev('GET', '/admin/callback', cookies=[state_cookie], query=f'code=good&state={state}'), None)
        self.assertEqual(r['statusCode'], 200)
        cookie = r['cookies'][0].split(';')[0]
        page = self.handler.lambda_handler(ev('GET', '/admin', cookies=[cookie]), None)['body']
        token = page.split('name="c" value="')[1].split('"')[0]
        r = self.handler.lambda_handler(ev('POST', '/admin/add', f'c={token}&people={quote("ada@example.com Ada")}', [cookie]), None)
        self.assertIn('1 added', r['body'])
        self.assertEqual(self.store.get_member('ada@example.com')['status'], 'active')
        self.assertNotIn('Add people', self.handler.lambda_handler(ev('GET', '/admin'), None)['body'])  # no cookie, no page
        self.assertEqual(self.handler.lambda_handler(ev('POST', '/subscribe', 'x' * 70000), None)['statusCode'], 413)

    def test_a_bounce_through_sns_shape(self):
        import json
        self.store.add_active('ada@example.com', 'Ada', NOW)
        msg = {'eventType': 'Bounce', 'bounce': {'bounceType': 'Permanent', 'bouncedRecipients': [{'emailAddress': 'ada@example.com'}]}}
        out = self.handler.lambda_handler({'Records': [{'EventSource': 'aws:sns', 'Sns': {'Message': json.dumps(msg)}}]}, None)
        self.assertEqual(out, {'suppressed': 1})
        self.assertEqual(self.store.get_member('ada@example.com')['status'], 'bounced')


if __name__ == '__main__':
    unittest.main()
