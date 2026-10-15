/// Bringing up a real enclave, and wiring clients to it.
///
/// The cosigner is a Wasm component with no listener of its own, so a test cannot spawn it: it
/// needs a host, and `enclave-runtime`'s own binary refuses to serve outside an enclave because it
/// measures the guest into PCR16 before serving and that reads the Nitro Security Module. So this
/// starts the dev enclave image (`docker-compose.enclave.yml`, built by infra): enclave-runtime's
/// `dev-enclave.sh` and the released cosigner in one container, booting the real thing under QEMU.
///
/// What that buys, beyond "it runs at all":
///
///  * **Tenancy comes free.** One passkey is one tenant with its own isolated filesystem, so Alice
///    and Bob are two state files against one enclave — not two processes, and not one process
///    multiplexing on a client-side `storageId` the way the old suite did.
///  * **The client runs its real path.** TLS, the nonce, and a WebAuthn assertion per request.
///
/// Booting is slow — minutes — and only one enclave can be up at a time because MinIO's port and
/// the vsock CID are fixed. So [EnclaveHarness.start] will
/// **attach to an enclave that is already running** when `VTXOS_ENCLAVE_RUN` names its run
/// directory. That is the developer loop: leave one up in another terminal and re-run the suite
/// against it.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' show Random;

import 'package:app_core/client.dart';
import 'package:app_core/enclave/dev_enclave.dart';
import 'package:app_core/enclave/gate.dart';
import 'package:hive/hive.dart';

import 'logger.dart';

/// One wallet: its passkey, its tenant, its client.
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

class EnclaveHarness {
  EnclaveHarness._({
    required this.runDir,
    required this.pcr0,
    required this.pcr16,
    required this.trustRoot,
    required this.port,
    required this.attached,
    this.runtimeRepo,
    Map<String, String>? compose,
  }) : _compose = compose;

  /// `target/qemu-nitro/<name>/` — the trust root, the passkey state files, the console log and
  /// every wake the guest raised.
  final String runDir;

  /// What every client here pins: each approval verifies the enclave's attestation document against
  /// these, and the cosigner channel refuses a certificate the document did not bind.
  final String pcr0;
  final String pcr16;
  final String trustRoot;

  final int port;

  /// True when we found an enclave already up rather than booting one. Teardown leaves it alone.
  final bool attached;

  /// Distinguishes this run's wallets from every earlier run's against the same enclave.
  ///
  /// A wallet is a passkey, and a passkey is a tenant whose sealed state outlives the process. So a
  /// second run naming its wallet `alice` again would reach the first run's tenant — whose seal
  /// already holds a key — and its DKG would be refused, correctly: the cosigner will not replace a
  /// wallet's key. Fresh names per run are what fresh wallets are.
  final String runId = List<int>.generate(4, (_) => Random.secure().nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

  /// The runtime whose passkey client enrols here: the image's copy of it, when we started one.
  final String? runtimeRepo;

  /// `docker compose`'s environment, when we started the enclave and so must stop it.
  final Map<String, String>? _compose;

  late final DevEnclave enclave = DevEnclave(
      runDir: runDir, port: port, pcr0: pcr0, pcr16: pcr16, runtimeRepo: runtimeRepo);

  /// The repository, from `e2e/`, where the suite runs.
  static String get _repo => Directory.current.parent.path;
  static String get _composeFile => '$_repo/docker-compose.enclave.yml';

  /// Attach to a running enclave, or start the dev enclave image.
  ///
  /// [component] serves another cosigner build than the image's (as does `COSIGNER_WASM`).
  /// [settings] are the cosigner's, as `NAME=VALUE`: written into the component as it is uploaded,
  /// so the enclave measures them into PCR16 with its code. Among them `SERVICE_ORIGINS`, the
  /// escrow services it may pair with — a wallet names a service *id* and never a URL — which is
  /// decided before the enclave boots, so a test that pairs starts its service on a known port.
  static Future<EnclaveHarness> start({
    String? component,
    Map<String, String> settings = const {},
    Duration timeout = const Duration(minutes: 30),
  }) async {
    const port = 8443;
    final existing = Platform.environment['VTXOS_ENCLAVE_RUN'];
    if (existing != null && existing.isNotEmpty) {
      Log.info('attaching to the enclave at $existing');
      return EnclaveHarness._(
        runDir: existing,
        // Read back from the console rather than re-derived, so an attached run reports what that
        // enclave actually measured and not what this checkout would build.
        pcr0: _fromConsole(existing, RegExp(r'pcr0=([0-9a-f]{96})')),
        pcr16: _fromConsole(existing, RegExp(r'pcr16=([0-9a-f]{96})')),
        trustRoot: '$existing/trust-root.der',
        port: port,
        attached: true,
      );
    }

    // The container runs the harness from here, a host directory it mounts at the same path, and
    // sees nothing else of the host: so a component of our own goes in here too.
    final dir = '$_repo/.enclave-run';
    await Directory(dir).create(recursive: true);
    final wasm = component ?? Platform.environment['COSIGNER_WASM'];
    if (wasm != null) await File(wasm).copy('$dir/guest.wasm');
    final env = {
      'ENCLAVE_DIR': dir,
      'GUEST_ENV': [for (final s in settings.entries) '${s.key}=${s.value}'].join(','),
      if (wasm != null) 'GUEST': '$dir/guest.wasm',
    };

    Log.info('starting the dev enclave${wasm != null ? ' with $wasm' : ''}');
    final up = await Process.run(
        'docker',
        ['compose', '-f', _composeFile, 'up', '-d', '--wait', '--wait-timeout',
         '${timeout.inSeconds}'],
        environment: env);
    if (up.exitCode != 0) {
      final logs = await Process.run(
          'docker', ['compose', '-f', _composeFile, 'logs', '--tail', '80'], environment: env);
      await Process.run('docker', ['compose', '-f', _composeFile, 'down'], environment: env);
      throw StateError('the dev enclave did not come up:\n${up.stderr}\n${logs.stdout}');
    }

    final runDir = '$dir/bundle/target/qemu-nitro/vtxos';
    return EnclaveHarness._(
      runDir: runDir,
      pcr0: _fromConsole(runDir, RegExp(r'pcr0=([0-9a-f]{96})')),
      pcr16: _fromConsole(runDir, RegExp(r'pcr16=([0-9a-f]{96})')),
      trustRoot: '$runDir/trust-root.der',
      port: port,
      attached: false,
      runtimeRepo: '$dir/bundle',
      compose: env,
    );
  }

  /// A wallet, with its own passkey and therefore its own tenant and filesystem.
  ///
  /// `dev-enclave.sh` enrols `alice.json` on the way up so its printed command works; any other
  /// name is enrolled here. Registration is open — no invitation, no operator step — which is the
  /// whole reason a second wallet costs one subprocess.
  Future<Wallet> wallet(String name, {required String aspHost, required int aspPort}) async {
    await _initPersistence();
    final state = File('$runDir/$name-$runId.json');
    if (!state.existsSync()) {
      Log.info('enrolling a passkey for $name');
      await enclave.enrol(state);
    }
    final gate = enclave.gate(state);
    return Wallet(
      name,
      enclave.client(gate, aspHost: aspHost, aspPort: aspPort, storageId: 'e2e_${name}_$runId'),
      gate,
    );
  }

  /// The same passkey on a phone that has never held this wallet's key.
  ///
  /// Its enrolled credential — so the runtime resolves the same tenant and the same cosigner — with
  /// a gate of its own and an empty store. What a reinstall looks like, and the only honest way to
  /// test recovery: a client that has never run the ceremony it is recovering from.
  Future<Wallet> newDeviceFor(String name,
      {required String aspHost, required int aspPort}) async {
    await _initPersistence();
    final state = File('$runDir/$name-$runId.json');
    if (!state.existsSync()) {
      throw StateError('$name has no passkey to recover with');
    }
    final gate = enclave.gate(state);
    return Wallet(
      name,
      enclave.client(gate,
          aspHost: aspHost, aspPort: aspPort, storageId: 'e2e_${name}_device2_$runId'),
      gate,
    );
  }

  /// Hive, once per process, under a directory this run owns.
  ///
  /// Wallet state is public — who the wallet is, its delegate, its exits; no share, no dealer
  /// secret — and it is per test run, not per enclave: a fresh directory each time is what stops
  /// one run's wallet being opened against another run's tenant, whose seal knows nothing about it.
  static Directory? _hiveDir;

  /// The file [wallet]'s client state is appended to. For a test that wants to read what is
  /// actually on disk, not what the client says it wrote.
  File stateFileOf(Wallet wallet, {bool secondDevice = false}) {
    final dir = _hiveDir;
    if (dir == null) throw StateError('no wallet has been opened yet');
    final id = secondDevice ? 'e2e_${wallet.name}_device2_$runId' : 'e2e_${wallet.name}_$runId';
    return File('${dir.path}/mpc_client/${id.toLowerCase()}.hive');
  }

  static Future<void> _initPersistence() async {
    if (_hiveDir != null) return;
    final dir = Directory.systemTemp.createTempSync('merlin_e2e_');
    _hiveDir = dir;
    Hive.init(dir.path);
    await MpcClient.initPersistence(path: '${dir.path}/mpc_client');
  }

  /// Stop what we started. An attached enclave is left running — it was not ours to stop.
  ///
  /// `down` stops the harness, whose exit trap removes the QEMU, MinIO and Pebble containers it
  /// started on the host's Docker. Not reliably: a trap cut short leaves them holding the fixed ports
  /// the next run needs. Everything it creates carries the label `enclave-harness=<name>`, which is
  /// exactly what that trap removes — so this sweeps them too, for when it did not get to.
  Future<void> stop() async {
    final env = _compose;
    if (attached || env == null) return;
    Log.info('stopping the enclave');
    await Process.run('docker', ['compose', '-f', _composeFile, 'down'], environment: env);
    await _sweep(name);
  }

  /// This run's name, from its directory.
  String get name => runDir.split('/').last;

  static Future<void> _sweep(String name) async {
    final ids = await Process.run(
        'docker', ['ps', '-aq', '--filter', 'label=enclave-harness=$name']);
    final containers =
        (ids.stdout as String).split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (containers.isNotEmpty) {
      await Process.run('docker', ['rm', '-f', ...containers]);
    }
  }

  /// The runtime writes its log with colour, and the escapes land between the field name and its
  /// value — `pcr0` and `=8f20…` are separated by a reset sequence — so a pattern that reads like
  /// the text on screen matches nothing.
  static final _ansi = RegExp(r'\x1B\[[0-9;]*[a-zA-Z]');

  static String _fromConsole(String runDir, RegExp pattern) {
    final console = File('$runDir/console.log');
    if (!console.existsSync()) {
      throw StateError('no console.log in $runDir — is that an enclave run directory?');
    }
    final m = pattern.firstMatch(console.readAsStringSync().replaceAll(_ansi, ''));
    if (m == null) {
      throw StateError('could not find ${pattern.pattern} in $runDir/console.log');
    }
    return m.group(1)!;
  }
}
