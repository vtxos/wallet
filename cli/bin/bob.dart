/// Bob — the counterparty the app's integration test pays and is paid by: a wallet of this CLI's,
/// on the same dev enclave as the app's, behind three HTTP endpoints. The emulator reaches them at
/// 10.0.2.2:7090.
///
///   dart run bin/bob.dart          (`make bob-up`)
///
///   GET  /ark-address   {"address": "tark1..."}
///   GET  /balance       {"spendable_sats": 12345}
///   POST /send          {"address": "...", "amount_sats": 30000}  ->  {"txid": "..."}
///
/// The first run enrols Bob's passkey, runs DKG and funds him from bitcoind (`BOB_FUND_SATS`,
/// default 500000). After that he is reopened from the CLI's home like any of its wallets, and is
/// funded again only when he holds nothing. Built from the CLI's environment — see
/// `fromEnvironment` — plus `BOB_PORT` (7090).
library;

import 'dart:convert';
import 'dart:io';

import 'package:merlin_cli/cli.dart';

const name = 'bob';

Future<void> main() async {
  final env = Platform.environment;
  final cli = fromEnvironment();
  await cli.start();
  if (!cli.home.wallets.containsKey(name)) await cli.create(name);
  final bob = await cli.client(name);
  if (await spendable(cli) == 0) await cli.fund(name, int.parse(env['BOB_FUND_SATS'] ?? '500000'));

  final server = await HttpServer.bind(InternetAddress.anyIPv4, int.parse(env['BOB_PORT'] ?? '7090'));
  print('bob: ${await bob.getArkAddress()}, ${await spendable(cli)} sats, on :${server.port}');
  await for (final request in server) {
    final reply = request.response..headers.contentType = ContentType.json;
    try {
      final body = switch ((request.method, request.uri.path)) {
        ('GET', '/ark-address') => {'address': await bob.getArkAddress()},
        ('GET', '/balance') => {'spendable_sats': await spendable(cli)},
        ('POST', '/send') => await send(cli, jsonDecode(await utf8.decodeStream(request))),
        _ => null,
      };
      if (body == null) reply.statusCode = HttpStatus.notFound;
      reply.write(jsonEncode(body ?? {'error': 'not found'}));
    } catch (e) {
      reply
        ..statusCode = e is ArgumentError || e is FormatException
            ? HttpStatus.badRequest
            : HttpStatus.internalServerError
        ..write(jsonEncode({'error': '$e'}));
    }
    await reply.close();
  }
}

/// What Bob holds and has not spent.
Future<int> spendable(Cli cli) async {
  final vtxos = await (await cli.client(name)).listVtxos();
  return vtxos.where((v) => !v.isSpent).fold<int>(0, (sum, v) => sum + v.amountSats);
}

Future<Map<String, Object>> send(Cli cli, Object? request) async {
  if (request case {'address': String address, 'amount_sats': int sats}) {
    final bob = await cli.client(name);
    return {'txid': await cli.bitcoind.whileMining(() => bob.sendVtxo(address, sats))};
  }
  throw ArgumentError('expected {"address": "...", "amount_sats": <int>}');
}
