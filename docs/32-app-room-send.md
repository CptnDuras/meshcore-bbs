# Spec 32 — App: Room send message

## Dependencies
Spec 31 (Room history), Spec 20 (daemon POST handler).

## Design language
- Pending: amber (#F59E0B) left border, clock icon (bundled)
- Confirmed: border fades, checkmark icon (bundled)
- Failed: red border, tap bubble to retry (no modal)
- Feel: instant feedback, message appears immediately

## Task
Compose message, send, show optimistic state.

## Deliverables
- Tap send → message appears instantly (pending style)
- On ack → pending clears smoothly
- On fail → subtle error, tap to retry

## Acceptance criteria
- [ ] Message shows immediately (optimistic)
- [ ] Amber border + clock while pending
- [ ] Fades to confirmed on ack
- [ ] Retry on tap if failed
- [ ] No blocking modals or alerts

## Test
Manual: send msg, see pending→confirmed transition.
