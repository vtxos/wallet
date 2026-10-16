import 'dart:convert';

import 'package:http/http.dart' as http;

/// HTTP client for Bob (`cli/bin/bob.dart`, `make bob-up`) running on the host. The emulator
/// reaches the host via `10.0.2.2`. Bob is a CLI wallet on the same dev enclave, the counterparty
/// for the integration test's Ark send/receive.
class BobClient {
  final String _base;
  BobClient({String host = '10.0.2.2', int port = 7090})
      : _base = 'http://$host:$port';

  Future<String> arkAddress() async {
    final r = await http.get(Uri.parse('$_base/ark-address'));
    if (r.statusCode != 200) {
      throw Exception('Bob /ark-address ${r.statusCode}: ${r.body}');
    }
    return (jsonDecode(r.body) as Map<String, dynamic>)['address'] as String;
  }

  Future<int> spendableSats() async {
    final r = await http.get(Uri.parse('$_base/balance'));
    if (r.statusCode != 200) {
      throw Exception('Bob /balance ${r.statusCode}: ${r.body}');
    }
    return (jsonDecode(r.body) as Map<String, dynamic>)['spendable_sats']
        as int;
  }

  Future<String?> sendTo(String address, int amountSats) async {
    final r = await http.post(
      Uri.parse('$_base/send'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'address': address, 'amount_sats': amountSats}),
    );
    if (r.statusCode != 200) {
      throw Exception('Bob /send ${r.statusCode}: ${r.body}');
    }
    return (jsonDecode(r.body) as Map<String, dynamic>)['txid'] as String?;
  }
}
