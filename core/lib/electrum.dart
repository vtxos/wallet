import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:blockchain_utils/blockchain_utils.dart' hide hex;
import 'package:convert/convert.dart';

/// A single unspent output returned by `blockchain.scripthash.listunspent`.
class ElectrumUtxo {
  final String txHash;
  final int vout;
  final BigInt value;
  final int height;

  const ElectrumUtxo({
    required this.txHash,
    required this.vout,
    required this.value,
    required this.height,
  });
}

/// One entry of `blockchain.scripthash.get_history`.
class ElectrumHistoryItem {
  final String txHash;
  final int height; // 0 = unconfirmed/mempool

  const ElectrumHistoryItem({required this.txHash, required this.height});
}

/// Minimal Electrum (TCP, newline-delimited JSON-RPC) client. The wallet owns
/// all on-chain Bitcoin (UTXO scan, broadcast, history); the cosigner has no
/// Bitcoin-node dependency. Mirrors the deleted cosigner-runtime electrum client.
class ElectrumClient {
  final String host;
  final int port;
  final Duration timeout;

  Socket? _socket;
  StreamSubscription<List<int>>? _sub;
  final _buffer = StringBuffer();
  int _nextId = 1;
  final _pending = <int, Completer<dynamic>>{};

  ElectrumClient(this.host, this.port,
      {this.timeout = const Duration(seconds: 30)});

  /// Electrum scripthash for an address: reversed SHA256 of its scriptPubKey.
  static String scriptHashForAddress(BitcoinBaseAddress address) {
    final spk = address.toScriptPubKey().toBytes();
    final h = QuickCrypto.sha256Hash(spk);
    return hex.encode(h.reversed.toList());
  }

  Future<void> _ensureConnected() async {
    if (_socket != null) return;
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    _socket = socket;
    _sub = socket.listen(
      _onData,
      onError: (e) => _failAll(e),
      onDone: () => _failAll('electrum: connection closed'),
      cancelOnError: true,
    );
  }

  void _onData(List<int> data) {
    _buffer.write(utf8.decode(data));
    while (true) {
      final s = _buffer.toString();
      final nl = s.indexOf('\n');
      if (nl < 0) break;
      final line = s.substring(0, nl);
      final rest = s.substring(nl + 1);
      _buffer
        ..clear()
        ..write(rest);
      if (line.trim().isEmpty) continue;
      _dispatch(line);
    }
  }

  void _dispatch(String line) {
    final dynamic msg = jsonDecode(line);
    if (msg is! Map) return;
    final id = msg['id'];
    if (id is! int) return; // server notification (e.g. scripthash subscribe)
    final completer = _pending.remove(id);
    if (completer == null) return;
    final err = msg['error'];
    if (err != null) {
      completer.completeError(StateError('electrum error: $err'));
    } else {
      completer.complete(msg['result']);
    }
  }

  void _failAll(Object error) {
    _sub?.cancel();
    _socket?.destroy();
    _socket = null;
    _sub = null;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(error);
    }
    _pending.clear();
  }

  Future<dynamic> _request(String method, List<dynamic> params) async {
    await _ensureConnected();
    final id = _nextId++;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    final payload =
        '${jsonEncode({'id': id, 'method': method, 'params': params})}\n';
    _socket!.add(utf8.encode(payload));
    return completer.future.timeout(timeout, onTimeout: () {
      _pending.remove(id);
      throw TimeoutException('electrum $method timed out');
    });
  }

  Future<List<ElectrumUtxo>> listUnspentByScriptHash(String scriptHash) async {
    final res = await _request('blockchain.scripthash.listunspent', [scriptHash]);
    final list = (res as List?) ?? const [];
    return list.map((e) {
      final m = e as Map;
      return ElectrumUtxo(
        txHash: m['tx_hash'] as String,
        vout: m['tx_pos'] as int,
        value: BigInt.from(m['value'] as int),
        height: (m['height'] as int?) ?? 0,
      );
    }).toList();
  }

  Future<List<ElectrumUtxo>> listUnspent(BitcoinBaseAddress address) =>
      listUnspentByScriptHash(scriptHashForAddress(address));

  Future<List<ElectrumHistoryItem>> getHistory(String scriptHash) async {
    final res = await _request('blockchain.scripthash.get_history', [scriptHash]);
    final list = (res as List?) ?? const [];
    return list.map((e) {
      final m = e as Map;
      return ElectrumHistoryItem(
        txHash: m['tx_hash'] as String,
        height: (m['height'] as int?) ?? 0,
      );
    }).toList();
  }

  Future<String> getTransaction(String txHash) async {
    final res = await _request('blockchain.transaction.get', [txHash, false]);
    return res as String;
  }

  Future<int> getBlockHeaderTime(int height) async {
    // `blockchain.block.header` returns the 80-byte header hex; bytes 68..72 are
    // the little-endian timestamp.
    final res = await _request('blockchain.block.header', [height]);
    final headerHex = res as String;
    final bytes = hex.decode(headerHex);
    if (bytes.length < 72) return 0;
    return bytes[68] |
        (bytes[69] << 8) |
        (bytes[70] << 16) |
        (bytes[71] << 24);
  }

  Future<String> broadcast(String txHex) async {
    final res = await _request('blockchain.transaction.broadcast', [txHex]);
    return res as String;
  }

  void close() {
    _failAll('electrum: closed by client');
  }
}
