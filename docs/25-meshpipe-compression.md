# Spec 25 — Wire compression (mandatory)

## Dependencies
None.

## Concept
**All wire data is compressed by default.** Decompress on receive. Skip only if compressed size > original.

## Task
Compress/decompress all payloads with zlib.

## Deliverables
- `compress(data)` → compressed (or original + flag if larger)
- `decompress(data)` → original
- Header flag: bit in flags byte indicates compressed
- Applied at meshpipe layer (before segmentation, after reassembly)

## Rules
- **Always try compression**
- If compressed >= original: send raw, clear flag
- Receiver checks flag before decompress
- Works for: messages, files, images, history, all opcodes

## Acceptance criteria
- [ ] Text payload compresses ~50-70%
- [ ] Random/pre-compressed data sent raw (no bloat)
- [ ] Round-trip: compress→decompress matches original
- [ ] All opcodes use compression

## Test
`meshpipe_test.v`: `test_compression_text()`, `test_compression_binary()`
