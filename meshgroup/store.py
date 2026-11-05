"""The members and the counters, in one DynamoDB table (key: pk).

    m#<address>   a member: status (pending, active, unsubscribed, bounced, complained, blocked), name, token, added, sent, expires
    ps#/pd#/sub#  counters that count up to a limit and then expire by themselves
    p#<message>   "this message was already handled"
"""
import secrets
from decimal import Decimal

from boto3.dynamodb.conditions import Attr
from botocore.exceptions import ClientError


def _plain(item):
    return {k: int(v) if isinstance(v, Decimal) else v for k, v in item.items()}


def _failed_condition(e):
    return e.response['Error']['Code'] == 'ConditionalCheckFailedException'


class DynamoStore:
    def __init__(self, table):
        self.t = table

    def get_member(self, address):
        item = self.t.get_item(Key={'pk': 'm#' + address}).get('Item')
        return _plain(item) if item else None

    def put_pending(self, address, name, token, now):
        """Records a sign-up that has not been confirmed; it disappears after three days if it never is."""
        self.t.put_item(Item={'pk': 'm#' + address, 'email': address, 'name': name, 'token': token, 'status': 'pending',
                              'added': now, 'sent': now, 'expires': now + 3 * 86400})

    def activate(self, address, token, now):
        try:
            self.t.update_item(Key={'pk': 'm#' + address},
                               UpdateExpression='SET #s = :a, #j = :n REMOVE #x',
                               ConditionExpression='#s = :p AND #t = :t',
                               ExpressionAttributeNames={'#s': 'status', '#t': 'token', '#j': 'joined', '#x': 'expires'},
                               ExpressionAttributeValues={':a': 'active', ':p': 'pending', ':t': token, ':n': now})
            return True
        except ClientError as e:
            if _failed_condition(e):
                return False
            raise

    def add_active(self, address, name, now, note=''):
        """For the owner's own list: on the list without the confirmation step (the owner vouches for them)."""
        self.t.put_item(Item={'pk': 'm#' + address, 'email': address, 'name': name, 'token': secrets.token_urlsafe(24),
                              'status': 'active', 'added': now, 'joined': now, 'note': note})

    def set_status(self, address, status, only_from=None):
        """Changes a member's state; with only_from, only when they are in that state. False if nothing changed."""
        kw = {'ConditionExpression': 'attribute_exists(pk)'}
        values = {':n': status}
        if only_from:
            kw['ConditionExpression'] = '#s = :f'
            values[':f'] = only_from
        try:
            self.t.update_item(Key={'pk': 'm#' + address}, UpdateExpression='SET #s = :n REMOVE #x',
                               ExpressionAttributeNames={'#s': 'status', '#x': 'expires'}, ExpressionAttributeValues=values, **kw)
            return True
        except ClientError as e:
            if _failed_condition(e):
                return False
            raise

    def _members(self, status=None):
        f = Attr('pk').begins_with('m#')
        if status:
            f = f & Attr('status').eq(status)
        out, kw = [], {'FilterExpression': f}
        while True:
            r = self.t.scan(**kw)
            out += [_plain(i) for i in r.get('Items', [])]
            if 'LastEvaluatedKey' not in r:
                return out
            kw['ExclusiveStartKey'] = r['LastEvaluatedKey']

    def list_active(self):
        return self._members('active')

    def list_all(self):
        return self._members()

    def count_active(self):
        return len(self.list_active())

    def remove(self, address):
        self.t.delete_item(Key={'pk': 'm#' + address})

    def bump(self, key, limit, ttl, now):
        """Counts one more against `key`; False (and no count) once it has reached `limit`."""
        try:
            self.t.update_item(Key={'pk': key}, UpdateExpression='ADD #n :one SET #x = if_not_exists(#x, :e)',
                               ConditionExpression='attribute_not_exists(#n) OR #n < :limit',
                               ExpressionAttributeNames={'#n': 'n', '#x': 'expires'},
                               ExpressionAttributeValues={':one': 1, ':limit': limit, ':e': now + ttl})
            return True
        except ClientError as e:
            if _failed_condition(e):
                return False
            raise

    def claim(self, key, ttl, now):
        """True the first time a key is claimed, False after."""
        try:
            self.t.put_item(Item={'pk': key, 'expires': now + ttl}, ConditionExpression='attribute_not_exists(pk)')
            return True
        except ClientError as e:
            if _failed_condition(e):
                return False
            raise
