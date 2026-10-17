// The wallet against its cosigner in the dev enclave, from the device: what was the host's e2e
// suite, with every wallet the app's own client and every passkey the platform's, made and asserted
// through Credential Manager. scripts/e2e-all.sh runs it.
//
// Every call goes the real way: TLS pinned to the attested certificate, a nonce per request, and a
// WebAuthn assertion exchanged for a single-use token bound to that method and path.
//
// Not here: the cosigner refreshing funds on its own, which app_test.dart proves through the app;
// and the escrow service's own protocol — both halves arriving, a half refused, a payment paying
// once — which the cosigner's tests prove in isolation, and app_test.dart's payout end to end.

// Each test enrols its passkeys and runs its ceremonies through Credential Manager, a sheet at a
// time: package:test's 30 seconds is less than two of them take on a CI emulator.
@Timeout(Duration(minutes: 5))
library;

import 'dart:typed_data';

import 'package:blockchain_utils/blockchain_utils.dart' show SegwitBech32Encoder;
import 'package:core/ark/ark.dart' as ark;
import 'package:core/asp/asp_client.dart' show IndexerVtxo;
import 'package:core/asp/exit_chain.dart' show ChainKind;
import 'package:core/client.dart';
import 'package:core/enclave/attestation.dart';
import 'package:core/enclave/gate.dart';
import 'package:core/passkey/key_derivation.dart' show walletPolynomial;
import 'package:core/passkey/seed_source.dart';
import 'package:core/passkey/share_reconstruction.dart' show WrongPasskey;
import 'package:core/persistence/wallet_store.dart' show forbiddenStateKeys;
import 'package:core/sessions/service_delivery.dart' show RewritingDelivery;
import 'package:core/threshold_types.dart' as threshold;
import 'package:e2e/boarding_poll.dart';
import 'package:e2e/logger.dart';
import 'package:e2e/regtest_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'test_helpers/device_wallet.dart';

/// The served component's sha256, which the host can read and the device cannot: e2e-all.sh
/// passes it.
const servedGuestSha256 = String.fromEnvironment('E2E_GUEST_SHA256');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('the component serves', () {
    test('GetServerInfo reports the configured network', () async {
      final alice = await wallet('info_alice');
      try {
        final info = await alice.client.getServerInfo();
        // regtest is the cosigner's default, and it is what it has to fall back to: the image's
        // environment is all `S3FS_*`, which the runtime strips, so BITCOIN_NETWORK never arrives.
        expect(info.bitcoinNetwork, 'regtest');
      } finally {
        await alice.close();
      }
    });
  });

  group('attestation', () {
    test('every approval attests the enclave, down to the component it serves', () async {
      expect(servedGuestSha256, hasLength(64), reason: 'run with E2E_GUEST_SHA256');
      final alice = await wallet('attest_alice');
      try {
        await alice.client.getServerInfo();
        expect(alice.gate.attested!.guestSha256, servedGuestSha256,
            reason: 'user_data names the component the enclave measured and serves');
      } finally {
        await alice.close();
      }
    });

    test('an enclave serving another component is refused before anything is sent', () async {
      final real = await wallet('pinned_alice');
      final passkey = real.gate.authenticator;
      await real.close();
      final pins = enclaveGate().pins;
      final gate = EnclaveGate(
        endpoint: real.gate.endpoint,
        pins: EnclavePins(
          trustRoot: pins.trustRoot,
          pcr0: pins.pcr0,
          // PCR0 alone cannot catch this: the right runtime, serving something else.
          pcr16: '00' * 48,
        ),
        origin: real.gate.origin,
        authenticator: passkey,
      );
      try {
        // Refused on the document, before the passkey is asked: no sheet comes up for it.
        await expectLater(gate.mint(method: 'POST', path: '/cosigner.v1.Cosigner/GetServerInfo'),
            throwsA(isA<AttestationException>()));
        expect(gate.attested, isNull, reason: 'nothing a refused document said is kept');
      } finally {
        gate.close();
      }
    });

    test('a cosigner channel refuses a certificate the gate did not attest', () async {
      final real = await wallet('elsewhere_alice');
      final gate = _PinnedElsewhere(real.gate);
      await real.close();
      final client = MpcClient.enclave(gate: gate, aspHost: host, aspPort: 7070);
      try {
        await expectLater(
          client.getServerInfo(),
          // The socket served the real certificate, which is not the pinned one.
          throwsA(predicate((e) => '$e'.contains('not the attested'))),
        );
      } finally {
        await client.close();
        gate.close();
      }
    });
  });

  group('DKG', () {
    test('a ceremony over one stream produces a key both sides derive', () async {
      final alice = await wallet('dkg_alice');
      try {
        await alice.client.doDkg();
        final key = alice.client.groupKeyHex;
        expect(key, isNotNull);
        expect(key!.length, 66, reason: 'a compressed point, hex');

        // Not self-certifying: `DkgSession` derives the group key from the wallet's own public key
        // package and throws if the cosigner's answer differs, so reaching here means both sides
        // arrived at the same key independently.
        expect(alice.client.userId, isNotNull);

        // And never a second one. A DKG over a wallet that has a key would replace it and strand
        // everything held under the old one, so the cosigner refuses before dealing anything.
        await expectLater(alice.client.doDkg(), throwsA(anything),
            reason: 'a second DKG on the same wallet must be refused');
        expect(alice.client.groupKeyHex, key, reason: 'and the refusal must not touch the key');
      } finally {
        await alice.close();
      }
    });

    /// Enrolling for wakes rides the ceremony: a `RegisterDevice` of its own would be a second
    /// passkey approval straight after onboarding, for nothing the user asked for.
    test('the ceremony enrols the device token it carries, with no call of its own', () async {
      final dana = await wallet('dkg_dana');
      try {
        const token = 'e2e-dkg-device-token-0123456789abcdef';
        final enrolled = <String>[];
        dana.client.onDeviceEnrolled = enrolled.add;
        dana.client.offerDeviceToken(token);

        await dana.client.doDkg();

        expect(enrolled, [token], reason: 'the cosigner should report the token enrolled');
        expect(await dana.client.deviceCount(), 1);
      } finally {
        await dana.close();
      }
    });

    test('two passkeys are two tenants, with two wallets', () async {
      final alice = await wallet('tenant_alice');
      final bob = await wallet('tenant_bob');
      try {
        await alice.client.doDkg();
        await bob.client.doDkg();

        // Different tenants, different filesystems, different seals: the runtime resolves a tenant
        // from each caller's own token and hands it a scoped filesystem, so this is the runtime's
        // isolation being checked rather than ours.
        expect(alice.client.groupKeyHex, isNot(equals(bob.client.groupKeyHex)));
      } finally {
        await alice.close();
        await bob.close();
      }
    });
  });

  group('addresses', () {
    test('the wallet derives its own, and they are stable', () async {
      final alice = await wallet('addr_alice');
      try {
        await alice.client.doDkg();

        // Straight from the ASP: the cosigner has no socket, so the client asks arkd itself and
        // passes what it learns back in on each SendOpen/RenewOpen.
        final info = await alice.client.getArkInfo();
        expect(info.signerPubkey, isNotEmpty);
        expect(info.network, 'regtest');
        expect(info.unilateralExitDelay, greaterThan(0));
        expect(info.boardingExitDelay, greaterThan(0));
        expect(info.boardingExitDelay, isNot(equals(info.unilateralExitDelay)),
            reason: 'the mixed-delay tests depend on these differing');

        // Derived here, over FFI, from the wallet's own key and the ASP's — not fetched.
        final arkAddress = await alice.client.getArkAddress();
        final boarding = await alice.client.getBoardingAddress();
        expect(arkAddress, startsWith('tark1'), reason: 'regtest Ark address');
        expect(boarding, startsWith('bcrt1p'), reason: 'regtest boarding address');

        expect(await alice.client.getArkAddress(), arkAddress, reason: 'derivation is a function');
        expect(await alice.client.getBoardingAddress(), boarding);
      } finally {
        await alice.close();
      }
    });

    test('a fresh wallet holds nothing', () async {
      final bob = await wallet('fresh_bob');
      try {
        await bob.client.doDkg();
        // Both scripts are queried, always — a wallet holds a mixed set, and asking for one makes
        // the other bucket invisible, which is indistinguishable from empty.
        expect(await bob.client.listVtxos(), isEmpty);
      } finally {
        await bob.close();
      }
    });
  });

  // ===============================================================================================
  // Money. Every test here moves funds, and every one stops mid-stream for the wallet to sign. Each
  // uses its own wallet names, so its own tenants: nothing one test leaves behind can be scanned by
  // another.
  // ===============================================================================================

  late RegtestHelper btc;

  setUpAll(() async {
    try {
      await RegtestHelper(rpcUrl: 'http://$host:18443').createWallet('default');
    } catch (e) {
      if (!e.toString().contains('already')) rethrow;
    }
    btc = RegtestHelper(rpcUrl: 'http://$host:18443/wallet/default');
  });

  /// Fund [w]'s boarding address with [btcAmount], settle it into Ark, and return what it holds.
  Future<List<IndexerVtxo>> boardAndRenew(Wallet w, double btcAmount) async {
    final boarding = await w.client.getBoardingAddress();
    await btc.sendToAddress(boarding, btcAmount);
    await btc.generateToAddress(1, await btc.getNewAddress());
    final minSats = (btcAmount * 1e8).round();
    final deposits = await pollBoardingUtxos(boarding, minSats, host: host);
    expect(deposits, isNotEmpty, reason: '${w.name}: electrs should index the deposit');
    final commitment = await whileMining(btc, () => renewBoarding(w.client, deposits));
    expect(commitment, isNotEmpty, reason: '${w.name}: the renewal should return a commitment');
    return eventually(
      '${w.name}: the boarded VTXO to be indexed',
      w.client.listVtxos,
      // Less the ASP's boarding fee, which is small next to any amount used here.
      (List<IndexerVtxo> v) => v.totalSats > minSats * 0.9,
    );
  }

  /// Send, then wait until both sides see exactly what they should.
  Future<void> sendAndSettleBalances(Wallet from, Wallet to, int amount) async {
    final fromBefore = (await from.client.listVtxos()).totalSats;
    final toBefore = (await to.client.listVtxos()).totalSats;
    final txid = await whileMining(
        btc, () async => from.client.sendVtxo(await to.client.getArkAddress(), amount));
    expect(txid, isNotEmpty);

    await eventually("${to.name} to receive $amount", to.client.listVtxos,
        (List<IndexerVtxo> v) => v.totalSats == toBefore + amount);
    final left = await eventually("${from.name}'s change to land", from.client.listVtxos,
        (List<IndexerVtxo> v) => v.totalSats == fromBefore - amount);
    for (final v in left) {
      expect(v.script, isNotEmpty, reason: 'every VTXO sits under a script');
    }
  }

  /// The exits are the point of the whole arrangement: a spend of each VTXO through its own exit
  /// leaf, signed by the 2-of-2 while the cosigner is here, kept by the wallet. If the cosigner
  /// never answers again, these are the money — so they are checked to be complete, correct and
  /// re-issued whenever the set of VTXOs changes.
  group('the way out', () {
    test('every renewal signs an exit for every VTXO it covers', () async {
      final erin = await wallet('exit_erin');
      try {
        await erin.client.doDkg();

        // Where the exits pay: an address in bitcoind's wallet, which this wallet cannot spend.
        await erin.client.setExitAddress(await btc.getNewAddress());

        final held = await boardAndRenew(erin, 0.005);
        final vtxo = held.single;

        final exits = erin.client.exits;
        expect(exits, hasLength(1), reason: 'one exit per held VTXO');
        final exit = exits.single;
        expect(exit.outpoint, '${vtxo.txid}:${vtxo.vout}');
        expect(exit.amountSats, vtxo.amountSats,
            reason: 'an exit pays the whole VTXO — it carries an anchor instead of a fee');
        expect(exit.sequence, greaterThan(0), reason: "it waits out the VTXO's exit delay");
        expect(exit.rawTx.length, greaterThan(200), reason: 'a signed transaction, not a stub');

        // The exit is the last hop. Everything above it — the batch tree, down from a commitment
        // transaction already on-chain — has to be published first, and the indexer is where those
        // come from.
        final chain = await erin.client.exitChain(exit);
        expect(chain.missing, isEmpty, reason: 'the indexer should know the whole path');
        expect(chain.hops.first.kind, ChainKind.commitment,
            reason: 'a path starts at something already on-chain');
        expect(chain.hops.last.kind, ChainKind.exit);
        expect(chain.hops.last.rawTx, exit.rawTx);
        expect(chain.hops.length, greaterThanOrEqualTo(3),
            reason: 'commitment, at least one tree transaction, and the exit');
        for (final hop in chain.toPublish) {
          expect(hop.rawTx, isNotNull,
              reason: '${hop.kind.name} ${hop.txid} has to be broadcastable, not just named');
          expect(hop.rawTx, isNotEmpty);
        }
        Log.info('exit path: ${chain.hops.map((h) => h.kind.name).join(' -> ')}');

        // Spending the VTXO makes its exit meaningless, and the renewal on the way out replaces it.
        final bob = await wallet('exit_bob');
        await bob.client.doDkg();
        final bobAddress = await bob.client.getArkAddress();
        await whileMining(btc, () => erin.client.sendVtxo(bobAddress, 10000));
        final after = erin.client.exits;
        expect(after.map((e) => e.outpoint), isNot(contains(exit.outpoint)),
            reason: "the spent VTXO's exit is gone");
        expect(after, isNotEmpty, reason: 'the change VTXO has an exit of its own');
        expect(after.single.amountSats, lessThan(vtxo.amountSats));

        // Bob received, and has renewed nothing yet: he holds money with no exit until he protects
        // it. That gap is what the Exit tab shows, and what `protectFunds` closes.
        expect(bob.client.exits, isEmpty);
        await bob.client.setExitAddress(await btc.getNewAddress());
        final renewed = await bob.client.protectFunds();
        expect(renewed.exits, hasLength(1));
        expect(bob.client.exits.single.amountSats, 10000);
      } finally {
        await erin.close();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));

    /// The claim every other exit test rests on: that these transactions actually spend.
    ///
    /// The VTXO here is synthetic: an ordinary on-chain output carrying this wallet's VTXO script,
    /// funded by bitcoind. A real VTXO lives in a batch tree whose branch would have to be published
    /// first, and that branch would change nothing about the hop being proven here, the last one.
    test('a signed exit really spends, and bitcoind agrees', () async {
      final alice = await wallet('exit_spend');
      try {
        await alice.client.doDkg();
        final exitAddress = await btc.getNewAddress();
        await alice.client.setExitAddress(exitAddress);

        // An output under this wallet's own VTXO script: same owner key, same ASP key, same exit
        // delay, so the exit leaf the cosigner signs against is the one that guards it.
        final info = await alice.client.getArkInfo();
        final script = ark.vtxoScriptPubkeyHex(
          ownerXOnlyHex: alice.client.groupXOnlyPubKey!,
          aspPubkeyHex: info.signerPubkey,
          exitDelay: info.unilateralExitDelay,
          network: info.network,
        );
        final program = Uint8List.fromList([
          for (var i = 4; i < script.length; i += 2)
            int.parse(script.substring(i, i + 2), radix: 16),
        ]);
        final vtxoAddress = SegwitBech32Encoder.encode('bcrt', 1, program);

        final fundingTxid = await btc.sendToAddress(vtxoAddress, 0.002);
        await btc.generateToAddress(1, await btc.getNewAddress());
        final funding = await btc.getRawTransaction(fundingTxid);
        final output = (funding['vout'] as List)
            .cast<Map<String, dynamic>>()
            .firstWhere((o) => (o['scriptPubKey'] as Map)['hex'] == script);
        final amountSats = ((output['value'] as num) * 1e8).round();
        final fundedAt = (funding['blocktime'] as num).toInt();

        // The cosigner signs its exit. It derives the script from its own key, so an output that is
        // not ours is one it cannot produce a spendable signature for anyway.
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final renewed = await alice.client.protectFunds(over: [
          IndexerVtxo(
            txid: fundingTxid,
            vout: (output['n'] as num).toInt(),
            amountSats: amountSats,
            script: script,
            isSpent: false,
            createdAt: now,
            expiresAt: now + 86400,
            exitDelay: info.unilateralExitDelay,
          )
        ]);
        final exit = renewed.exits.single;
        expect(exit.amountSats, amountSats);

        // Too early: the timelock is the whole point of an exit, so it must actually bind.
        final tooEarly = await btc.testMempoolAccept([exit.rawTx]);
        expect(tooEarly.single['allowed'], isFalse,
            reason: 'an exit must not be spendable before its delay');
        expect('${tooEarly.single['reject-reason']}', contains('non-BIP68'),
            reason: 'and the reason must be the timelock, not something else');

        // Wait it out. The delay is in seconds, so what has to pass is the chain's median time —
        // mined blocks follow the node's clock.
        await btc.setMockTime(fundedAt + info.unilateralExitDelay + 3600);
        await btc.generateToAddress(12, await btc.getNewAddress());
        expect(await btc.medianTime(), greaterThan(fundedAt + info.unilateralExitDelay));

        // Consensus: mined directly, because an exit pays no fee and a node will not relay it
        // alone. The script, the sequence, the witness and the FROST signature are all valid.
        final exitTxid = (await btc.decodeRawTransaction(exit.rawTx))['txid'] as String;
        await btc.generateBlock(await btc.getNewAddress(), [exit.rawTx]);
        final mined = await btc.getRawTransaction(exitTxid);
        expect(mined['confirmations'], greaterThanOrEqualTo(1), reason: 'the exit is in a block');

        // And the money is where the owner said it should go.
        final paid = (mined['vout'] as List)
            .cast<Map<String, dynamic>>()
            .firstWhere((o) => ((o['scriptPubKey'] as Map)['address'] ?? '') == exitAddress);
        expect(((paid['value'] as num) * 1e8).round(), amountSats,
            reason: 'an exit pays the whole VTXO — the fee comes from whoever bumps it');
        Log.info('exit $exitTxid paid $amountSats sats to $exitAddress');
      } finally {
        await alice.close();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));

    /// A wallet that never set one still works — it simply has nothing to fall back on.
    test('a wallet with no exit address still renews its delegate', () async {
      final dana = await wallet('exit_dana');
      try {
        await dana.client.doDkg();
        await boardAndRenew(dana, 0.005);
        expect(dana.client.delegateStatus, isNotNull);
        expect(dana.client.exits, isEmpty);
      } finally {
        await dana.close();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));
  });

  group('the full flow', () {
    /// Board, settle, then three sends — the third spending down the change of the second, which is
    /// a different input than the boarded VTXO the first one spent.
    test('board, settle, and three sends Alice to Bob', () async {
      final alice = await wallet('flow_alice');
      final bob = await wallet('flow_bob');
      try {
        await alice.client.doDkg();
        await bob.client.doDkg();

        // A token that arrives after onboarding — FCM rotated it — rides the next renewal.
        const token = 'e2e-renew-device-token-0123456789abcdef';
        final enrolled = <String>[];
        alice.client.onDeviceEnrolled = enrolled.add;
        alice.client.offerDeviceToken(token);

        final held = await boardAndRenew(alice, 0.01);
        expect(enrolled, [token], reason: 'the renewal should carry the token and enrol it');
        expect(await alice.client.deviceCount(), 1);
        expect(held, hasLength(1));
        final vtxo = held.single;
        expect(vtxo.exitDelay, greaterThan(0),
            reason: 'tagged from the script it came under — the cosigner refuses a VTXO without it');
        expect(vtxo.script, isNotEmpty);
        expect(vtxo.expiresAt, greaterThan(0));

        // Boarding renewed the delegate on its way out, on the same stream and approval: over the
        // one VTXO held, valid from its expiry less the margin.
        final boarded = alice.client.delegateStatus;
        expect(boarded, isNotNull, reason: 'boarding should renew the delegate before closing');
        expect(boarded!.covered, {'${vtxo.txid}:${vtxo.vout}'});
        expect(boarded.validAt,
            DateTime.fromMillisecondsSinceEpoch(vtxo.expiresAt * 1000).subtract(boarded.margin));
        expect(await alice.client.unprotectedVtxos(), isEmpty);

        await sendAndSettleBalances(alice, bob, 100000);
        await sendAndSettleBalances(alice, bob, 50000);
        // Spends the change the previous send produced — a unilateral-delay VTXO, not the boarded
        // one.
        await sendAndSettleBalances(alice, bob, 20000);

        expect((await bob.client.listVtxos()).totalSats, 170000);

        // Each send renewed the delegate over what was left, so Alice's change is covered with no
        // call of its own.
        expect(alice.client.delegateStatus, isNotNull);
        expect(await alice.client.unprotectedVtxos(), isEmpty,
            reason: 'a send should renew the delegate over its change before closing');

        // Bob only received. No delegate covers those funds until he protects them — one call, and
        // then one does.
        expect(bob.client.delegateStatus, isNull);
        expect(await bob.client.unprotectedVtxos(), hasLength(3));
        final renewed = await bob.client.protectFunds();
        expect(renewed.covered, hasLength(3));
        expect(await bob.client.unprotectedVtxos(), isEmpty);
      } finally {
        await alice.close();
        await bob.close();
      }
    }, timeout: const Timeout(Duration(minutes: 15)));
  });

  group('nothing secret at rest', () {
    /// No share is stored: each operation rebuilds one from the passkey's seed and the half the
    /// cosigner returns on the stream it approved. A right seed signs a renewal the ASP accepts and
    /// leaves nothing of itself on disk; a wrong one is refused on the device, before anything is
    /// opened.
    test('the right seed signs and leaves nothing behind; a wrong seed cannot spend', () async {
      final seed = Uint8List.fromList(List<int>.generate(32, (i) => (i * 7 + 3) & 0xff));
      final wrong = Uint8List.fromList(List<int>.generate(32, (i) => (i * 7 + 4) & 0xff));

      final alice = await wallet('atrest_alice');
      final bob = await wallet('atrest_bob');
      try {
        // Wired before DKG: the wallet's polynomial is derived from this.
        alice.client.setSeedSource(FixedSeedSource(seed));
        await alice.client.doDkg();
        await bob.client.doDkg();

        final held = await boardAndRenew(alice, 0.01);
        expect(held, hasLength(1),
            reason: 'a VTXO means the rebuilt share signed validly, twice, in-band — the intent '
                'proof and the commitment — and then the delegate, all off one contribution');

        // What is on disk after a DKG, a boarding and its delegate. The file, not the live value:
        // Hive appends, so anything ever written is still in it.
        final polynomial = await walletPolynomial(Uint8List.fromList(seed));
        final raw = await stateFileOf(alice).readAsBytes();
        final rawText = String.fromCharCodes(raw).toLowerCase();
        for (final key in forbiddenStateKeys) {
          expect(rawText.contains(key.toLowerCase()), isFalse, reason: '"$key" is on disk');
        }
        for (final secret in {
          'the seed': seed,
          'a0': threshold.bigIntToBytes(polynomial.a0.scalar),
          'a1': threshold.bigIntToBytes(polynomial.a1),
        }.entries) {
          expect(rawText.contains(_hex(secret.value)), isFalse,
              reason: '${secret.key} is on disk, as hex');
          expect(_containsBytes(raw, secret.value), isFalse,
              reason: '${secret.key} is on disk, as bytes');
        }

        alice.client.setSeedSource(FixedSeedSource(wrong));
        await expectLater(
          alice.client.sendVtxo(await bob.client.getArkAddress(), 1000),
          throwsA(isA<WrongPasskey>()),
          reason: 'a wrong seed derives another wallet, and is refused before a stream is opened',
        );
      } finally {
        await alice.close();
        await bob.close();
      }
    }, timeout: const Timeout(Duration(minutes: 15)));
  });

  group('a mixed exit-delay set', () {
    /// A send spending a boarded VTXO and a received one together, in both orders: they sit under
    /// different scripts, and a send that reused one input's spend info for every input produces a
    /// wrong prevout the ASP rejects.
    test('a send spends boarded and received VTXOs together, in both orders', () async {
      final alice = await wallet('mixed_alice');
      final bob = await wallet('mixed_bob');
      try {
        await alice.client.doDkg();
        await bob.client.doDkg();
        final info = await alice.client.getArkInfo();
        expect(info.boardingExitDelay, isNot(equals(info.unilateralExitDelay)),
            reason: 'with equal delays this test cannot detect the bug — check the arkd config');

        await boardAndRenew(alice, 0.002);
        await boardAndRenew(bob, 0.003);

        // Alice receives, so she now holds one of each.
        await sendAndSettleBalances(bob, alice, 150000);
        final mixed = await alice.client.listVtxos();
        expect(mixed.map((v) => v.exitDelay).toSet(), hasLength(2),
            reason: 'Alice must hold a boarded AND a received VTXO');

        // Spends across both delays: more than either VTXO alone.
        await sendAndSettleBalances(alice, bob, 250000);

        // Reverse: the change is already held, and a fresh boarding arrives after it.
        await boardAndRenew(alice, 0.002);
        final reversed = await alice.client.listVtxos();
        expect(reversed.map((v) => v.exitDelay).toSet(), hasLength(2));
        await sendAndSettleBalances(alice, bob, reversed.totalSats - 10000);
      } finally {
        await alice.close();
        await bob.close();
      }
    }, timeout: const Timeout(Duration(minutes: 20)));
  });

  group('a wallet reopened from storage', () {
    /// A client restored from its own storage can still spend: a fresh object that has never seen
    /// DKG and holds no share, spending from its stored public state, its passkey and the enclave.
    test('can still spend after the client is rebuilt', () async {
      final first = await wallet('restore_carol');
      final dave = await wallet('restore_dave');
      String key;
      try {
        await first.client.doDkg();
        await dave.client.doDkg();
        key = first.client.groupKeyHex!;
        await boardAndRenew(first, 0.005);
      } finally {
        await first.close();
      }

      final reopened = await wallet('restore_carol');
      try {
        expect(await reopened.client.restoreState(), isTrue);
        expect(reopened.client.groupKeyHex, key, reason: 'the same wallet, not a new one');
        await sendAndSettleBalances(reopened, dave, 100000);
      } finally {
        await reopened.close();
        await dave.close();
      }
    }, timeout: const Timeout(Duration(minutes: 15)));
  });

  group('a wallet on a new phone', () {
    /// The passkey is the whole wallet: nothing else crosses from the old device. Reporting the same
    /// group key would not prove the rebuilt share is right — that is public. Spending does.
    test('the passkey alone brings it back, and it can still spend', () async {
      final erin = await wallet('recover_erin');
      final frank = await wallet('recover_frank');
      late String key;
      late int held;
      try {
        await erin.client.doDkg();
        await frank.client.doDkg();
        key = erin.client.groupKeyHex!;
        held = (await boardAndRenew(erin, 0.005)).totalSats;
      } finally {
        await erin.close();
      }

      // A new phone: the same passkey, an empty store.
      final newPhone = await newDeviceFor('recover_erin');
      try {
        expect(await newPhone.client.restoreState(), isFalse,
            reason: 'this device has never held the wallet');

        await newPhone.client.recover();

        expect(newPhone.client.groupKeyHex, key, reason: 'the same wallet, not a new one');
        expect(newPhone.client.userId, isNotNull);
        expect((await newPhone.client.listVtxos()).totalSats, held,
            reason: 'the balance was never on the old phone either — it comes from the ASP');

        await sendAndSettleBalances(newPhone, frank, 100000);
      } finally {
        await newPhone.close();
        await frank.close();
      }
    }, timeout: const Timeout(Duration(minutes: 20)));

    /// The failure that matters: a PRF that answers differently on this device. Nothing in WebAuthn
    /// promises a synced passkey yields the same PRF output everywhere, so the cosigner checks the
    /// identifier the caller derived against the one the ceremony recorded, and refuses.
    test('a passkey whose PRF answers differently is refused, not half-served', () async {
      final gina = await wallet('recover_gina');
      try {
        await gina.client.doDkg();
      } finally {
        await gina.close();
      }

      final newPhone = await newDeviceFor('recover_gina');
      try {
        newPhone.client.setSeedSource(FixedSeedSource(Uint8List.fromList(List.filled(32, 0xab))));
        await expectLater(
          newPhone.client.recover(),
          throwsA(predicate((e) => '$e'.contains('does not derive this wallet'))),
        );
        expect(newPhone.client.groupKeyHex, isNull, reason: 'a refused recovery saves nothing');
      } finally {
        await newPhone.close();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));

    /// One tenant cannot have another wallet's half — not even knowing that wallet's seed. Mallory's
    /// passkey resolves to her own tenant, whose seal holds her wallet and never Heidi's, so the
    /// identifier she derives as Heidi matches nothing there.
    test("an authenticated tenant cannot retrieve another wallet's contribution", () async {
      final heidiSeed = Uint8List.fromList(List<int>.generate(32, (i) => (i * 11 + 5) & 0xff));
      final heidi = await wallet('tenant_heidi');
      final mallory = await wallet('tenant_mallory');
      try {
        heidi.client.setSeedSource(FixedSeedSource(heidiSeed));
        await heidi.client.doDkg();
        await mallory.client.doDkg();
      } finally {
        await heidi.close();
        await mallory.close();
      }

      // Mallory's passkey — her tenant — on a device with nothing stored, deriving as Heidi.
      final asHeidi = await newDeviceFor('tenant_mallory');
      try {
        asHeidi.client.setSeedSource(FixedSeedSource(heidiSeed));
        await expectLater(
          asHeidi.client.recover(),
          throwsA(predicate((e) => '$e'.contains('does not derive this wallet'))),
        );
        expect(asHeidi.client.isInitialized, isFalse);
        expect(await asHeidi.client.restoreState(), isFalse,
            reason: 'a refused recovery writes nothing');
      } finally {
        await asHeidi.close();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));
  });

  group('services', () {
    /// A service this deployment does not name is refused before anything is dealt.
    test('a service the deployment does not name is refused before anything is dealt', () async {
      final dave = await wallet('pair_dave');
      try {
        await dave.client.doDkg();
        final stranger =
            threshold.Identifier.derive(Uint8List.fromList('nobody-the-image-knows'.codeUnits));

        await expectLater(
          dave.client.setUpEscrow(
            serviceIdentifier: stranger,
            policy: const {'op': 'always'},
            deadline: DateTime.now().add(const Duration(hours: 1)),
            delivery: RewritingDelivery(hostFacingHost: host),
          ),
          throwsA(predicate((e) => '$e'.contains('does not know that service'))),
        );
        expect(dave.client.escrows, isEmpty, reason: 'refused before an escrow was minted');
      } finally {
        await dave.close();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}

String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

bool _containsBytes(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// A gate whose approvals are real but whose pin names some other certificate — what an intercepted
/// channel looks like from the client's side.
class _PinnedElsewhere extends EnclaveGate {
  _PinnedElsewhere(EnclaveGate real)
      : super(
          endpoint: real.endpoint,
          pins: real.pins,
          origin: real.origin,
          authenticator: real.authenticator,
        );

  static final _elsewhere = AttestedConnection(
    certificateSha256: '00' * 32,
    guestSha256: '00' * 32,
    timestamp: DateTime.now(),
  );

  @override
  AttestedConnection? get attested => _elsewhere;

  @override
  Future<AttestedConnection> attest() async => _elsewhere;
}
