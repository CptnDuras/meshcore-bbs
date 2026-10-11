# Spec 37 — App: Onboarding flow

## Dependencies
Spec 26 (fork + build), Spec 27 (BLE pair).

## Design language
- Illustrations: bundled (radio, mesh, checkmark)
- Colors: teal primary, white surface
- Typography: title large for headings, body for instructions
- Buttons: filled teal, white text, 48dp height
- Feel: welcoming, minimal steps, no jargon

## Task
First-launch onboarding: connect radio, set name.

## Deliverables
- Splash screen (1s)
- Connect screen: "Connect your radio" (BLE scan + tap)
- Name screen: "What's your name?" (skip-able)
- Land on Room tab

## Acceptance criteria
- [ ] New install shows onboarding
- [ ] Can connect radio (no "pair" jargon)
- [ ] Can skip name
- [ ] Lands on Room with "You're connected" toast
- [ ] Total flow < 30 seconds

## Test
Manual: clear app data, launch, complete onboarding.
