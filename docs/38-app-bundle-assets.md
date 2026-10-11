# Spec 38 — App: Bundle all assets locally

## Dependencies
Spec 26 (fork + build).

## Task
Bundle all icons, illustrations, and weather assets in-app. Zero network fetches for UI.

## Deliverables
- `assets/icons/`: status (clock, check, warning), nav (room, nodes, bbs), actions (send, refresh)
- `assets/weather/`: sun, cloud, rain, snow, fog, wind, storm (~12 conditions)
- `assets/illustrations/`: onboarding (radio, mesh), empty states
- Register in `pubspec.yaml`

## Rationale
All rendering assets live in the APK. Only raw data (text, numbers) goes over the air. App maps condition codes → local icons.

## Acceptance criteria
- [ ] All icons in `assets/icons/`
- [ ] All weather icons in `assets/weather/`
- [ ] Illustrations in `assets/illustrations/`
- [ ] `pubspec.yaml` updated
- [ ] App builds without network asset errors
- [ ] WX screen renders icon from bundled asset

## Test
Airplane mode: app renders all UI elements correctly.
