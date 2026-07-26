// 顧客端末のネットワーク情報を集めて、当社サーバーへ送る。
//
// 用途（2026-07-26 ユーザー確定）:
//   サポート中に**プリンタや機器の IP を調べる**ため。
//   これまでは netnum のようなソフトを別途入れて調べていた。
//   相談員のビュアーに出せば、その手間が要らなくなる。
//
// 🔴 **能動的なネットワークスキャンはしない**。
//   遠隔サポートツールが勝手に LAN を探索すると、お客様のセキュリティソフトや
//   社内監視に検知され、説明を求められる。信用に関わる。
//   ARP テーブルは「端末が既にやり取りした相手」の記録で、読むだけでは
//   通信を発生させないので安全。ここを緩めてスキャンを足さないこと。
//
// 🔴 失敗しても絶対に例外を投げない。
//   ネットワーク情報はサポートの補助であって、本筋ではない。
//   ここで落ちると接続そのものが止まる。取れなければ黙って諦める。

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// コマンドを実行して標準出力を返す。失敗したら空文字。
Future<String> _run(String exe, List<String> args) async {
  try {
    final r = await Process.run(exe, args, runInShell: false)
        .timeout(const Duration(seconds: 8));
    return (r.stdout ?? '').toString();
  } catch (_) {
    return '';
  }
}

/// 既定の経路（＝今この通信が出ている口）のゲートウェイと NIC 名。
Future<Map<String, String>> _defaultRoute() async {
  if (Platform.isWindows) {
    // route print の "0.0.0.0" 行。3列目がゲートウェイ、4列目が自分のIP。
    final out = await _run('route', ['print', '-4']);
    for (final line in out.split('\n')) {
      final p = line.trim().split(RegExp(r'\s+'));
      if (p.length >= 4 && p[0] == '0.0.0.0' && p[1] == '0.0.0.0') {
        return {'gateway': p[2], 'ip': p[3]};
      }
    }
  } else if (Platform.isMacOS) {
    final out = await _run('route', ['-n', 'get', 'default']);
    String gw = '', iface = '';
    for (final line in out.split('\n')) {
      final t = line.trim();
      if (t.startsWith('gateway:')) gw = t.split(':').last.trim();
      if (t.startsWith('interface:')) iface = t.split(':').last.trim();
    }
    return {'gateway': gw, 'iface': iface};
  } else if (Platform.isLinux) {
    final out = await _run('ip', ['route', 'show', 'default']);
    final m = RegExp(r'default via (\S+) dev (\S+)').firstMatch(out);
    if (m != null) return {'gateway': m.group(1)!, 'iface': m.group(2)!};
  }
  return {};
}

/// DNS サーバー。
Future<List<String>> _dnsServers() async {
  final out = Platform.isWindows
      ? await _run('powershell', [
          '-NoProfile',
          '-Command',
          'Get-DnsClientServerAddress -AddressFamily IPv4 | '
              'Select-Object -ExpandProperty ServerAddresses'
        ])
      : Platform.isMacOS
          ? await _run('scutil', ['--dns'])
          : await _run('cat', ['/etc/resolv.conf']);

  final found = <String>{};
  for (final m in RegExp(r'\b(\d{1,3}(?:\.\d{1,3}){3})\b').allMatches(out)) {
    final ip = m.group(1)!;
    if (ip == '0.0.0.0' || ip.startsWith('127.')) continue;
    found.add(ip);
    if (found.length >= 6) break;
  }
  return found.toList();
}

/// ARP テーブル（近隣機器）。プリンタや NAS を探すのはこれ。
Future<List<Map<String, String?>>> _neighbors() async {
  final out = Platform.isLinux
      ? await _run('ip', ['neigh', 'show'])
      : await _run('arp', ['-a']);

  final list = <Map<String, String?>>[];
  final seen = <String>{};
  for (final line in out.split('\n')) {
    final ipM = RegExp(r'\b(\d{1,3}(?:\.\d{1,3}){3})\b').firstMatch(line);
    if (ipM == null) continue;
    final ip = ipM.group(1)!;
    // ブロードキャスト・マルチキャストは機器ではないので出さない（一覧が埋もれる）
    if (ip.endsWith('.255') || ip.startsWith('224.') || ip.startsWith('239.')) continue;
    if (!seen.add(ip)) continue;
    final macM =
        RegExp(r'\b([0-9a-fA-F]{2}([:-])[0-9a-fA-F]{2}(\2[0-9a-fA-F]{2}){4})\b')
            .firstMatch(line);
    list.add({'ip': ip, 'mac': macM?.group(1)});
    if (list.length >= 200) break;
  }
  return list;
}

/// 端末の全 NIC。
Future<List<Map<String, dynamic>>> _nics(String? defaultIp, String? defaultIface) async {
  final nics = <Map<String, dynamic>>[];
  try {
    final ifaces = await NetworkInterface.list(
      includeLoopback: false,
      includeLinkLocal: false,
      type: InternetAddressType.any,
    );
    for (final i in ifaces) {
      String? v4, v6;
      for (final a in i.addresses) {
        if (a.type == InternetAddressType.IPv4 && v4 == null) v4 = a.address;
        if (a.type == InternetAddressType.IPv6 && v6 == null) v6 = a.address;
      }
      if (v4 == null && v6 == null) continue;
      nics.add({
        'name': i.name,
        'ipv4': v4,
        'ipv6': v6,
        // 「今この通信が出ている口」を明示する。仮想/VPN が混ざると
        // どれで繋がっているのか相談員が判断できない。
        'isDefault': (defaultIp != null && v4 == defaultIp) ||
            (defaultIface != null && i.name == defaultIface),
      });
      if (nics.length >= 20) break;
    }
  } catch (_) {
    // 取れなければ空のまま返す
  }
  return nics;
}

/// 収集して送信する。失敗しても例外は投げない。
Future<void> sendNetworkInfo({
  required String apiBase,
  required String shortId,
  String? customerToken,
}) async {
  try {
    final route = await _defaultRoute();
    // 型がそれぞれ違うので Future.wait でまとめない（推論が効かずビルドが落ちる）。
    // 収集はいずれも数百ミリ秒なので、順番に取っても体感は変わらない。
    final nics = await _nics(route['ip'], route['iface']);
    final dns = await _dnsServers();
    final neighbors = await _neighbors();

    final body = <String, dynamic>{
      'shortId': shortId,
      'hostname': Platform.localHostname,
      'nics': nics,
      'gateway': route['gateway'],
      'dns': dns,
      'neighbors': neighbors,
      'collectedAt': DateTime.now().toIso8601String(),
    };

    await http
        .post(
          Uri.parse('$apiBase/api/customer/network-info'),
          headers: {
            'Content-Type': 'application/json',
            if (customerToken != null) 'x-customer-token': customerToken,
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 12));
  } catch (_) {
    // ネットワーク情報はサポートの補助。取れなくても接続は続ける。
  }
}
