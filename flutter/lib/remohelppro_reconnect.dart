// 再起動しても同じサポートに戻る仕組み（顧客側）。
//
// 経緯（2026-07-27 ユーザー指摘）:
//   サポート中に再起動を求める場面は多い。しかし再起動すると接続が切れ、
//   お客様が席を離れていると**続きができない**。認証コードを入れ直して
//   もらう必要があるが、誰もいなければそれもできない。
//
// 動き:
//   ① 再起動の直前に、サーバーへ「これから再起動します」と申告し、
//      復帰用の合言葉を受け取って手元に保存する
//   ② 再起動後、アプリが起動したら合言葉を探す
//   ③ あればサーバーへ渡し、同じセッションに繋ぎ直す
//      → **お客様の操作は一切いらない**
//
// 🔴 合言葉は1回きり・期限つき。使ったら消す。
//   残しておくと翌日でも同じ端末に繋がってしまう。お客様の同意は
//   「今のサポート」に対するものなので、そこを超えてはいけない。
//
// 🔴 失敗しても通常の起動を妨げない。
//   合言葉が読めない・期限切れ・通信不能なら、黙って普通の
//   「認証コードを入力してください」に戻る。

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// 合言葉を置く場所。再起動をまたぐので一時フォルダではなく
/// ユーザーのアプリデータに置く。
File _tokenFile() {
  final base = Platform.isWindows
      ? (Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path)
      : (Platform.environment['HOME'] ?? Directory.systemTemp.path);
  final dir = Directory('$base/REMOHELP PRO');
  if (!dir.existsSync()) {
    try {
      dir.createSync(recursive: true);
    } catch (_) {}
  }
  return File('${dir.path}/reconnect.token');
}

/// 再起動の直前に呼ぶ。復帰用の合言葉を取って保存する。
/// 失敗しても例外は投げない（再起動そのものは止めない）。
Future<void> armReboot({
  required String apiBase,
  required String shortId,
}) async {
  try {
    final r = await http
        .post(
          Uri.parse('$apiBase/api/customer/reconnect-arm'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'shortId': shortId}),
        )
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) return;
    final j = jsonDecode(r.body) as Map;
    final token = j['token'] as String?;
    if (token == null || token.isEmpty) return;
    _tokenFile().writeAsStringSync(token);
  } catch (_) {
    // 取れなければ従来どおり。再起動後に認証コードを入れ直してもらう。
  }
}

/// 起動時に呼ぶ。合言葉があれば同じセッションに戻る。
/// 戻れたら onetimeToken を返す。戻れなければ null。
Future<String?> tryResume({
  required String apiBase,
  required String rustdeskId,
}) async {
  final f = _tokenFile();
  String token;
  try {
    if (!f.existsSync()) return null;
    token = f.readAsStringSync().trim();
    // 🔴 読んだ時点で消す。成功しても失敗しても1回きり。
    //   残すと、次の起動でも復帰を試みてしまう。
    try {
      f.deleteSync();
    } catch (_) {}
  } catch (_) {
    return null;
  }
  if (token.isEmpty) return null;

  try {
    final r = await http
        .post(
          Uri.parse('$apiBase/api/customer/reconnect-resume'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'token': token, 'rustdeskId': rustdeskId}),
        )
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) return null;
    final j = jsonDecode(r.body) as Map;
    return j['onetimeToken'] as String?;
  } catch (_) {
    return null;
  }
}
