#!/usr/bin/env bash
# Approve every passkey sheet Credential Manager shows on an emulator, as its owner would: tap
# "Continue" whenever the sheet is in front. For the emulator e2e, whose passkey provider is
# app/android/testpasskey; runs until killed.
#
#   scripts/approve-passkeys.sh [serial]
#
# A sign-in always shows the sheet: androidx.credentials 1.3 has no way for an app to skip it for a
# passkey, and a Flutter test cannot reach a window that is not the app's.
set -euo pipefail
adb=(adb ${1:+-s "$1"})
while :; do
    if "${adb[@]}" shell dumpsys window 2>/dev/null | grep -m1 mCurrentFocus | grep -q CredentialChooser; then
        ui="$("${adb[@]}" exec-out uiautomator dump /dev/tty 2>/dev/null || true)"
        # The button's label, then the bounds of the node that carries it: [x1,y1][x2,y2].
        read -r x1 y1 x2 y2 < <(grep -oE '<node [^>]*text="Continue"[^>]*>' <<<"$ui" | head -1 \
            | grep -oE 'bounds="[^"]*"' | grep -oE '[0-9]+' | paste -sd' ') || true
        if [[ -n "${y2:-}" ]]; then
            "${adb[@]}" shell input tap $(((x1 + x2) / 2)) $(((y1 + y2) / 2))
            echo "approved a passkey sheet"
            sleep 2
        else
            echo "a passkey sheet with no Continue: $(grep -oE ' text="[^"]+"' <<<"$ui" | paste -sd' ')"
        fi
    fi
    sleep 1
done
