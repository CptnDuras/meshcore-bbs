# Spec 48 — App: Image display in chat

## Dependencies
Spec 47 (image send), Spec 31 (room history).

## Design language
- Inline thumbnail: max 160x160dp in bubble
- Tap to expand: full-screen viewer with zoom
- Loading: grey placeholder with shimmer
- Failed: broken image icon + "Tap to retry"
- Cached locally after first load

## Task
Display received images inline in chat bubbles.

## Deliverables
- Detect image message in history
- Render thumbnail inline
- Tap opens full viewer
- Cache in local storage

## Acceptance criteria
- [ ] Image messages show thumbnail in bubble
- [ ] Tap opens full-screen view
- [ ] Pinch to zoom works
- [ ] Images cached (no re-download)
- [ ] Graceful placeholder while loading

## Test
Receive image, verify thumbnail, tap, verify full view.
