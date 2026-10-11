# Spec 28 — App: Dart appproto header codec

## Dependencies
Spec 26 (fork + build).

## Task
Port header codec to Dart.

## Deliverables
- `lib/appproto.dart`: `AppHeader`, `encodeHeader()`, `decodeHeader()`

## Acceptance criteria
- [ ] Encodes to 4 bytes
- [ ] Decodes 4 bytes to struct
- [ ] Matches V codec output byte-for-byte

## Test
`test/appproto_test.dart`: `testHeaderRoundtrip()`
