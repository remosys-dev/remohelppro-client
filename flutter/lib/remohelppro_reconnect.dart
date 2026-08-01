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

// ───────────────────────────────────────────────────────────────
// ログオン前の再接続（2026-08-01 ユーザー指示）。
//
// 上の仕組み（RunOnce）は **お客様がログオンしてからしか動かない**。
// 席を離れていればそこで止まる。ログオン画面から続けられるのは
// Windows サービスだけなので、再起動をまたぐときだけ一時的に作る。
//
// ⚠ 作れるのは管理者だけ。UAC（画面が暗くなる確認）は Windows の
//   仕組みなので回避できない。押していただけなければ従来のやり方に落とす。
// ⚠ 消すのは**サービス自身**（期限とサポート終了を自分で見る）。
//   ここから消しに行くと、そのたびに管理者の確認が出てしまう。

/// 一時サービスが自分を消すまでの時間。復帰の窓（サーバー側30分）と揃える。
const int kPrelogonMinutes = 30;

/// 結果。相談員にそのまま伝えられる粒度にする。
enum PrelogonResult { ok, noAdmin, failed }

/// ログオン前の再接続を用意する。
///
/// 戻り値をそのまま相談員に見せる想定なので、**曖昧な失敗を作らない**。
///   ok      … 用意できた。再起動してよい
///   noAdmin … 管理者権限が無い（お客様が「いいえ」を押した場合も含む）
///   failed  … それ以外（ウイルス対策ソフトに止められた等）
Future<PrelogonResult> preparePrelogonResume(String shortId) async {
  if (!Platform.isWindows) return PrelogonResult.failed;
  try {
    // 今動いているアプリ一式の場所。設定とIDもここにある（丸ごと複製する）。
    final appDir = Platform.environment['RL_APP_DIR'] ?? '';
    if (appDir.isEmpty) return PrelogonResult.failed;
    final exe = Platform.resolvedExecutable;
    final deadline = (DateTime.now().millisecondsSinceEpoch ~/ 1000) +
        kPrelogonMinutes * 60;

    // 昇格して実行する。終了コードで結果を受け取る（0=成功 2=権限なし）。
    //   ⚠ お客様が UAC で「いいえ」を押すと Start-Process が例外を投げる。
    //     それは「権限が無い」と同じ扱いにする（相談員への伝え方が同じため）。
    final ps = "\$ErrorActionPreference='Stop';"
        "\$p=Start-Process -FilePath '${exe.replaceAll("'", "''")}'"
        " -ArgumentList '--rl-prelogon-install','${appDir.replaceAll("'", "''")}','$shortId','$deadline'"
        " -Verb RunAs -Wait -PassThru;"
        "exit \$p.ExitCode";
    final r = await Process.run(
        'powershell', ['-NoProfile', '-NonInteractive', '-Command', ps]);
    if (r.exitCode == 0) return PrelogonResult.ok;
    if (r.exitCode == 2) return PrelogonResult.noAdmin;
    // Start-Process が投げた（＝「いいえ」を押された）場合もここに来る。
    final err = '${r.stderr}';
    if (err.contains('cancel') || err.contains('キャンセル') || err.contains('操作は')) {
      return PrelogonResult.noAdmin;
    }
    return PrelogonResult.failed;
  } catch (_) {
    return PrelogonResult.failed;
  }
}

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
  String? custToken,
}) async {
  try {
    final r = await http
        .post(
          Uri.parse('$apiBase/api/customer/reconnect-arm'),
          headers: {
            'Content-Type': 'application/json',
            // 🔴 本人であることを示す（2026-07-30 追加）。
            //   これが無いと、短IDを知っただけの第三者が復帰の合言葉を取得でき、
            //   相談員の接続先を自分の端末に差し替えられた。
            if (custToken != null && custToken.isNotEmpty)
              'x-customer-token': custToken,
          },
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

// ───────────────────────────────────────────────────────────────
// 再起動をまたいでサポートを続けるための「起動し直す仕掛け」。
//
// 🔴 これが無く、再起動後の自動再接続は成り立っていなかった（2026-07-30 実機指摘）。
//   合言葉を用意する仕組み（armReboot）と、それを使って復帰する仕組み（tryResume）は
//   出来ていたのに、**再起動後にアプリを起こす人が誰も居なかった**。
//   Windows は落としてきた1個のファイルを勝手に起動し直したりしない。
//
// やりかた:
//   ① 落としてきたファイルを、消えない場所に1つだけ控える
//      （元のファイルは使い終わりしだい消えるので、控えが要る）
//   ② RunOnce に登録する。Windows が**次の起動で1回だけ**実行して、
//      登録を自分で消す。「1回きり」という約束と形が合っている。
//   ③ サポートが終わったら、控えと登録を両方消す
//
// ⚠ **Windows はログインしてからでないと RunOnce を実行しない。**
//   パスワードが要るPCで、お客様が席を離れていると復帰できない。
//   これは仕組みの限界であり、無人での復帰が要るお客様には常駐版を使う。
//   （常駐版はサービスとして動くのでログイン前から繋がる）

const _kResumeRunKey =
    r'HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce';
const _kResumeRunName = 'REMOHELPPRO_RESUME';

Directory _resumeDir() {
  final base = Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
  return Directory('$base/REMOHELP PRO/resume');
}

File _resumeExe() => File('${_resumeDir().path}/remohelppro-resume.exe');

/// 接続できた時点で呼ぶ。再起動されても戻れるように控えを作る。
/// 失敗しても例外は投げない（サポートそのものは続ける）。
Future<void> prepareRebootResume() async {
  if (!Platform.isWindows) return;
  // ランナー（落としてきた1個のファイル）の場所。ワンタイム版のときだけ渡ってくる。
  final runner = Platform.environment['RL_RUNNER_EXE'] ?? '';
  if (runner.isEmpty) return;
  try {
    final src = File(runner);
    if (!src.existsSync()) return;
    final dir = _resumeDir();
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final dst = _resumeExe();
    // 既に同じ大きさの控えがあれば作り直さない（30MB弱の複製を毎回は避ける）。
    if (!dst.existsSync() || dst.lengthSync() != src.lengthSync()) {
      src.copySync(dst.path);
    }
    await Process.run('reg', [
      'add', _kResumeRunKey,
      '/v', _kResumeRunName,
      '/t', 'REG_SZ',
      '/d', '"${dst.path}"',
      '/f',
    ]);
  } catch (_) {
    // 控えが作れなければ、再起動後は認証コードの入れ直しになるだけ。
  }
}

/// サポートが終わったときに呼ぶ。控えと登録を残さない。
///
/// 🔴 残すと、次にPCを起動したときに勝手にアプリが立ち上がる。
///   お客様は「勝手に動いた」と受け取る。必ず消すこと。
Future<void> clearRebootResume() async {
  if (!Platform.isWindows) return;
  try {
    await Process.run('reg', ['delete', _kResumeRunKey, '/v', _kResumeRunName, '/f']);
  } catch (_) {}
  try {
    final f = _resumeExe();
    if (f.existsSync()) f.deleteSync();
  } catch (_) {}
}
