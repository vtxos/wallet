import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:app/main.dart' show VtxosApp;
import 'package:app/services/mpc_service.dart';
import 'package:app/services/payout_service.dart';

Widget buildTestApp() {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) {
        final svc = MpcService();
        svc.initFuture = svc.init();
        return svc;
      }),
      // As main.dart has it: the send screens read it.
      ChangeNotifierProvider(
        lazy: false,
        create: (context) => PayoutService(context.read<MpcService>()),
      ),
    ],
    child: const VtxosApp(),
  );
}
