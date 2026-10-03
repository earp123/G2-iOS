#!/usr/bin/env bash
# Build an Ad Hoc .ipa for client demo distribution (Diawi / OTA).
# Ported from MS-Neuro-iOS Tools/adhoc.sh.
#
# Prereqs (one-time): Apple Distribution cert in the login Keychain (team
# 742QW9KJUK), client UDIDs registered at developer.apple.com > Devices.
# Re-run after adding any new UDID -- the profile is baked into the .ipa.
#
# Usage: Tools/adhoc.sh [scheme]   (default: G2-iOS)
set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="${1:-G2-iOS}"
PROJECT="G2-iOS.xcodeproj"
STAMP="$(date +%Y%m%d-%H%M)"
OUT="build/adhoc/$STAMP"
ARCHIVE="$OUT/$SCHEME.xcarchive"

mkdir -p "$OUT"

# Pretty-print if xcpretty is installed; a failed archive still fails the script.
if command -v xcpretty >/dev/null 2>&1; then FMT=(xcpretty); else FMT=(cat); fi

xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  | "${FMT[@]}"

[[ -d "$ARCHIVE" ]] || { echo "Archive failed: $ARCHIVE not found" >&2; exit 1; }

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist ExportOptions-AdHoc.plist \
  -exportPath "$OUT" \
  -allowProvisioningUpdates

IPA="$(ls "$OUT"/*.ipa | head -n1)"
echo
echo "IPA: $IPA"
echo "Next: upload to https://www.diawi.com and send the client the link."
