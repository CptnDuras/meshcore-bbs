# Spec 47 — App: Image picker and send

## Dependencies
Spec 32 (room send), Spec 44 (image compression), Spec 45 (image codec).

## Design language
- Attach button: 📎 icon left of compose field
- Picker: system image picker (no custom gallery)
- Preview: thumbnail in compose area before send
- Progress: subtle progress bar on bubble during upload
- Pending: same amber style as text messages

## Task
User picks image, app compresses, sends, shows progress.

## Deliverables
- Attach button opens image picker
- Selected image shown as preview
- Compress to <5KB before send
- Send via 0x14, show progress
- On complete: image in chat

## Acceptance criteria
- [ ] Tap 📎 opens picker
- [ ] Large photo auto-compressed
- [ ] Preview shows before send
- [ ] Progress visible during send
- [ ] Image appears in chat on complete

## Test
Pick photo, send, verify appears in Room.
