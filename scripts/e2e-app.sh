#!/usr/bin/env bash
# The app's full flow on an Android emulator (app/integration_test/app_test.dart): a passkey,
# DKG, boarding, the cosigner's own renewal, an entry with the passkey, the Exit tab, and a payout
# through the platform. Against the dev enclave image's app bundle, whose relying party is
# vtxos.com, and MerlinPlatform with its fake Grid.
#
# The passkey takes the real path, PasskeyPlugin → Credential Manager → a provider: the provider is
# app/android/testpasskey, set as the emulator's over adb, and scripts/approve-passkeys.sh taps
# each sheet's Continue as the owner would.
#
#   make e2e-app       with an emulator up, API 34 or later; ANDROID_SERIAL picks one of several
#
# `make e2e-app` brings up regtest and arkd and builds the x86_64 FFI first. MerlinPlatform is
# found as scripts/platform.sh finds it.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"
serial="${ANDROID_SERIAL:-$(adb devices | awk 'NR > 1 && $1 ~ /^emulator-/ && $2 == "device" { print $1; exit }')}"
[[ -n "$serial" ]] || { echo "no emulator: start one, or set ANDROID_SERIAL" >&2; exit 1; }

# The platform first: the cosigner names it by an identifier only its build prints.
scripts/platform.sh up
platform="$(scripts/platform.sh id)"

# The cosigner set as `make up` sets it (scripts/up-enclave.sh): the ASP, a delegate due about five
# minutes after the VTXOs it covers, and the platform with the fake Grid's view-only token.
export ENCLAVE_DIR="$repo/.enclave-run" ENCLAVE_BUNDLE=app
export GUEST_ENV="ASP_URL=http://192.168.127.254:7070,AUTO_SETTLE_SAFETY_MARGIN_SECS=15060,\
SERVICE_ORIGINS=$platform:http://192.168.127.254:7200,\
SERVICE_CREDENTIALS_GRID=dev-view:dev-view-secret,\
SERVICE_CREDENTIAL_ORIGIN_GRID=http://192.168.127.254:7300"
mkdir -p "$ENCLAVE_DIR"
compose=(docker compose -f docker-compose.enclave.yml)
miner="" approver=""
trap 'kill $miner $approver 2>/dev/null || true; "${compose[@]}" down >/dev/null 2>&1 || true' EXIT
"${compose[@]}" up -d --wait --wait-timeout 1500 || { "${compose[@]}" logs --tail 80; exit 1; }
run="$ENCLAVE_DIR/bundle/target/qemu-nitro/vtxos"
scripts/platform.sh pins "$run"

# Nothing moves on regtest unless somebody mines.
(while true; do scripts/bitcoin.sh mine >/dev/null 2>&1 || true; sleep 10; done) &
miner=$!

# The emulator's passkey provider is the test one. `flutter pub get` writes the
# android/local.properties Gradle reads.
(cd app && flutter pub get >/dev/null)
(cd app/android && ./gradlew -q :testpasskey:assembleDebug)
adb -s "$serial" install -r -t app/build/testpasskey/outputs/apk/debug/testpasskey-debug.apk
provider=com.vtxos.testpasskey/com.vtxos.testpasskey.TestPasskeyService
adb -s "$serial" shell settings put secure credential_service "$provider"
adb -s "$serial" shell settings put secure credential_service_primary "$provider"
scripts/approve-passkeys.sh "$serial" &
approver=$!

defines="$(scripts/dev-enclave-defines.sh "$run")"
cd app
# shellcheck disable=SC2086 # the defines are separate flags
flutter test integration_test/app_test.dart -d "$serial" $defines
