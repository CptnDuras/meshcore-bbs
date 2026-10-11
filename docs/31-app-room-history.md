# Spec 31 — App: Room auto-loads history

## Dependencies
Spec 30 (Room scaffold), Spec 18 (daemon HISTORY handler), Spec 28 (Dart codec).

## Design language
- Message bubbles: incoming grey left, outgoing teal right, 12dp radius
- Timestamps: inside bubble, secondary color, relative if <1h
- Date dividers: centered pill
- Sender name: bold, above bubble for incoming
- Feel: seamless group chat — messages just appear

## Task
On Room tab open, automatically fetch history. Zero user action.

## Deliverables
- Send 0x10 on tab open (silent, background)
- Parse 0x90, display message list
- Cache locally; only fetch delta if available
- Smooth scroll to latest

## Acceptance criteria
- [ ] Messages display with sender + text + time
- [ ] Newest at bottom, auto-scrolled
- [ ] Empty state if no messages
- [ ] No loading spinners — shimmer or instant
- [ ] Feels like opening any chat app

## Test
Manual: open Room, messages appear smoothly.
