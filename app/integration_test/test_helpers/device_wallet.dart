/// Wallets on this device, for integration_test/enclave_test.dart: the client the app builds, with
/// the platform's passkey made through Credential Manager — on the emulator, testpasskey's, each of
/// its sheets approved by scripts/approve-passkeys.sh.
library;

import 'dart:async';
import 'dart:io';

import 'package:app/passkey/platform_passkey.dart';
import 'package:app/services/server_host.dart' as server_host;
import 'package:core/asp/asp_client.dart' show IndexerVtxo;
import 'package:core/client.dart';
import 'package:core/enclave/gate.dart';
import 'package:e2e/logger.dart';
import 'package:e2e/regtest_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

/// The host, as the emulator reaches it: the dev enclave, arkd, electrs and bitcoind are all there.
const host = '10.0.2.2';

class Wallet {
  Wallet(this.name, this.client, this.gate);
  final String name;
  final MpcClient client;
  final EnclaveGate gate;

  Future<void> close() async {
    await client.close();
    gate.close();
  }
}

/// This run's, so one run's wallet is never opened against another run's tenant.
final _runId = DateTime.now().millisecondsSinceEpoch.toRadixString(36);

/// Each name's passkey, once enrolled: a second [wallet] of the same name is the same wallet.
final _credentials = <String, String>{};
Directory? _dir;

/// The wallet [name], enrolling a passkey for it the first time.
Future<Wallet> wallet(String name) => _open(name, storageId: 'e2e_${name}_$_runId');

/// The same passkey on a phone that has never held this wallet: its credential, so the same tenant
/// and the same cosigner, with an empty store.
Future<Wallet> newDeviceFor(String name) {
  if (!_credentials.containsKey(name)) throw StateError('$name has no passkey to recover with');
  return _open(name, storageId: 'e2e_${name}_device2_$_runId');
}

/// The file [w]'s client state is appended to, for a test that reads what is on disk.
File stateFileOf(Wallet w) =>
    File('${_dir!.path}/mpc_client/${'e2e_${w.name}_$_runId'.toLowerCase()}.hive');

/// A gate to the dev enclave, pinned to this boot as the app is (DEV_ENCLAVE_* defines).
EnclaveGate enclaveGate() => EnclaveGate(
      endpoint: server_host.enclaveEndpoint(host),
      pins: server_host.DevEnclaveConfig.fromDefines.pins(),
      origin: server_host.origin(host),
    );

Future<Wallet> _open(String name, {required String storageId}) async {
  if (_dir == null) {
    final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/e2e_$_runId')
      ..createSync(recursive: true);
    Hive.init(dir.path);
    await MpcClient.initPersistence(path: '${dir.path}/mpc_client');
    _dir = dir;
  }
  final gate = enclaveGate();
  final passkey =
      PlatformPasskey(rpId: server_host.relyingPartyId(host), credentialId: _credentials[name]);
  if (!passkey.isRegistered) {
    Log.info('enrolling a passkey for $name');
    final enrolment = await gate.enrol(passkey, displayName: name);
    passkey.adopt(enrolment.credentialId);
    _credentials[name] = enrolment.credentialId;
  }
  gate.authenticator = passkey;
  final asp = server_host.aspEndpoint(host);
  final client = MpcClient.enclave(
    gate: gate,
    aspHost: asp.host,
    aspPort: asp.port,
    aspSecure: asp.secure,
    storageId: storageId,
  );
  // As the app wires it: the wallet's key is derived from the passkey's PRF, for every operation.
  client.setSeedSource(passkey.seedSource);
  return Wallet(name, client, gate);
}

extension TotalSats on List<IndexerVtxo> {
  int get totalSats => fold(0, (sum, v) => sum + v.amountSats);
}

/// Mine a block every few seconds for as long as [body] runs: nothing confirms on regtest unless
/// somebody mines, and the ASP waits on confirmations.
Future<T> whileMining<T>(RegtestHelper btc, Future<T> Function() body) async {
  var mining = true;
  final miner = Timer.periodic(const Duration(seconds: 3), (_) async {
    if (!mining) return;
    try {
      await btc.generateToAddress(1, await btc.getNewAddress());
    } catch (_) {
      // A missed block delays the round; it does not fail it.
    }
  });
  try {
    return await body();
  } finally {
    mining = false;
    miner.cancel();
  }
}

/// Poll until [check] holds, or fail naming what was being waited for.
Future<T> eventually<T>(
  String what,
  Future<T> Function() read,
  bool Function(T) check, {
  Duration timeout = const Duration(minutes: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  late T last;
  while (DateTime.now().isBefore(deadline)) {
    last = await read();
    if (check(last)) return last;
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  fail('timed out after $timeout waiting for $what; last saw $last');
}
