// The cosigner's e2e settings as GUEST_ENV takes them, for scripts/e2e-all.sh to boot the one
// enclave the suite and the app's flow share. The settings themselves are e2eSettings.

import 'package:e2e/e2e_profile.dart';

void main() => print([for (final s in e2eSettings.entries) '${s.key}=${s.value}'].join(','));
