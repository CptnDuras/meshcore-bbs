# Spec 44 — Image compression for mesh

## Dependencies
Spec 25 (wire compression).

## Concept
Images must be tiny to send over mesh. Aggressive compression to ~1-5KB. **Image data then wire-compressed on top.**

## Strategy
- **Max dimensions**: 160x160px (thumbnail)
- **Format**: WebP or JPEG at quality 20-40
- **Color reduction**: optional dithering to 64 colors
- **Target size**: <3KB typical, <10KB max

## Deliverables
- `compress_image(bytes, max_kb)` → compressed bytes
- `decompress_image(bytes)` → displayable image
- Auto-resize before compress
- Reject if still too large after compress

## Size budget
| Image type | Target | Frames (~150B each) |
|------------|--------|---------------------|
| Icon/emoji | <500B | 3-4 |
| Thumbnail | 1-3KB | 7-20 |
| Photo | 3-10KB | 20-70 |

## Acceptance criteria
- [ ] 1080p photo compresses to <5KB thumbnail
- [ ] Thumbnail is recognizable
- [ ] Round-trip: compress→decompress displays correctly

## Test
Compress sample photos, verify <5KB and visually acceptable.
