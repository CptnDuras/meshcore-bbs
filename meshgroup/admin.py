#!/usr/bin/env python3
"""Look after the mesh group's list from a terminal (uses the AWS default profile).

  admin.py add people.txt      put the people in the file on the list, active at once (one a line: an address, or an address and a name)
  admin.py list                everyone, with their state
  admin.py remove ada@x.com    take someone off (and forget them)
  admin.py block spam@x.com    never mail them and refuse their posts
  admin.py unblock ada@x.com   let them sign up again

`add` skips the confirmation email: use it only for people who asked you to add them. TABLE (or the stack named by STACK, default meshgroup) says which table.
"""
import os
import sys
import time

import boto3

import app
from store import DynamoStore


def table():
    name = os.environ.get('TABLE')
    if not name:
        out = boto3.client('cloudformation').describe_stacks(StackName=os.environ.get('STACK', 'meshgroup'))['Stacks'][0]['Outputs']
        name = next(o['OutputValue'] for o in out if o['OutputKey'] == 'Table')
    return DynamoStore(boto3.resource('dynamodb').Table(name))


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd, args, store = argv[1], argv[2:], None
    if cmd in ('add', 'list', 'remove', 'block', 'unblock'):
        store = table()
    now = int(time.time())
    if cmd == 'add' and args:
        added = skipped = 0
        for line in open(args[0], encoding='utf-8'):
            p = app.parse_person(line)
            if p is None:
                continue
            if not p[0]:
                print('not an address, skipped:', p[1])
                continue
            m = store.get_member(p[0])
            if m and m['status'] in ('active', 'blocked'):
                skipped += 1
                continue
            store.add_active(p[0], p[1], now, note='added by the list owner')
            added += 1
        print(f'{added} added, {skipped} already on the list or blocked')
    elif cmd == 'list':
        members = sorted(store.list_all(), key=lambda m: (m.get('status', ''), m['email']))
        for m in members:
            print(f"{m.get('status', ''):13} {m['email']}  {m.get('name', '')}")
        print(f'{sum(m.get("status") == "active" for m in members)} active, {len(members)} in all')
    elif cmd == 'remove' and args:
        store.remove(app.clean_address(args[0]) or '')
    elif cmd == 'block' and args and app.clean_address(args[0]):
        a = app.clean_address(args[0])
        if not store.set_status(a, 'blocked'):
            store.t.put_item(Item={'pk': 'm#' + a, 'email': a, 'name': '', 'token': '', 'status': 'blocked', 'added': now})
    elif cmd == 'unblock' and args and app.clean_address(args[0]):
        store.set_status(app.clean_address(args[0]), 'unsubscribed', only_from='blocked')
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
