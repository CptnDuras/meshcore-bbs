# Spec 30 — App: Room tab scaffold

## Dependencies
Spec 26 (fork + build).

## Design language
- Bottom nav: 3 tabs (Room, People, Services), teal active, grey inactive
- Empty state: centered text, radio wave illustration (bundled asset)
- Compose: text field + teal send FAB, bottom-anchored
- All icons bundled (no network fetch)
- Feel: group chat, not "channel" — familiar like iMessage/Signal

## Task
Add Room tab with basic layout (no data yet).

## Deliverables
- Bottom nav with Room/People/Services tabs
- Room tab shows empty state + compose field

## Acceptance criteria
- [ ] 3 tabs visible, Room is default
- [ ] Empty state: "Start the conversation"
- [ ] Text field + send button at bottom

## Test
Manual: launch, see tabs, Room is selected.
