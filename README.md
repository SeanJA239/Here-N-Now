# 此刻锚点 (Here & Now)

A calm, always-visible screen for people living with Alzheimer's disease at home. A caregiver confirms a small amount of information (the time of day, one upcoming plan or the current place, a family recording), and a patient iPad shows it with one sentence and one button. The caregiver manages and publishes content from an iPhone, and the two sync through a small self-hosted service.

It is not a medical, medication, location, or safety-monitoring product.

Beyond the core screen, the app includes the PRD's P1 features, all off or manual by default: weekly recurring plans, comfort recordings a caregiver starts by hand, scheduled greetings with quiet hours and daily limits, an optional 7-day playback log, family members who can only suggest recordings, photos, and plans, and on-device voice dictation that fills a draft. A widget/StandBy version was assessed and deferred; see `docs/standby-widget-assessment.md`.

## Layout

- `ios/`: one universal SwiftUI app (iOS 17+). An iPad paired as a patient screen shows patient mode; an iPhone that creates a family is the caregiver app. A single device can do both.
- `ios/Packages/HereNowCore`: platform-independent rules: what the patient sees at a given instant, event validity, publish validation, three-way merge, clock-jump detection, and palette contrast.
- `server/`: the sync service (Node 24+, built-in `node:sqlite`, no dependencies): pairing, versioned publishing, receipts, revocation, deletion, recovery, family suggestions, comfort commands, and the optional play log.

The app reaches sync only through the `CaregiverSyncing` and `DisplaySyncing` protocols (`ios/HereNow/Sync/SyncAPI.swift`), so the service can be replaced, for example with CloudKit, without changing the UI or the rules.

## Run

```sh
# Sync service
cd server && npm start              # listens on :8787, data in ./data (HERE_NOW_DATA_DIR)

# App (macOS with Xcode 26+ and XcodeGen)
cd ios && xcodegen generate && open HereNow.xcodeproj
```

The app reads the service URL from `HereNowServerURL` in `ios/project.yml` (default `http://127.0.0.1:8787`, which simulators reach on the Mac) or from the `HERE_NOW_SERVER_URL` environment variable. Real devices need an HTTPS deployment of `server/`.

## Test

```sh
cd server && npm test                                   # sync contract: pairing, publish, revoke, delete, recovery
cd ios/Packages/HereNowCore && swift test               # patient-screen rules
scripts/e2e-two-devices.sh <iphone-udid> <ipad-udid>    # caregiver iPhone + patient iPad against the running server
```
