#!/usr/bin/env bash
# Runs the caregiver (iPhone) and patient display (iPad) UI tests at the same time against a running sync server.
# Usage: scripts/e2e-two-devices.sh <iphone-udid> <ipad-udid>
set -euo pipefail
IPHONE=${1:?iPhone simulator UDID}
IPAD=${2:?iPad simulator UDID}
cd "$(dirname "$0")/../ios"
curl -fsS "${HERE_NOW_SERVER_URL:-http://127.0.0.1:8787}/healthz" >/dev/null || { echo "sync server is not running"; exit 1; }
xcodegen generate --quiet
xcodebuild build-for-testing -project HereNow.xcodeproj -scheme HereNow -destination "id=$IPHONE" -derivedDataPath /tmp/dd-e2e > /tmp/e2e-build.log 2>&1 || { grep -E "error:" /tmp/e2e-build.log; exit 1; }
rm -rf /tmp/herenow-e2e
run() {
  xcodebuild test-without-building -project HereNow.xcodeproj -scheme HereNow -destination "id=$1" -derivedDataPath /tmp/dd-e2e \
    -only-testing:"HereNowUITests/TwoDeviceFlowUITests/$2" > "/tmp/e2e-$2.log" 2>&1
}
run "$IPHONE" testCaregiverCreatesFamilyPublishesAndApprovesDisplay & phone=$!
# Launching two test runners at the same instant is flaky in Xcode; the display side waits for the code anyway.
(sleep 20; run "$IPAD" testDisplayPairsWithCodeAndShowsPublishedContent) & pad=$!
status=0
wait $phone || status=1
wait $pad || status=1
grep -hE "Test Case .*(passed|failed)|error:" /tmp/e2e-test*.log || true
exit $status
