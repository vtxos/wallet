#!/usr/bin/env bash
# Approve every passkey sheet Credential Manager shows on an emulator, as its owner would: tap its
# "Continue". For the emulator e2e, whose passkey provider is app/android/testpasskey; runs until
# killed.
#
#   scripts/approve-passkeys.sh [serial]
#
# A sign-in always shows the sheet: androidx.credentials 1.3 has no way for an app to skip it for a
# passkey, and a Flutter test cannot reach a window that is not the app's. The sheet is Play
# services' on an image with Play, Android's own Credential Manager UI on one without. It is found
# by its button rather than by window focus, which a mirror such as scrcpy can leave unset.
set -euo pipefail
adb=(adb ${1:+-s "$1"})
tick=0
while :; do
    # A dump starts a JVM on the device and floods its log, so it is only made when the sheet's
    # activity is the one in front — and every tenth time regardless, in case its name changes.
    tick=$((tick + 1))
    if (( tick % 10 )) && ! "${adb[@]}" shell dumpsys activity activities 2>/dev/null \
        | grep -m1 -E 'topResumedActivity|mResumedActivity' | grep -qE 'CredentialChooser|credentialmanager'; then
        sleep 1
        continue
    fi
    ui="$("${adb[@]}" exec-out uiautomator dump /dev/tty 2>/dev/null || true)"
    button="$(grep -oE '<node [^>]*text="Continue"[^>]*>' <<<"$ui" \
        | grep -E 'package="(com\.google\.android\.gms|com\.android\.credentialmanager)"' | head -1 || true)"
    if [[ -n "$button" ]]; then
        # Its bounds: [x1,y1][x2,y2].
        read -r x1 y1 x2 y2 < <(grep -oE 'bounds="[^"]*"' <<<"$button" | grep -oE '[0-9]+' | paste -sd' ')
        "${adb[@]}" shell input tap $(((x1 + x2) / 2)) $(((y1 + y2) / 2))
        echo "approved a passkey sheet"
        sleep 2
    fi
    sleep 1
done
