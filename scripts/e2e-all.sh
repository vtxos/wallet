#!/usr/bin/env bash
# Every e2e, on one dev enclave: the suite (e2e/test/enclave_ark_test.dart, software passkeys) and
# the app's full flow on an Android emulator (app/integration_test/app_test.dart): a passkey, DKG,
# boarding, the cosigner's own renewal, an entry, the Exit tab and a payout through the platform.
#
# The enclave is the dev enclave image's app bundle (ENCLAVE_BUNDLE=app). Its relying party is
# vtxos.com, and it allows https://vtxos.com, which the suite's software passkeys claim, as well as
# the app's android:apk-key-hash origins. The cosigner has the suite's settings (e2eSettings), which
# name both the suite's escrow service and MerlinPlatform.
#
# The app's passkey takes the real path, PasskeyPlugin → Credential Manager → a provider: the
# provider is app/android/testpasskey, set as the emulator's over adb, and
# scripts/approve-passkeys.sh taps each sheet's Continue as the owner would.
#
#   make e2e-all       with an emulator up, API 34 or later; ANDROID_SERIAL picks one of several
#
# `make e2e-all` brings up regtest and arkd and builds both FFIs first. MerlinPlatform is found as
# scripts/platform.sh finds it. Both suites run whatever the first does; it fails if either did.
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
compose=(docker compose -f docker-compose.enclave.yml)
miner="" approver=""
trap 'kill $miner $approver 2>/dev/null || true; "${compose[@]}" down >/dev/null 2>&1 || true' EXIT
"${compose[@]}" up -d --wait --wait-timeout 1500 || { "${compose[@]}" logs --tail 80; exit 1; }
run="$ENCLAVE_DIR/bundle/target/qemu-nitro/vtxos"
scripts/platform.sh pins "$run"

# Nothing moves on regtest unless somebody mines.
(while true; do scripts/bitcoin.sh mine >/dev/null 2>&1 || true; sleep 10; done) &
miner=$!

suite=0
make --no-print-directory e2e-enclave ENCLAVE_RUN="$run" FFI_DEP= || suite=$?

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

app=0
defines="$(scripts/dev-enclave-defines.sh "$run")"
# shellcheck disable=SC2086 # the defines are separate flags
(cd app && flutter test integration_test/app_test.dart -d "$serial" $defines) || app=$?

echo "the suite: $([[ $suite == 0 ]] && echo passed || echo "failed ($suite)")," \
     "the app: $([[ $app == 0 ]] && echo passed || echo "failed ($app)")"
[[ $suite == 0 && $app == 0 ]]
