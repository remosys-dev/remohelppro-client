/// お客様のアプリに何が起きたかを、**必ず残す**ための記録。
///
/// 🔴 なぜ作ったか（2026-08-27・ご指示）
///
///   顧客アプリが接続の1〜4分後に消える、という最大の未解明があった。
///   ⚠ 原因が分からない本当の理由は「**失敗が誰にも見えない**」ことだった。
///     `remohelppro_pairing.dart` には `catch (_) {}`（黙って握りつぶす）が
///     30か所以上あり、止まった理由がどこにも残らない。
///   ⚠ 2026-08-01 の設計書が**最優先**としていた
///     「顧客アプリの動きをサーバーへ送る仕組み」は、26日経っても無かった。
///
///   ★ここを飛ばして先を直すと、また「直したつもり」になる。
///     まず見えるようにして、それから測る。
///
/// ## 二重に残す（どちらか片方が死んでも残る）
///
///   ① お客様のPCのファイル … `%LOCALAPPDATA%\REMOHELP PRO\trace\rl-trace.log`
///      ⚠ **同期で書く**。次の行が書けないまま落ちても、直前までは残る。
///        これが「消える」を追うための唯一の証拠になる。
///   ② 当社のサーバー … `POST /api/customer/trace`
///      お客様に「ファイルを送ってください」と頼まずに読める。
///      ⚠ 送れなくても①には残る。送信の失敗自体も①に書く。
///
/// ## 約束
///   - ⚠ **絶対に例外を投げない。** 記録の仕組みがアプリを壊してはならない
///   - ⚠ **絶対に待たせない。** 送信は裏で行う（呼び出し側は待たない）
///   - ⚠ 個人情報・合言葉・トークンは書かない（[_scrub] で落とす）
library;

import 'dart:async';
import 'remohelppro_endpoints.dart';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

// ⚠ 場所は remohelppro_endpoints.dart に集めた（2026-09-04）。
//   ⚠ ここに直書きしないこと。散らばると切り替え忘れが必ず出る。
const String _kApiBase = kRlApiBase;

/// 1行の最大の長さ。長い例外文でファイルを膨らませない。
const int _kMaxLineChars = 2000;

/// ためておける上限。サーバーへ送れない間に増え続けないようにする。
const int _kMaxQueued = 300;

/// 1回の送信で送る最大の件数（サーバー側も同じ数で切る）。
const int _kMaxBatch = 50;

/// 記録ファイルがこの大きさを超えたら、1世代だけ退避する。
const int _kMaxFileBytes = 4 * 1024 * 1024;

String _role = 'app';
String? _shortId;
String? _custToken;
File? _file;
bool _fileReady = false;
Timer? _flush;
final List<Map<String, Object?>> _queue = <Map<String, Object?>>[];
bool _sending = false;
DateTime? _startedAt;

/// このプロセスが何者かを名乗る（`main` / `cm` / `resident` など）。
///
/// ⚠ 1本のアプリは**プロセスを2つ以上持つ**（画面の窓＋接続の窓）。
///   どちらが書いた行かが分からないと、記録は読めない。
void rlTraceSetRole(String role) {
  _role = role.trim().isEmpty ? 'app' : role.trim();
}

/// このセッションの短いIDと顧客トークンを教える。
///
/// これを呼ぶまでの行は、ファイルには残るがサーバーへは送らない
/// （どのセッションの話か分からないため）。呼んだ時点で、
/// ためてあった分もまとめて送る。
void rlTraceBind({required String shortId, String? custToken}) {
  _shortId = shortId.trim().toUpperCase();
  _custToken = custToken;
  _kick();
}

/// 記録を1行残す。
///
/// [ev] は英数字の短い名前（`poll_stop` など）。画面に出す文ではないので
/// 日本語にしない（文字コードの問題を持ち込まない）。
void rlTrace(String ev, [Map<String, Object?>? data]) {
  try {
    _startedAt ??= DateTime.now();
    final now = DateTime.now();
    final rec = <String, Object?>{
      't': now.toIso8601String(),
      'ev': ev,
      'pid': pid,
      'role': _role,
      'up': now.difference(_startedAt!).inSeconds,
      if (data != null && data.isNotEmpty) 'd': _scrub(data),
    };
    _writeLine(rec);
    _enqueue(rec);
  } catch (_) {
    // ⚠ ここで投げない。記録が原因でアプリを止めない。
  }
}

/// いま溜まっている分を、待って送り切る（最大 [timeout]）。
///
/// 🔴 `exit(0)` の直前で呼ぶためのもの。
///   ⚠ 消える瞬間の1行こそが、いちばん知りたい行。
Future<void> rlTraceFlushNow(
    {Duration timeout = const Duration(seconds: 3)}) async {
  try {
    await _send().timeout(timeout);
  } catch (_) {
    // 送れなくてもファイルには残っている。
  }
}

// ─────────────────────────────────────────────────────────────
// ここから下は内部の処理
// ─────────────────────────────────────────────────────────────

/// 合言葉やトークンを記録に残さない。
///
/// ⚠ 記録は当社のサーバーへ送られる。お客様の合言葉が混ざれば、
///   それは我々が意図せず預かってしまうということ。名前で落とす。
Map<String, Object?> _scrub(Map<String, Object?> data) {
  const banned = <String>{
    'password',
    'passwd',
    'pw',
    'token',
    'custToken',
    'dlToken',
    'secret',
    'pin',
  };
  final out = <String, Object?>{};
  for (final e in data.entries) {
    final k = e.key;
    if (banned.contains(k) || banned.any((b) => k.toLowerCase().contains(b))) {
      out[k] = '(hidden)';
      continue;
    }
    final v = e.value;
    if (v == null || v is num || v is bool) {
      out[k] = v;
    } else {
      var s = v.toString();
      if (s.length > 300) s = '${s.substring(0, 300)}…';
      out[k] = s;
    }
  }
  return out;
}

Directory _dir() {
  if (Platform.isWindows) {
    final base =
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    return Directory('$base/REMOHELP PRO/trace');
  }
  if (Platform.isMacOS) {
    final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
    return Directory('$home/Library/Logs/REMOHELP PRO');
  }
  return Directory('${Directory.systemTemp.path}/REMOHELP PRO');
}

File? _ensureFile() {
  if (_fileReady) return _file;
  _fileReady = true;
  try {
    final d = _dir();
    if (!d.existsSync()) d.createSync(recursive: true);
    final f = File('${d.path}/rl-trace.log');
    // 大きくなりすぎたら1世代だけ退避する（消さない。過去の事故を追える）。
    try {
      if (f.existsSync() && f.lengthSync() > _kMaxFileBytes) {
        final old = File('${d.path}/rl-trace.1.log');
        if (old.existsSync()) old.deleteSync();
        f.renameSync(old.path);
      }
    } catch (_) {}
    _file = f;
  } catch (_) {
    _file = null;
  }
  return _file;
}

void _writeLine(Map<String, Object?> rec) {
  final f = _ensureFile();
  if (f == null) return;
  try {
    var line = jsonEncode(rec);
    if (line.length > _kMaxLineChars) {
      line = '${line.substring(0, _kMaxLineChars)}…';
    }
    // ⚠ **同期で書く**。落ちる瞬間の行を残すのが目的なので、ここは待つ。
    f.writeAsStringSync('$line\n',
        mode: FileMode.append, encoding: utf8, flush: true);
  } catch (_) {}
}

void _enqueue(Map<String, Object?> rec) {
  _queue.add(rec);
  if (_queue.length > _kMaxQueued) {
    // 古いものから捨てる。⚠ ただし「捨てた」ことも残す。
    final dropped = _queue.length - _kMaxQueued;
    _queue.removeRange(0, dropped);
    _writeLine(<String, Object?>{
      't': DateTime.now().toIso8601String(),
      'ev': 'trace_dropped',
      'pid': pid,
      'role': _role,
      'd': {'n': dropped},
    });
  }
  _kick();
}

void _kick() {
  if (_shortId == null) return;
  _flush ??= Timer.periodic(const Duration(seconds: 5), (_) {
    unawaited(_send());
  });
  if (_queue.length >= _kMaxBatch) unawaited(_send());
}

Future<void> _send() async {
  final sid = _shortId;
  if (sid == null || _queue.isEmpty || _sending) return;
  _sending = true;
  try {
    while (_queue.isNotEmpty) {
      final take = _queue.length > _kMaxBatch ? _kMaxBatch : _queue.length;
      final batch = _queue.sublist(0, take);
      final r = await http
          .post(
            Uri.parse('$_kApiBase/api/customer/trace'),
            headers: {
              'Content-Type': 'application/json',
              if (_custToken != null) 'x-customer-token': _custToken!,
            },
            body: jsonEncode({'shortId': sid, 'events': batch}),
          )
          .timeout(const Duration(seconds: 8));
      if (r.statusCode == 200) {
        _queue.removeRange(0, take);
      } else {
        // ⚠ 失敗の理由をファイルに残す。⚠ ここで再帰しないよう直接書く。
        _writeLine(<String, Object?>{
          't': DateTime.now().toIso8601String(),
          'ev': 'trace_send_failed',
          'pid': pid,
          'role': _role,
          'd': {'status': r.statusCode},
        });
        break; // 次のtickでやり直す（消さずに残す）
      }
    }
  } catch (e) {
    _writeLine(<String, Object?>{
      't': DateTime.now().toIso8601String(),
      'ev': 'trace_send_error',
      'pid': pid,
      'role': _role,
      'd': {'e': e.toString()},
    });
  } finally {
    _sending = false;
  }
}
