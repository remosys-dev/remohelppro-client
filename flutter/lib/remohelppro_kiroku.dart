// お客様のPCに残す「接続記録」（2026-09-01 ご指示）。
//
// 🔴🔴 なぜ要るか
//   常駐は**無人のPC**に入る。お客様は「いつ・誰が・何をしたか」を見ていない。
//   ⚠ 後から確かめる手段が**記録しかない**。
//
//   ⚠ 当社のコンソールの記録は**当社が持っているもの**。
//     お客様のPCの記録は**当社に消せないもの**。
//     ＝ 信頼の重みがまったく違う。無人PCに常駐させる商品は、
//       「見られていないこと」を証明できて初めて売れる。
//
// 🔴 技術用の記録（rl-trace.log）とは**別**にする。
//   あちらは英語・技術用語で、⚠ **お客様には読めない。**
//   ここは日本語で、⚠ **お客様が読むためだけ**に書く。
//
// 🔴 文字化けを起こさない（2026-09-01 ご心配。同じ日に2回はまっている）
//   ・UTF-8 **BOM付き** … BOM が無いとメモ帳が cp932 と誤解して化ける
//   ・改行は **CRLF**   … LF だけだとメモ帳で1行に潰れる
//   ・1行ずつ開いて追記して閉じる … 複数のプロセスが同時に書いても混ざらない
//   ・★書いた直後に読み返して確かめる … 化けていたら記録に残す
//   ⚠ 書けなくても**黙って諦める**。サポートは止めない。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_hbb/models/platform_model.dart';
import 'remohelppro_trace.dart' show rlTrace;

/// BOM（UTF-8）。⚠ これが無いとメモ帳で化ける。
const List<int> _kBom = [0xEF, 0xBB, 0xBF];

/// 置き場所。⚠ **誰でも開ける共有の場所**に置く。
/// ⚠ 利用者ごとの場所に置くと、SYSTEM で動く一時サービスから見えない
///   （同じ間違いを 2026-09-01 に復帰の合言葉でやっている）。
File? _file() {
  try {
    String base = '';
    try {
      base = bind.mainGetCommonSync(key: 'rl-shared-dir').trim();
    } catch (_) {}
    if (base.isEmpty) {
      final pub = Platform.environment['PUBLIC'] ?? r'C:\Users\Public';
      base = '$pub\Documents\REMOHELP PRO';
    }
    final d = Directory(base);
    if (!d.existsSync()) d.createSync(recursive: true);
    return File('${d.path}\接続記録.txt');
  } catch (_) {
    return null;
  }
}

String _stamp() {
  final n = DateTime.now();
  String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
  return '${n.year}-${p(n.month)}-${p(n.day)} ${p(n.hour)}:${p(n.minute)}:${p(n.second)}';
}

/// 1行 足す。⚠ **消さない・上書きしない。**
void rlKiroku(String line) {
  final f = _file();
  if (f == null) return;
  try {
    final text = '${_stamp()}  $line\r\n';
    final bytes = utf8.encode(text);
    if (!f.existsSync() || f.lengthSync() == 0) {
      // ⚠ 最初の1回だけ BOM と見出しを書く。
      f.writeAsBytesSync(
        [..._kBom, ...utf8.encode('【接続記録】このパソコンへの遠隔サポートの記録です\r\n\r\n')],
        mode: FileMode.write,
      );
    }
    f.writeAsBytesSync(bytes, mode: FileMode.append, flush: true);

    // ★書いた直後に読み返して確かめる（2026-09-01）。
    //   ⚠ 「確かめずに直したと言う」を今日ずっと繰り返している。
    //     ここは機械に確かめさせる。化けていれば記録に残して気づけるようにする。
    try {
      final back = f.readAsStringSync(encoding: utf8);
      if (!back.contains(line)) {
        rlTrace('kiroku_mismatch', {'line': line});
      }
    } catch (e) {
      rlTrace('kiroku_unreadable', {'e': e.toString()});
    }
  } catch (_) {
    // 書けなくてもサポートは止めない。
  }
}

/// 繋がったとき。
void rlKirokuConnected({String? staff, String? company}) {
  final who = [
    if (staff != null && staff.trim().isNotEmpty) '相談員：${staff.trim()}',
    if (company != null && company.trim().isNotEmpty) '（${company.trim()}）',
  ].join('');
  rlKiroku('接続しました   ${who.isEmpty ? '（担当者名なし）' : who}');
}

/// 切れたとき。
void rlKirokuDisconnected(Duration d) {
  final m = d.inMinutes;
  rlKiroku('切断しました   接続時間 ${m < 1 ? '1分未満' : '$m分'}');
}
