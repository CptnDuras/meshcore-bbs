"""The Lambda: the one place that talks to AWS. It answers three kinds of event: a message SES received for the list, a delivery
report (bounce or complaint) from SES via SNS, and a web request for the sign-up and owner pages (from API Gateway)."""
import base64
import json
import os
from urllib.parse import parse_qs

import boto3

import app
from store import DynamoStore

CSP = "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"


class Objects:
    def __init__(self, s3, bucket):
        self.s3, self.bucket = s3, bucket

    def size(self, key):
        try:
            return self.s3.head_object(Bucket=self.bucket, Key=key)['ContentLength']
        except self.s3.exceptions.ClientError:
            return None

    def get(self, key):
        return self.s3.get_object(Bucket=self.bucket, Key=key)['Body'].read()

    def delete(self, key):
        self.s3.delete_object(Bucket=self.bucket, Key=key)


class Mailer:
    def __init__(self, ses, config_set):
        self.ses, self.config_set = ses, config_set

    def send(self, to, subject, text, sender, reply_to, unsubscribe):
        headers = [{'Name': 'Precedence', 'Value': 'list'}, {'Name': 'X-Loop', 'Value': reply_to}]
        if unsubscribe:
            headers += [{'Name': 'List-Unsubscribe', 'Value': f'<{unsubscribe}>'}]
        kw = {'ConfigurationSetName': self.config_set} if self.config_set else {}
        self.ses.send_email(
            FromEmailAddress=sender, Destination={'ToAddresses': [to]}, ReplyToAddresses=[reply_to],
            Content={'Simple': {'Subject': {'Data': subject, 'Charset': 'UTF-8'},
                                'Body': {'Text': {'Data': text, 'Charset': 'UTF-8'}}, 'Headers': headers}}, **kw)


_app = None


def build():
    global _app
    if _app is None:
        env = os.environ
        cfg = app.Config.from_env(env)

        _app = app.App(cfg, DynamoStore(boto3.resource('dynamodb').Table(env['TABLE'])),
                       Mailer(boto3.client('sesv2'), env.get('CONFIG_SET', '')),
                       Objects(boto3.client('s3'), env['BUCKET']))
    return _app


def web(a, event):
    """The page for one web request: (status, html, cookie, location)."""
    http = event['requestContext']['http']
    owner = http['path'] == '/admin' or http['path'].startswith('/admin/')
    body = event.get('body') or ''
    if len(body) > (65536 if owner else 8192):
        return 413, 'too large', '', ''
    if event.get('isBase64Encoded'):
        body = base64.b64decode(body).decode('utf-8', 'replace')
    one = lambda q: {k: v[0] for k, v in parse_qs(q or '', max_num_fields=600 if owner else 20).items()}
    ip = http.get('sourceIp', '')
    if owner:
        cookies = dict(c.split('=', 1) for c in event.get('cookies') or [] if '=' in c)
        r = a.console.handle(http['method'], http['path'], one(body), ip, cookies)
        return r.status, r.html, r.cookie, r.location
    status, html = a.web(http['method'], http['path'], one(event.get('rawQueryString')), one(body), ip,
                         event['requestContext'].get('domainName', ''))
    return status, html, '', ''


def lambda_handler(event, context):
    a = build()
    records = event.get('Records') or []
    if records and records[0].get('eventSource') == 'aws:ses':
        return {'results': [a.inbound(r['ses']) for r in records]}
    if records and records[0].get('EventSource') == 'aws:sns':
        return {'suppressed': sum(a.delivery_event(json.loads(r['Sns']['Message'])) for r in records)}
    if 'requestContext' in event:
        status, html, cookie, location = web(a, event)
        headers = {'Content-Type': 'text/html; charset=utf-8', 'Content-Security-Policy': CSP, 'X-Content-Type-Options': 'nosniff',
                   'Referrer-Policy': 'no-referrer', 'Cache-Control': 'no-store'}
        if location:
            headers['Location'] = location
        reply = {'statusCode': status, 'headers': headers, 'body': html}
        if cookie:
            reply['cookies'] = [cookie]
        return reply
    return {'error': 'unknown event'}
