# Spec 33 — App: People tab scaffold

## Dependencies
Spec 30 (tab nav exists).

## Design language
- List rows: 40dp avatar (initials/identicon, generated locally), name, timestamp
- Unread dot: teal, right side
- Empty state: "No one nearby yet" + mesh illustration (bundled)
- Feel: contacts list, not "nodes"

## Task
Add People tab with list layout.

## Deliverables
- People tab shows list of discovered peers
- Each row: avatar, name, last seen

## Acceptance criteria
- [ ] Tab labeled "People" (not Nodes)
- [ ] List populates from contact/advert data
- [ ] Empty state if no peers

## Test
Manual: switch to People tab, see peer list.
