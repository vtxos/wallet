#!/usr/bin/env bash
# Every e2e, from an Android emulator against one dev enclave and MerlinPlatform:
#
#   app/integration_test/app_test.dart     the app's full flow through its screens: a passkey, DKG,
#                                          boarding, the cosigner's own renewal, an entry, the Exit
#                                          tab and a payout through the platform
#   app/integration_test/enclave_test.dart the wallet against the cosigner: attestation and its
#                                          refusals, tenants, sends, exits that really spend,
#                                          recovery, and what must be refused
#
# The enclave is the dev enclave image's app bundle (ENCLAVE_BUNDLE=app), whose relying party is
# vtxos.com and which allows the app's android:apk-key-hash origins, with the cosigner set as the e2e
# sets it (e2eSettings: the ASP, a delegate due within minutes, MerlinPlatform and the fake Grid).
#
# Every passkey takes the real path, PasskeyPlugin → Credential Manager → a provider: the provider
# is app/android/testpasskey, set as the emulator's over adb, and scripts/approve-passkeys.sh taps
# each sheet's Continue as the owner would.
#
#   make e2e-all       with an emulator up, API 34 or later; ANDROID_SERIAL picks one of several
#
# `make e2e-all` brings up regtest and arkd and builds the emulator's FFI first. MerlinPlatform is
# found as scripts/platform.sh finds it. COSIGNER_WASM serves a cosigner build of your own.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"
serial="${ANDROID_SERIAL:-$(adb devices | awk 'NR > 1 && $1 ~ /^emulator-/ && $2 == "device" { print $1; exit }')}"
[[ -n "$serial" ]] || { echo "no emulator: start one, or set ANDROID_SERIAL" >&2; exit 1; }

# The platform first: it has to be up for the pins below, and the app pays through it.
scripts/platform.sh up
scripts/platform.sh id >/dev/null

export ENCLAVE_DIR="$repo/.enclave-run" ENCLAVE_BUNDLE=app ZFS_SIZE="${E2E_ZFS_SIZE:-16G}"
GUEST_ENV="$(cd e2e && dart pub get >/dev/null && dart run bin/guest_env.dart)"
export GUEST_ENV
mkdir -p "$ENCLAVE_DIR"
# A cosigner build of your own instead of the image's: the container sees only ENCLAVE_DIR.
if [[ -n "${COSIGNER_WASM:-}" ]]; then
    cp "$COSIGNER_WASM" "$ENCLAVE_DIR/guest.wasm"
    export GUEST="$ENCLAVE_DIR/guest.wasm"
fi
# By its full path: the trap that takes it down runs from wherever the script has got to.
compose=(docker compose -f "$repo/docker-compose.enclave.yml")
miner="" approver="" logcat=""
trap 'kill $miner $approver $logcat 2>/dev/null || true; "${compose[@]}" down >/dev/null 2>&1 || true' EXIT
"${compose[@]}" up -d --wait --wait-timeout 1500 || { "${compose[@]}" logs --tail 80; exit 1; }
run="$ENCLAVE_DIR/bundle/target/qemu-nitro/vtxos"
scripts/platform.sh pins "$run"

# Nothing moves on regtest unless somebody mines.
(while true; do scripts/bitcoin.sh mine >/dev/null 2>&1 || true; sleep 10; done) &
miner=$!

# The emulator's passkey provider is the test one, built with the app's Gradle. Flutter generates
# the wrapper and android/local.properties; neither is checked in.
(cd app && flutter build apk --config-only >/dev/null)
(cd app/android && ./gradlew -q :testpasskey:assembleDebug)
adb -s "$serial" install -r -t app/build/testpasskey/outputs/apk/debug/testpasskey-debug.apk
provider=com.vtxos.testpasskey/com.vtxos.testpasskey.TestPasskeyService
adb -s "$serial" shell settings put secure credential_service "$provider"
adb -s "$serial" shell settings put secure credential_service_primary "$provider"
scripts/approve-passkeys.sh "$serial" &
approver=$!
# The emulator's own log, for when the app never gets as far as printing anything.
adb -s "$serial" logcat -c
adb -s "$serial" logcat >"$ENCLAVE_DIR/logcat.txt" 2>&1 &
logcat=$!

# This boot's pins, and the component it serves, which the device cannot read for itself.
defines="$(scripts/dev-enclave-defines.sh "$run")"
defines+=" --dart-define=E2E_GUEST_SHA256=$(sha256sum "$run/guests/guest.wasm" | cut -d' ' -f1)"
cd app
# The app's flow first: the exit test moves bitcoind's clock on, which nothing after it minds.
# Bounded: `flutter test` waits for the app to report in, with no limit of its own, so an app that
# never starts would otherwise hold the run until something else gives up.
# shellcheck disable=SC2086 # the defines are separate flags
timeout "${E2E_TEST_TIMEOUT:-60m}" \
    flutter test integration_test/app_test.dart integration_test/enclave_test.dart -d "$serial" $defines
