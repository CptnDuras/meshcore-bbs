# Spec 50 — App: File share and receive

## Dependencies
Spec 43 (file codec), Spec 49 (daemon handler), Spec 35 (services tab).

## Design language
- Share button: in Room compose area (📎 → picker shows Files option)
- File bubble: icon + filename + size, tap to open/save
- Progress: bar on bubble during transfer
- Types: show appropriate icon (text, json, gpx, generic)

## Task
Send and receive files in chat and via Services tab.

## Deliverables
- File picker (system picker)
- Size check (<50KB) before send
- Send via 0x16, progress shown
- Receive: show file bubble
- Tap: open or save to device

## Acceptance criteria
- [ ] Can attach file from picker
- [ ] >50KB rejected with friendly message
- [ ] Progress shown during send
- [ ] Received files tappable
- [ ] Files cached locally

## Test
Send 10KB text file, receive on other device, tap to open.
