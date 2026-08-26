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

/// 一時サービスの**最後の歯止め**。ここまで来たら、何があっても消す。
///
/// 🔴 これは「サポートの制限時間」ではない（2026-08-03 に作り直した）。
///   当初は「作った時刻＋30分」を期限として渡していたが、一時サービスを作るのは
///   **再起動する前**なので、砂時計は再起動中も、戻ってきて相談員が作業して
///   いる間も進む。＝ **30分を超えるサポートは作業の途中で必ず切れていた。**
///   普段の終わり方は「サーバーがサポート終了と答えたら消える」で、
///   そちらは一時サービス側が20秒ごとに自分で確かめている。
///   ここに渡すのは、その道が全部塞がったときのための最後の歯止め。
const int kPrelogonHardLimitHours = 12;

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
    final hardLimit = (DateTime.now().millisecondsSinceEpoch ~/ 1000) +
        kPrelogonHardLimitHours * 3600;

    // 昇格して実行する。終了コードで結果を受け取る（0=成功 2=権限なし）。
    //   ⚠ お客様が UAC で「いいえ」を押すと Start-Process が例外を投げる。
    //     それは「権限が無い」と同じ扱いにする（相談員への伝え方が同じため）。
    final ps = "\$ErrorActionPreference='Stop';"
        "\$p=Start-Process -FilePath '${exe.replaceAll("'", "''")}'"
        " -ArgumentList '--rl-prelogon-install','${appDir.replaceAll("'", "''")}','$shortId','$hardLimit'"
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

/// 復帰できたときにサーバーから返るもの。
///
/// 🔴 onetimeToken だけでは足りない（2026-08-01 作り直し）。
///   短ID と顧客トークンが無いと、戻った後に
///   「終了の見張り」も「次の再起動の控え」も始められない。
///   実際、戻れても**相談員が終了してもお客様のPCが止まらず、
///   2回目の再起動にも戻れない**状態になっていた。
class ResumeResult {
  final String onetimeToken;
  final String shortId;
  final String? customerToken;
  const ResumeResult(this.onetimeToken, this.shortId, this.customerToken);
}

/// 復帰の合言葉を持っているか（＝再起動から戻ろうとしているか）。
///
/// 🔴 これを**接続番号を待つ前に**見る（2026-08-27）。
///   合言葉が無ければ復帰ではないので、待たずにすぐ入力画面へ。
///   合言葉があるなら、席を離れているお客様に代わって**粘る価値がある**。
/// ⚠ 置き場所は APP_DIR ではなく `%LOCALAPPDATA%`。
///   ワンタイム版は起動のたびに別の場所へ展開されるので、
///   APP_DIR に置くと再起動をまたげない。
bool hasResumeToken() {
  try {
    final f = _tokenFile();
    return f.existsSync() && f.readAsStringSync().trim().isNotEmpty;
  } catch (_) {
    return false;
  }
}

/// 起動時に呼ぶ。合言葉があれば同じセッションに戻る。
/// 戻れたら接続に必要な一式を返す。戻れなければ null。
Future<ResumeResult?> tryResume({
  required String apiBase,
  required String rustdeskId,
}) async {
  final f = _tokenFile();
  String token;
  try {
    if (!f.existsSync()) return null;
    token = f.readAsStringSync().trim();
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
    // 🔴 消すのは**サーバーの返事を受け取ってから**（2026-08-01 作り直し）。
    //
    //   元は「読んだ時点で消す」だった。1回きりを守るための判断だったが、
    //   **再起動の直後はネットワークがまだ上がっていない**ことが多い。
    //   そこで通信に失敗すると、合言葉は既に消えており、**二度と戻れない**。
    //   お客様は席を離れたまま、サポートは終わってしまう。
    //
    //   サーバーが返事をくれた時点で消す（200 でも 403 でも1回きりは保たれる）。
    //   返事が無い＝通信できていないので、残して次の起動でもう一度試す。
    //   ⚠ 残した場合も、サーバー側の期限（30分）で必ず無効になる。
    //     手元に残ることが「いつまでも戻れる」を意味しないのが要点。
    try {
      f.deleteSync();
    } catch (_) {}
    if (r.statusCode != 200) return null;
    final j = jsonDecode(r.body) as Map;
    final ot = j['onetimeToken'] as String?;
    final sid = j['shortId'] as String?;
    if (ot == null || ot.isEmpty || sid == null || sid.isEmpty) return null;
    return ResumeResult(ot, sid, j['customerToken'] as String?);
  } catch (_) {
    // 通信できなかった。合言葉は残す（次の起動でもう一度試せる）。
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

    // 🔴🔴 RunOnce から**直接プログラムを呼ばない**（2026-08-02 実機で確定）。
    //
    //   実機で起きたこと:
    //     ・登録は正しく作られていた（パスも中身も確認済み）
    //     ・再起動後、Windows は登録を**消した**（＝処理はした）
    //     ・しかしプログラムは**一度も動かなかった**（記録も展開もゼロ）
    //     ・同じパスを手で実行すると、警告も出ずに普通に起動した
    //   ＝ パスは正しい。**ログインした瞬間に呼ばれても起動しきれない**。
    //
    //   ★RunOnce は1回しか呼ばれず、失敗しても何も残らない。
    //     ログイン直後は、ネットワークも周辺の部品もまだ揃っていない。
    //     そこへ30MBの自己展開プログラムを直接ぶつけるのが無理筋だった。
    //
    //   間に**小さな命令書**を挟む:
    //     ① 20秒待つ（準備が整うのを待つ）
    //     ② 起動する
    //     ③ 動き出したか確かめる。だめならもう2回試す（20秒おき）
    //     ④ 試したことを必ず記録に残す
    //   ⚠ ④が肝心。今回いちばん困ったのは「失敗したのか、試してすら
    //     いないのか」が分からなかったこと。次からは記録を見れば分かる。
    // ⚠ 区切りを ¥ にそろえる。混ざっていても起動できることは確かめたが、
    //   バッチの中では素直な形にしておく（読む人が迷わない）。
    //   🔴 パスの組み立てで `\\r` `\\n` を作らないこと（2026-08-02 検証で発見）。
    //     `'$base\\rl-resume.log'` と書くと `\r` が**復帰コード**として解釈され、
    //     `resumel-resume.log` という壊れたパスになる。実際に一度そう書いていた。
    //     区切りは r'\' を足す形にして、文字として確実に扱う。
    final sep = r'\';
    final base = dir.path.replaceAll('/', sep);
    final cmdPath = base + sep + 'rl-resume.cmd';
    final logPath = base + sep + 'rl-resume.log';
    final exePath = dst.path.replaceAll('/', sep);
    //   🔴 `for` の中にまとめて書かないこと（2026-08-02 検証で発見）。
    //     `for /L ... do ( ... )` の中は**丸ごと先に読まれる**ため、
    //     `%date%` も `errorlevel` も**ループに入る前の値で固定**される。
    //     実際に試したところ、3回とも同じ秒に走り、一度も起動しなかった。
    //     （`setlocal enabledelayedexpansion` と `!` を使う手もあるが、
    //      ここは3回だけなので、素直に3回並べる方が読み違えようがない）
    //   ⚠ 待つのは20秒。ログイン直後は、まだ回線も周辺の部品も揃っていない。
    //     直接呼んで失敗したのが今回の原因なので、ここは急がない。
    //   ⚠ 記録は**英字で書く**（2026-08-02 検証で決めた）。
    //     日本語を入れるには chcp 65001 が要るが、それを入れると
    //     `find` の判定が壊れる（文字コードが噛み合わない）。
    //     この記録は我々が原因を追うためのものなので、
    //     文字コードの問題を持ち込む価値が無い。
    //   ⚠ `find` は**フルパスで呼ぶ**。PATH に別の find があると
    //     そちらが呼ばれて、判定が常に「見つからない」になる。
    //     （実際、検証中に他の find が呼ばれて誤判定した）
    const findExe = r'%SystemRoot%\System32\find.exe';

    // 🔴🔴 探す名前を決め打ちにしない（2026-08-08 実機で確定）。
    //
    //   ここは `remohelppro.exe` を探していた。ところがお客様用のアプリは
    //   **`remohelppro-support.exe`** という別の名前で配っている
    //   （常駐の taskkill に巻き込まれないよう名前を分けた）。
    //   ＝ 探しても**絶対に見つからない** → 毎回「起動していない」と判定 →
    //     20秒おきに3回とも起動する。
    //
    //   実機で見つかった状態（お客様PC・再起動後）:
    //     remohelppro-resume  ×3   ← この命令書が3回起こした
    //     remohelppro-support ×4   ← 各 resume が展開して起動した
    //   RustDesk 系は1台に1つの接続番号しか持てないので、**4本が奪い合って
    //   どれも中継サーバーに登録できない**。画面には「接続できません」としか出ない。
    //   常駐まで巻き添えで繋がらなくなり、8/4 から追っていた
    //   「再起動すると繋がらない／サービスを手で再起動すると直る」の正体だった。
    //
    //   ★名前から機能を推測しない。**いま自分が動いている実行ファイルの名前**を
    //     そのまま使う。名前を変えても、ここが追随する。
    //   ⚠ 控え（remohelppro-resume.exe）も一緒に見る。前の復帰がまだ動いて
    //     いるなら、重ねて起こしてはいけない。
    final myExe = Platform.resolvedExecutable.split(sep).last;
    final resumeName = dst.path.replaceAll('/', sep).split(sep).last;
    final watchNames = <String>{myExe, resumeName, 'remohelppro.exe'}
        .where((n) => n.isNotEmpty)
        .toList();

    // どれか1つでも動いていれば「起動済み」。
    String runningCheck(String label) => watchNames
        .map((n) => [
              'tasklist /FI "IMAGENAME eq $n" | $findExe /I "$n" >nul',
              'if not errorlevel 1 goto :$label',
            ].join('\r\n'))
        .join('\r\n');

    String tryOnce(String n) => [
          'ping -n 21 127.0.0.1 >nul',
          runningCheck('running'),
          'echo [%date% %time%] try $n >> "$logPath"',
          'start "" "$exePath"',
        ].join('\r\n');

    final cmd = [
      '@echo off',
      'echo [%date% %time%] START >> "$logPath"',
      tryOnce('1'),
      tryOnce('2'),
      tryOnce('3'),
      'ping -n 11 127.0.0.1 >nul',
      // 最後の見届け。どれか動いていれば OK、1つも無ければ FAILED。
      //   ⚠ 記録に**探した名前を残す**。今回のように「探す名前が違っていた」
      //     ときは、これが無いと FAILED の理由に一生辿り着けない。
      'echo [%date% %time%] watching ${watchNames.join(" ")} >> "$logPath"',
      runningCheck('ok'),
      'echo [%date% %time%] FAILED >> "$logPath"',
      'goto :end',
      ':ok',
      'echo [%date% %time%] OK >> "$logPath"',
      'goto :end',
      ':running',
      'echo [%date% %time%] ALREADY-RUNNING >> "$logPath"',
      ':end',
      // 🔴🔴 登録を**自分で消してから**、命令書を消す（2026-08-25 実機で修正）。
      //
      //   ⚠ これまでは命令書だけが自分を消し、RunOnce の登録は Windows 任せだった。
      //     2つがずれると「登録はあるのに中身が無い」状態になり、
      //     お客様の画面に **『rl-resume.cmd が見つかりません』** が出ていた。
      //     しかも復帰そのものも起きない（起こす人が居なくなるため）。
      //   ★消す順番は「登録 → 中身」。逆にすると、消し損ねたときに
      //     また同じ組み合わせ（登録あり・中身なし）ができる。
      'reg delete "$_kResumeRunKey" /v $_kResumeRunName /f >nul 2>nul',
      // 命令書は残さない。お客様のPCに当社のファイルを残さない。
      //   ⚠ 記録（.log）は残す。うまくいかなかったときに、
      //     試したかどうかを確かめられるようにするため。
      //     サポートが終わるときに clearRebootResume が消す。
      'del /f /q "$cmdPath" >nul 2>nul',
      '',
    ].join('\r\n');
    File(cmdPath).writeAsStringSync(cmd);

    // RunOnce にはこの命令書を登録する。
    //   ⚠ cmd を窓なしで走らせるため /c と start を使う。
    await Process.run('reg', [
      'add', _kResumeRunKey,
      '/v', _kResumeRunName,
      '/t', 'REG_SZ',
      // 🔴 **中身が無ければ何もしない**（2026-08-25 実機で修正）。
      //   ⚠ `if exist` が無いと、命令書が消えているときに
      //     Windows が『見つかりません』の窓をお客様に見せる。
      //     こちらの後始末の失敗を、お客様のエラーとして出してはいけない。
      '/d', 'cmd /c if exist "$cmdPath" start "" /min "$cmdPath"',
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
  // 🔴 合言葉のファイルも消す（2026-08-01 追加）。
  //   これを消していなかったため、サポートが終わった後も
  //   %LOCALAPPDATA%\REMOHELP PRO\reconnect.token が残り、
  //   **次に起動したとき古い合言葉で復帰を試みて 403 になっていた**。
  //   実害は「毎回1回だけ無駄な要求が飛ぶ」ことだが、記録が
  //   403 だらけになり、本当の失敗が埋もれて原因を追えなくなる。
  //   ⚠ Windows 以外でも消す（下の RunOnce の処理より前に置く）。
  try {
    final f = _tokenFile();
    if (f.existsSync()) f.deleteSync();
  } catch (_) {}
  if (!Platform.isWindows) return;
  try {
    await Process.run('reg', ['delete', _kResumeRunKey, '/v', _kResumeRunName, '/f']);
  } catch (_) {}
  // ⚠ 命令書と、その記録も消す（2026-08-02 追加）。
  //   消し忘れると、お客様のPCに当社のファイルが残る。
  //   「使い終わったら消える」という約束はここまで含む。
  try {
    final d = _resumeDir().path.replaceAll('/', r'\');
    for (final n in ['rl-resume.cmd', 'rl-resume.log']) {
      final f = File('$d\\$n');
      if (f.existsSync()) f.deleteSync();
    }
  } catch (_) {}
  try {
    final f = _resumeExe();
    if (f.existsSync()) f.deleteSync();
  } catch (_) {}
}
