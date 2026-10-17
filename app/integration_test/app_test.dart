// One end-to-end testWidgets covering the user lifecycle:
//   server → passkey → DKG → exit address → Ark board → the cosigner renews on its own → an entry
//   to the app re-arms the renewal → a payout through the platform → the app restarted → a new
//   phone, restored from the passkey, pays again.

// ignore_for_file: avoid_print

import 'package:app/main.dart' show VtxosApp;
import 'package:app/services/mpc_service.dart';
import 'package:app/services/payout_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';

import 'test_helpers/flows.dart';
import 'test_helpers/page_objects.dart';
import 'test_helpers/regtest_helper.dart';
import 'test_helpers/test_setup.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'full flow: onboarding → send → ark',
    (tester) async {
      final btc = RegtestHelper();
      await btc.ensureWalletLoaded('default');

      // ── Onboarding ───────────────────────────────────────────────────────
      //
      // The wallet is Ark-only now: there is no on-chain balance, no on-chain send, and no home
      // screen for either. What onboarding gained instead is the exit address, which is asked for
      // before the wallet opens because every later renewal pre-signs a spend to it.
      await resetAppState();
      await bootApp(tester);
      final exitAddress = await btc.getNewAddress();
      await Flows.completeOnboarding(tester, exitAddress: exitAddress);
      await pumpUntilFound(tester, find.byKey(const Key('arkSendMoneyBtn')));

      final ctxOnboard = tester.element(find.byKey(const Key('arkSendMoneyBtn')));
      final service = Provider.of<MpcService>(ctxOnboard, listen: false);
      expect(service.exitAddress, exitAddress,
          reason: 'the address given at onboarding is what exits will pay');

      final minerAddr = await btc.getNewAddress();

      // ── Ark boarding (skipped when ASP not configured) ──────────────────
      final arkAvailable = find.text('Ark Not Available').evaluate().isEmpty;
      if (!arkAvailable) {
        print('Ark not available — skipping ark sub-flow');
      } else {
        await ArkPage.tapBoard(tester);
        await pumpUntilFound(tester, find.byKey(const Key('arkBoardNowBtn')));

        final svcBoard = service;
        final boardingAddress = svcBoard.boardingAddress;
        expect(boardingAddress, isNotNull,
            reason: 'boardingAddress should be populated by the ark wallet');

        await btc.sendToAddress(boardingAddress!, 0.005);
        await btc.generateToAddress(1, minerAddr);

        await ArkBoardPage.waitForFundsDetected(tester);
        await ArkBoardPage.tapBoardNow(tester);
        await pumpUntilFound(
          tester,
          find.byKey(const Key('arkBoardDoneBtn')),
          timeout: const Duration(minutes: 2),
        );
        await ArkBoardPage.tapDone(tester);
        await pumpUntilFound(tester, find.byKey(const Key('arkSendMoneyBtn')));
        expect(svcBoard.arkBalance > BigInt.zero, isTrue,
            reason: 'ark balance should be non-zero after boarding');

        // Boarding re-arms the renewal on its way out, on the same approval: the board stream
        // renews the delegate once the indexer shows the new VTXO.
        await svcBoard.refreshVtxos();
        final delegDeadline =
            DateTime.now().add(const Duration(seconds: 30));
        while (!svcBoard.fundsProtected &&
            DateTime.now().isBefore(delegDeadline)) {
          await tester.pump(const Duration(seconds: 1));
        }
        expect(svcBoard.fundsProtected, isTrue,
            reason: 'boarding should have renewed the delegate on its way out. If false, its '
                'trailing renewal gave up: the indexer was slow, or the renewal failed.');

        // ── The exits are real ───────────────────────────────────────
        //
        // Renewing a delegate also signs one unilateral exit per VTXO. This is the thing the
        // cosigner cannot be asked for later: if it stops answering, these are the money.
        expect(svcBoard.exits, isNotEmpty,
            reason: 'boarding renewed the delegate, which must also have signed an exit');
        expect(svcBoard.vtxosWithoutExit, isEmpty,
            reason: 'every held VTXO should have an exit after a renewal');
        final boardedExit = svcBoard.exits.first;
        expect(boardedExit.rawTx, isNotEmpty);
        expect(boardedExit.amountSats, greaterThan(0));
        expect(boardedExit.sequence, greaterThan(0),
            reason: 'an exit waits out its VTXO\'s exit delay');

        // ── The cosigner renews on its own, and the next entry re-arms ──
        //
        // The delegate boarding signed is worth one renewal. The cosigner runs it before the VTXO
        // expires — on regtest, about five minutes after the VTXO was made — and the VTXO that
        // produces has no delegate: only the owner's passkey can sign the next. Every entry to the
        // app asks for that passkey, and re-arms with it.
        final renewedBy = DateTime.now().add(const Duration(minutes: 8));
        while (svcBoard.fundsProtected && DateTime.now().isBefore(renewedBy)) {
          await tester.pump(const Duration(seconds: 5));
          await svcBoard.refreshVtxos();
        }
        expect(svcBoard.fundsProtected, isFalse,
            reason: 'the cosigner should have run its delegate, leaving a VTXO nothing covers');

        // An entry. The lock asks for the passkey by itself — approve it on the device — and the
        // approval re-arms the renewal.
        svcBoard.lock();
        await pumpUntilFound(tester, find.byKey(const Key('unlockBtn')));
        final unlockedBy = DateTime.now().add(const Duration(minutes: 2));
        while (svcBoard.locked && DateTime.now().isBefore(unlockedBy)) {
          await tester.pump(const Duration(seconds: 1));
        }
        expect(svcBoard.locked, isFalse, reason: 'the passkey given, the lock lifts');
        final armedBy = DateTime.now().add(const Duration(minutes: 1));
        while ((!svcBoard.fundsProtected || svcBoard.vtxosWithoutExit.isNotEmpty) &&
            DateTime.now().isBefore(armedBy)) {
          await tester.pump(const Duration(seconds: 1));
          await svcBoard.refreshVtxos();
        }
        expect(svcBoard.fundsProtected, isTrue,
            reason: 'the entry re-armed the renewal over what the cosigner produced');
        expect(svcBoard.vtxosWithoutExit, isEmpty,
            reason: 'and signed its exit with the same approval');

        // ── The Exit tab shows them ─────────────────────────────────
        await ExitPage.open(tester);
        await tester.pumpAndSettle();
        expect(find.text('Your exit address'), findsOneWidget);
        expect(find.byKey(const Key('exitCopyBtn')), findsWidgets,
            reason: 'each signed exit can be copied out of the app');

        // ── A payout through the platform ───────────────────────────
        //
        // KSh 1,500 to an M-PESA number. The platform quotes it, and the one approval Confirm asks
        // for mints the payout's own escrow, pairs the platform into it, seals the deal and funds
        // it. The platform pays through the fake Grid, then is repaid out of the escrow.
        final payouts = Provider.of<PayoutService>(
            tester.element(find.byType(VtxosApp)),
            listen: false);
        final balanceBefore = svcBoard.arkBalance;
        await WalletPage.open(tester);
        await PayoutPage.sendToMpesa(tester,
            phone: '712345678', name: 'Ada Obi', amount: '1500');
        await pumpUntilTrue(
          tester,
          () => payouts.payouts.isNotEmpty && payouts.payouts.first.finished,
          timeout: const Duration(minutes: 4),
        );
        final sent = payouts.payouts.first;
        expect(sent.state, 'repaid', reason: 'the payout failed: ${sent.failure}');
        expect(sent.escrowKey, isNotNull, reason: 'it was sent from an escrow of its own');
        expect(sent.arkTxid, isNotNull, reason: 'and the platform was repaid out of it');
        await pumpUntilFound(tester, find.byKey(const Key('payoutSendAgainBtn')));
        await svcBoard.refreshVtxos();
        expect(svcBoard.arkBalance <= balanceBefore - BigInt.from(sent.sats), isTrue,
            reason: 'the agreed price, ${sent.sats} sats, left the wallet');
        final held = svcBoard.arkBalance;

        // ── The app restarted: the wallet comes back from this device's storage ──
        //
        // A new MpcService over what the last one stored, which is public state only: no share and
        // no key. A cold start is an entry, so it opens locked and asks for the passkey by itself.
        await tearDownTree(tester);
        await bootApp(tester);
        final reopened =
            Provider.of<MpcService>(tester.element(find.byType(VtxosApp)), listen: false);
        await pumpUntilTrue(tester, () => reopened.dkgComplete && !reopened.locked,
            timeout: const Duration(minutes: 2), reason: 'the reopened wallet unlocks');
        await reopened.refreshVtxos();
        expect(reopened.arkBalance, held, reason: 'the same wallet, from its own storage');

        // ── A new phone: the passkey alone brings the wallet back, and it can still spend ──
        //
        // Everything this device stored is wiped; the passkey is the provider's, and stays. Restore
        // looks for it, and recovers with it: the cosigner hands back its half only to a passkey
        // that derives this wallet.
        await tearDownTree(tester);
        await resetAppState();
        await bootApp(tester);
        await pumpUntilFound(tester, find.byKey(const Key('welcomeRestoreBtn')));
        await WelcomePage.tapRestore(tester);
        await pumpUntilFound(tester, find.byKey(const Key('serverPresetRegtest')));
        await ServerConnectPage.pickRegtest(tester);
        await RestorePage.restore(tester);
        // Restore ends where onboarding does: the exits are the old phone's, so the address is asked
        // for again and the next renewal reissues them.
        await DkgProgressPage.waitForExitAddress(tester, timeout: const Duration(minutes: 3));
        await ExitAddressPage.enter(tester, exitAddress);
        await pumpUntilFound(tester, find.byKey(const Key('walletReadyBtn')));
        await WalletReadyPage.tapGoToWallet(tester);
        await tester.pumpAndSettle();
        final restored =
            Provider.of<MpcService>(tester.element(find.byType(VtxosApp)), listen: false);
        await restored.refreshVtxos();
        expect(restored.arkBalance, held,
            reason: 'the balance was never on the old phone either — it comes from the ASP');

        // Spending proves the rebuilt share right: the group key is public, a signature is not.
        final morePayouts =
            Provider.of<PayoutService>(tester.element(find.byType(VtxosApp)), listen: false);
        await PayoutPage.sendToMpesa(tester,
            phone: '712345679', name: 'Ada Obi', amount: '150');
        await pumpUntilTrue(
          tester,
          () => morePayouts.payouts.isNotEmpty && morePayouts.payouts.first.finished,
          timeout: const Duration(minutes: 4),
        );
        expect(morePayouts.payouts.first.state, 'repaid',
            reason: 'the restored wallet paid: ${morePayouts.payouts.first.failure}');
      }
    },
    // Boarding, then the cosigner's own renewal about five minutes after it, then an entry, a
    // payout, a restart and a restore.
    timeout: const Timeout(Duration(minutes: 25)),
  );
}
