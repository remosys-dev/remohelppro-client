import 'dart:async';
import 'dart:convert';
// Process / ProcessStartMode は Mac の自己削除で使う（自分を消す後始末を切り離して走らせる）。
import 'dart:io' show Platform, File, Directory, exit, Process, ProcessStartMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/common.dart' show gFFI;
import 'remohelppro_livekit.dart';
import 'rl_support.dart' show kRlSupportShowWindow;
import 'remohelppro_netinfo.dart' show sendNetworkInfo;
import 'remohelppro_resident.dart' show RemohelpproResidentCard;
import 'remohelppro_reconnect.dart'
    show
        armReboot,
        tryResume,
        prepareRebootResume,
        clearRebootResume,
        preparePrelogonResume,
        PrelogonResult;

const String _kApiBase = 'https://svr.remohelppro.jp';

/// 相談員が居なくなってアプリが自分を終了する直前に、server_model から呼ばれる。
///
/// 🔴 サーバーへ「終わった」と伝えるためだけの受け口（2026-07-30 追加）。
///   これが無いと、お客様のアプリが消えたあとも当社の画面は「接続中」と出続け、
///   相談員は繋がると思って繋がらない。**画面が嘘をつく**状態だった。
///   server_model は shortId も顧客トークンも知らないので、
///   知っているこちら側に処理を預ける形にする。
Future<void> Function()? rlNotifySupportEnded;

const String _kSlug = 'remohelppro';

/// 常駐を一時停止したときに置く「戻す予定」の名前。
///
/// 🔴 止めたら**必ず戻る**ようにするための仕掛け（2026-08-05）。
///   止めた事実をアプリのメモリだけに置くと、アプリが消えた瞬間に
///   誰も戻せなくなる。Windows 自身に予定を持たせて、外の誰かを当てにしない。
const String _kResumeTask = 'REMOHELPPRO_RESUME';

// REMOHELP PRO ブランド配色（ブルー系）。ここを変えれば一括で色が変わる。
const Color _accent = Color(0xFF2563EB);
const Color _accentDeep = Color(0xFF1E40AF);
const Color _accentSoft = Color(0xFFEAF1FD);
const Color _accentLine = Color(0xFFC7D7FE);
const Color _ink = Color(0xFF1F2937);
const Color _muted = Color(0xFF6B7280);
const Color _faint = Color(0xFF9CA3AF);
const Color _line = Color(0xFFE5E7EB);
const Color _danger = Color(0xFFDC2626);

/// REMOHELP PRO: 認証コードで遠隔操作を開始する（被操作側ペアリング）。
///   コード入力 → /api/customer/verify-pin で shortId → 自分の RustDesk ID
///   → /api/remote/grant-control で onetimeToken → それを自分のパスワードに設定
///   → 担当者が ID＋token で接続してくる。
class RemohelpproPairingCard extends StatefulWidget {
  const RemohelpproPairingCard({Key? key}) : super(key: key);
  @override
  State<RemohelpproPairingCard> createState() => _RemohelpproPairingCardState();
}

class _RemohelpproPairingCardState extends State<RemohelpproPairingCard> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  bool _busy = false;
  String? _error;
  bool _ready = false;
  String? _custToken; // 顧客セッショントークン（verify-pin で受領・以降のAPIに x-customer-token で添付）

  // ステータスパネル用（接続済み表示）
  String _enteredCode = ''; // 表示用の接続コード（手入力時）
  DateTime? _connectedAt; // 接続確立時刻（接続時間の起点）
  Timer? _clock; // 接続時間を1秒ごとに更新

  // R2: 相談員の終了を検知して被操作を自動停止するためのポーリング
  String? _shortId;
  Timer? _statusPoll;
  Timer? _rearm; // 再起動の合言葉を取り直す
  bool _terminated = false;
  /// ログオン前の再接続の用意が走っている最中か（二重起動を防ぐ）。
  bool _prelogonBusy = false;
  /// 常駐が入っているせいで繋がらない状態か（逃げ道のボタンを出すため）。
  bool _residentBlocking = false;
  /// 常駐を一時停止する処理の最中か。
  bool _pausing = false;
  /// このサポートのために常駐を止めたか（終わるときに戻す）。
  bool _residentPaused = false;
  /// 直前に「操作を許可した」状態だったか。view_only へ戻ったことを検知するために持つ。
  bool _wasFullControl = false;

  bool get _codeReady => _ctrl.text.replaceAll(RegExp(r'\D'), '').length == 6;

  String get _hostName {
    try {
      return Platform.localHostname;
    } catch (_) {
      return 'この PC';
    }
  }

  String _elapsed() {
    final a = _connectedAt;
    if (a == null) return '00:00:00';
    final d = DateTime.now().difference(a);
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (mounted) setState(() {});
    });
    // 相談員が居なくなってアプリが自分を終了する直前に、
    //   サーバーへ「終わった」と伝えるための受け口を預ける。
    rlNotifySupportEnded = _notifySupportEndedToServer;
    // 🔴 起動したら、まず前回の一時パスワードを無効にする（2026-07-29）。
    //
    //   設定は %LOCALAPPDATA% の**固定の場所**に残る。実行のたびに消えない。
    //   お客様がサポートの途中で窓を閉じるなど、終了処理を通らずに落ちると、
    //   前回の一時パスワードが**そのまま残る**。
    //   次に起動した瞬間、認証コードを入れる前から、その番号を知っている人が
    //   繋げてしまう。
    //
    //   顧客ページには「接続には毎回、担当者からお伝えする認証コードが必要です」
    //   と書いている。ここを塞がないと、その約束が嘘になる。
    //
    //   特に「継続用（消えない版）」は手元に残り続けるので影響が大きい。
    //   ワンタイム版も、自己削除を取りこぼしたときの保険になる。
    //   ⚠ 必ず自動接続より**先に**終わらせること。同時に走らせると、
    //     復帰や自動接続が設定した**正しいパスワードを消してしまう**。
    _bootSequence();
  }

  /// 起動時の順番を守る。無効化 → 自動接続。
  Future<void> _bootSequence() async {
    await _invalidateLeftoverPassword();
    if (!mounted) return;
    // ワンクリック接続：ランチャーが渡した合言葉があれば、手入力を飛ばして自動接続する。
    await _maybeAutoStart();
  }

  /// 前回の一時パスワードを使えなくする。失敗しても起動は妨げない。
  Future<void> _invalidateLeftoverPassword() async {
    if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) return;
    try {
      final rnd = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      await bind.mainSetPermanentPasswordWithResult(password: 'boot-$rnd');
    } catch (_) {
      // 設定を書けない環境でも、この後の認証コード入力は妨げない。
    }
  }

  /// ワンクリック接続の入口。
  ///   ランチャー(remohelppro-customer-lite.exe)が %TEMP%\remohelppro-pair.dlt に置いた
  ///   DLトークンを読み、あれば pair-init で shortId＋顧客トークンを取得して、6桁手入力を
  ///   スキップしてそのまま自動でペアリングする。トークンが無い／失効していれば、静かに
  ///   従来どおりの手入力カードを表示する（＝壊さない）。
  Future<void> _maybeAutoStart() async {
    if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) return;

    // 🔴 再起動からの復帰を最初に試す（2026-07-27）。
    //   サポート中に再起動を求める場面は多く、お客様が席を離れていると
    //   認証コードを入れ直せず**続きができない**。合言葉があれば
    //   お客様の操作なしで同じサポートに戻る。
    if (await _tryResumeAfterReboot()) return;

    final dlToken = await _readAndConsumeDlToken();
    if (dlToken == null || dlToken.isEmpty) return;
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // pair-init：DLトークン → shortId＋顧客トークン（＝verify-pin の置き換え）。
      final pr = await http.post(
        Uri.parse('$_kApiBase/api/customer/pair-init'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'dlToken': dlToken}),
      );
      if (pr.statusCode != 200) {
        // 使用済み(410)／失効(410)／不正 → 手入力にフォールバック（静かに）。
        if (mounted) setState(() { _busy = false; });
        return;
      }
      final j = jsonDecode(pr.body) as Map;
      final shortId = j['shortId'] as String;
      _custToken = j['customerToken'] as String?;
      await _finishRemotePairing(shortId);
    } catch (_) {
      // 通信失敗等 → 手入力にフォールバック。
      if (mounted) setState(() { _busy = false; });
    }
  }

  /// 再起動からの復帰。戻れたら true。
  ///   合言葉が無い・期限切れ・通信不能なら false を返し、
  ///   従来どおり「認証コードを入力してください」に落ちる（＝壊さない）。
  Future<bool> _tryResumeAfterReboot() async {
    try {
      // 被操作サービスを起動して当社サーバーへ登録し、自分のIDを得る。
      await _startServiceAndWaitRegistered();
      final myId = await _waitForMyId();
      if (myId == null) return false;

      final res = await tryResume(apiBase: _kApiBase, rustdeskId: myId);
      if (res == null) return false;

      // 新しいワンタイムトークンを自分のパスワードにする。
      await bind.mainSetPermanentPasswordWithResult(password: res.onetimeToken);
      if (!mounted) return true;
      _shortId = res.shortId;
      if (res.customerToken != null && res.customerToken!.isNotEmpty) {
        _custToken = res.customerToken;
      }
      _connectedAt = DateTime.now();
      _clock?.cancel();
      _clock = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
      setState(() {
        _ready = true;
        _busy = false;
      });

      // 🔴🔴 戻った後の「続きの準備」を必ずやり直す（2026-08-01 作り直し）。
      //
      //   ここまでは合言葉を入れ直すだけで終わっていた。その結果:
      //     ・終了の見張りが動かない
      //       → 相談員が終了しても**お客様のPCが止まらない**。
      //         接続できる状態のまま残り、自己削除も走らない
      //     ・次の控えを作らない
      //       → **2回目の再起動には戻れない**
      //     ・RunOnce を登録し直さない
      //       → Windows は一度実行すると登録を自分で消すので、
      //         次の再起動で**何も起動しない**
      //
      //   ＝ 復帰は「1回だけ、しかも後始末なし」でしか成り立っていなかった。
      //   通常の接続（_finishRemotePairing）と同じ準備をここでも行う。
      _startStatusPoll(res.shortId);
      unawaited(armReboot(
          apiBase: _kApiBase, shortId: res.shortId, custToken: _custToken));
      unawaited(prepareRebootResume());
      _rearm?.cancel();
      // ⚠ 通常の接続と同じく、終了後は叩かない（2026-08-01 検証で指摘）。
      //   これが無いと、サポートが終わってもアプリ終了まで10分ごとに
      //   控えを取り直そうとし続ける。
      _rearm = Timer.periodic(const Duration(minutes: 10), (_) {
        if (!_terminated) {
          unawaited(armReboot(
              apiBase: _kApiBase, shortId: res.shortId, custToken: _custToken));
        }
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 合言葉（DLトークン）を受け取る。
  ///
  /// 🔴 2026-07-29: これまではサイドカーファイルだけを見ていたが、
  ///   そのファイルを置くはずだった軽量ランチャーは**一度も作られなかった**。
  ///   つまりワンクリック接続は一度も動いておらず、お客様は毎回
  ///   ページとアプリで**2回**認証コードを入れていた。
  ///   今は自己展開ランチャーが、自分のファイル名から読み取った合言葉を
  ///   環境変数で渡してくる。そちらを先に見る。
  ///
  /// 見つからなければ null を返し、従来どおり認証コード入力画面を出す。
  Future<String?> _readAndConsumeDlToken() async {
    // ① 起動元（自己展開ランチャー）から渡された合言葉。
    try {
      final env = (Platform.environment['RL_PAIR_DL_TOKEN'] ?? '').trim();
      // サーバー側が単回消費するので、ここで消す必要はない。
      if (env.isNotEmpty) return env;
    } catch (_) {/* 環境変数が読めない環境でも②へ進む */}

    // ② 旧方式（サイドカーファイル）。将来の別経路のために残す。
    try {
      final f = File('${Directory.systemTemp.path}/remohelppro-pair.dlt');
      if (!await f.exists()) return null;
      final s = (await f.readAsString()).trim();
      try {
        await f.delete();
      } catch (_) {/* 削除失敗でもサーバ側で単回消費されるので安全 */}
      return s.isEmpty ? null : s;
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    rlNotifySupportEnded = null;
    _statusPoll?.cancel();
    _statusPoll = null;
    _rearm?.cancel();
    _rearm = null;
    _clock?.cancel();
    _clock = null;
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  /// 相談員が終了した（active=false）を検知したときの後始末。
  ///   接続切断 → 被操作サービス停止 → 一時パスワード無効化（ワンタイム再利用防止）。
  Future<void> _terminateBySupportEnd() async {
    if (_terminated) return;
    _terminated = true;
    _statusPoll?.cancel();
    _statusPoll = null;
    // ⚠ 控えの取り直しも止める（2026-08-01 検証で指摘）。
    //   止めていなかったため、終了後もアプリが生きている間は
    //   10分ごとにサーバーを叩き続けていた。
    _rearm?.cancel();
    _rearm = null;
    _clock?.cancel();
    _clock = null;
    try {
      await bind.mainCloseAllConnections();
    } catch (_) {}
    try {
      await bind.mainStopService();
    } catch (_) {}
    // 再起動復帰の控えと自動起動の登録を消す。
    //   🔴 残すと、次にPCを起動したときに勝手にアプリが立ち上がる。
    //     お客様は「勝手に動いた」と受け取る。
    try {
      await clearRebootResume();
    } catch (_) {}
    // サポートのために常駐を止めていたら、元に戻す。
    //   ⚠ 戻せなくても、次にパソコンを起動すれば自動で戻る。
    try {
      await _resumeResidentIfPaused();
    } catch (_) {}
    // 一時パスワードをランダム化して無効化（同じIDへ再接続できないように）
    try {
      final rnd = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      await bind.mainSetPermanentPasswordWithResult(password: 'end-$rnd');
    } catch (_) {}
    if (mounted) setState(() {});
    // 穴B対策: ワンタイム版は終了後にプロセスを確実に終了させ、ランナーの自己削除(穴C)を発火させる。
    //   接続前に顧客が終了した場合(_hasEverConnected=false)は server_model の自動終了が働かないため、
    //   ここで保険をかける。「終了しました」を読む数秒を残してから exit(0)。
    if (kRlSupportShowWindow) {
      // Mac は自己展開ランナーが無いので、アプリが自分で後始末する。
      await _selfDeleteMacApp();
      // 🔴 4秒 → 20秒（2026-08-02 実機指摘）。
      //   「サポートを終了しました」を出しているのに、4秒で消えるため
      //   **お客様が読む前に画面ごと無くなっていた**。
      //   ご高齢のお客様は、画面が変わったことに気づくまでに時間がかかる。
      //   終わったことが伝わらないと「まだ繋がっているのでは」と不安が残る。
      //   ⚠ 接続はこの時点で既に切れており、待っている間に何かできる状態ではない。
      //     待つのは**読んでいただくため**だけなので、危険は増えない。
      Future.delayed(const Duration(seconds: 20), () => exit(0));
    }
  }

  /// Mac のワンタイム版が、使い終わったあと自分を消す。
  ///
  /// Windows は自己展開ランナーが本体ごと消してくれるが、Mac は .dmg を開いて
  /// アプリを取り出す方式なので、**残ったアプリを誰も片付けない**。
  /// 「1回のサポートで1回だけ使う」を Mac でも成り立たせる。
  ///
  /// 🔴 消す対象を厳しく絞る。パスの取り違えで人のファイルを消すことだけは
  ///   絶対に避ける。少しでも当てはまらなければ**何もしない**。
  Future<void> _selfDeleteMacApp() async {
    if (!Platform.isMacOS) return;
    try {
      final exe = Platform.resolvedExecutable; // .../REMOHELP PRO.app/Contents/MacOS/xxx
      final marker = exe.indexOf('.app/');
      if (marker < 0) return;
      final appPath = exe.substring(0, marker + 4);
      if (!appPath.endsWith('.app')) return;
      // DMG から直接動かしている場合は読み取り専用。消す物が無いので触らない。
      if (appPath.startsWith('/Volumes/')) return;
      // OS の領域は絶対に触らない。
      if (appPath.startsWith('/System') || appPath.startsWith('/usr') ||
          appPath.startsWith('/bin') || appPath.startsWith('/sbin')) return;
      // 自分のアプリであることを名前でも確かめる。
      if (!appPath.contains('REMOHELP PRO')) return;

      // 自分が終わってから消す。
      //   🔴 パスを文字列に埋め込まない。アプリ名に空白（REMOHELP PRO）が入るうえ、
      //     引用符の付け方を間違えると **rm -rf の対象がずれる**。
      //     引数として渡し、シェルには $1 で受け取らせれば引用は要らない。
      await Process.start(
        '/bin/sh',
        ['-c', 'sleep 4; rm -rf "\$1"', 'sh', appPath],
        mode: ProcessStartMode.detached,
      );
    } catch (_) {
      // 消せなくても終了は妨げない。残っても、認証コードが無ければ何もできない。
    }
  }

  /// 相談員の終了を検知するポーリング（被操作が繋がったままにならないように）。
  void _startStatusPoll(String shortId) {
    _statusPoll?.cancel();
    _statusPoll = Timer.periodic(const Duration(seconds: 4), (_) async {
      try {
        final r = await http.get(
          Uri.parse('$_kApiBase/api/customer/session-status?shortId=$shortId'),
        );
        if (r.statusCode == 200) {
          final j = jsonDecode(r.body) as Map;
          if (j['active'] == false) {
            await _terminateBySupportEnd();
            return;
          }
          // 🔴 操作の取り消しに気づく（2026-07-29）。
          //   これまでは status（終了したか）しか見ていなかったため、
          //   相談員が「操作を終了」を押しても**接続はそのまま操作できていた**。
          //   ＝ 記録は「操作は終わった」なのに実態が伴わない。
          //   お客様に「操作をやめました」と伝えた後も動かせる状態は、
          //   この製品で最もあってはならない。
          //
          //   繋ぎ直してもらう（画面共有として入り直す）。黙って続けるより、
          //   一度切れる方がお客様にも相談員にも分かりやすい。
          final mode = j['mode'] as String?;
          if (mode == 'view_only' && _wasFullControl) {
            _wasFullControl = false;
            try {
              await bind.mainCloseAllConnections();
            } catch (_) {}
          } else if (mode == 'full_control') {
            _wasFullControl = true;
          }
          // 🔴 ログオン前の再接続の指示（2026-08-01 ユーザー指示）。
          //   相談員が「再起動して続ける」を押すと、ここに立つ。
          //   ⚠ 1回の指示に対して1回だけ実行する。二重に走らせると
          //     お客様の画面に管理者の確認が何度も出る。
          if (j['prelogon'] == true && !_prelogonBusy) {
            _prelogonBusy = true;
            unawaited(_runPrelogon(shortId));
          }
        }
      } catch (_) {
        /* 一時的な通信エラーは無視（次のtickで再確認） */
      }
    });
  }

  /// ログオン前の再接続を用意し、結果をサーバーへ返す。
  ///
  /// 🔴 結果を必ず返すこと。黙って失敗すると、相談員は用意できたと信じて
  ///   再起動を促し、**戻ってこないPCを待ち続ける**ことになる。
  Future<void> _runPrelogon(String shortId) async {
    PrelogonResult r;
    try {
      r = await preparePrelogonResume(shortId);
    } catch (_) {
      r = PrelogonResult.failed;
    }
    final name = r == PrelogonResult.ok
        ? 'ok'
        : (r == PrelogonResult.noAdmin ? 'noAdmin' : 'failed');
    try {
      await http.post(
        Uri.parse('$_kApiBase/api/customer/prelogon-result'),
        headers: {
          'Content-Type': 'application/json',
          if (_custToken != null) 'x-customer-token': _custToken!,
        },
        body: jsonEncode({'shortId': shortId, 'result': name}),
      );
    } catch (_) {
      // 返せなくても、相談員側は「返事が無い」ことで気づける（画面に出す）。
    }
    _prelogonBusy = false;
  }

  /// 相談員が居なくなり、アプリが自分を終了する直前の後始末。
  ///
  /// 🔴 サーバーへ終了を伝え、再起動復帰の控えも消す（2026-07-30 追加）。
  ///   伝えないと当社の画面は「接続中」のまま残り、相談員は繋がると
  ///   思って繋がらない。控えを残すと次の起動で勝手にアプリが立ち上がる。
  ///   ⚠ ここは終了の直前なので、時間をかけないこと（数秒で切る）。
  Future<void> _notifySupportEndedToServer() async {
    final sid = _shortId;
    if (sid != null) {
      try {
        await http
            .post(
              Uri.parse('$_kApiBase/api/customer/session-end'),
              headers: {
                'Content-Type': 'application/json',
                if (_custToken != null) 'x-customer-token': _custToken!,
              },
              body: jsonEncode({'shortId': sid}),
            )
            .timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    try {
      await clearRebootResume();
    } catch (_) {}
  }

  /// 顧客が自分で「終了する」を押したとき。
  ///   セッションを ended にし（相談員ダッシュボードにも伝わる）、被操作を停止・
  ///   一時パスワードを無効化する（＝以降は誰も操作できない）。
  Future<void> _endByCustomer() async {
    final sid = _shortId;
    if (sid != null) {
      try {
        await http.post(
          Uri.parse('$_kApiBase/api/customer/session-end'),
          headers: {
            'Content-Type': 'application/json',
            if (_custToken != null) 'x-customer-token': _custToken!,
          },
          body: jsonEncode({'shortId': sid}),
        );
      } catch (_) {/* 通信失敗でもローカル停止は行う */}
    }
    await _terminateBySupportEnd();
  }

  /// 常駐を一時停止してから、もう一度つなぎ直す。
  ///
  /// 🔴 ここは「今すぐサポートを受けられるようにする」ための逃げ道。
  ///   常駐が入っているPCでは、ワンタイム版が自分の接続を登録できず必ず失敗する。
  ///   常駐が承認前だと常駐からも繋げないので、**どこからも繋げない**状態になる。
  ///
  /// ⚠ サービスを**止めるだけ**にする。自動起動の設定は触らない。
  ///   触ると「戻し忘れ」で常駐が二度と動かなくなる。
  ///   止めるだけなら、次にパソコンを起動したときに自動で戻る＝最悪でも自己修復する。
  /// ⚠ 管理者の確認（UAC）は Windows の仕組みなので避けられない。
  ///   押していただけなければ、何も変えずに元の案内へ戻す。
  Future<void> _pauseResidentAndRetry() async {
    if (!Platform.isWindows) return;
    setState(() {
      _pausing = true;
      _error = null;
    });
    try {
      // 🔴🔴 止めたら、**必ず戻る仕掛けも同時に置く**（2026-08-05 検証の指摘）。
      //
      //   これまでは「止めた」という事実がこのアプリのメモリにしか無かった。
      //   アプリが強制終了・電源断・通信断で終わると、
      //   **それを知っている唯一の相手が消える**＝ 常駐は止まったまま、
      //   誰も戻さない。「次にパソコンを起動すれば戻る」と書いていたが、
      //   常駐の対象は**つけっぱなしのPC**なので、次の再起動がいつ来るか
      //   分からない。実質「気づかれないまま止まり続ける」。
      //
      //   ★外の誰か（このアプリ）を当てにしない。
      //     Windows 自身に「1時間ごとに開始する」予定を持たせる。
      //     普通に終われば下で予定を消す。消せなくても最大1時間で戻る。
      //   ⚠ 既に動いているサービスに開始をかけても害は無い（何も起きない）。
      //   ⚠ 管理者の確認は1回で済ませる。止めるのと予定を置くのを1回にまとめる。
      const cmd = 'sc stop remohelppro'
          ' & schtasks /create /tn $_kResumeTask'
          ' /sc minute /mo 60'
          ' /tr "sc.exe start remohelppro"'
          ' /ru SYSTEM /rl HIGHEST /f';
      final ps = "\$ErrorActionPreference='Stop';"
          "\$p=Start-Process -FilePath 'cmd.exe'"
          " -ArgumentList '/c','$cmd'"
          " -Verb RunAs -Wait -PassThru;"
          "exit \$p.ExitCode";
      final r = await Process.run(
          'powershell', ['-NoProfile', '-NonInteractive', '-Command', ps]);
      // sc stop は「既に止まっている」でも 0 以外を返すことがある。
      // 成否は次の登録確認で判断する（止まっていれば通る）。
      debugPrint('RL pause resident: exit=${r.exitCode}');
      _residentPaused = true;
    } catch (e) {
      debugPrint('RL pause resident failed: $e');
      if (mounted) {
        setState(() {
          _pausing = false;
          _error = '一時停止できませんでした。\n'
              '管理者の確認で「はい」を押していただく必要があります。';
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _pausing = false;
      _residentBlocking = false;
    });
    // 入力済みの認証コードがあれば、そのまま繋ぎ直す。
    if (_codeReady) {
      await _connect();
    }
  }

  /// 一時停止した常駐を元に戻す。サポートが終わるときに呼ぶ。
  ///
  /// ⚠ ここが呼ばれなくても戻る。止めるときに Windows へ
  ///   「1時間ごとに開始する」予定を置いてあるので、最大1時間で自動的に戻る。
  ///   ここは「すぐ戻して、予定を片付ける」ための道。
  /// ⚠ お客様に管理者の確認をもう一度出さないよう、静かに試すだけにする。
  ///   断られても、上の予定が効くので困らない。
  Future<void> _resumeResidentIfPaused() async {
    if (!_residentPaused || !Platform.isWindows) return;
    _residentPaused = false;
    try {
      const cmd = 'sc start remohelppro'
          ' & schtasks /delete /tn $_kResumeTask /f';
      const ps = "\$p=Start-Process -FilePath 'cmd.exe'"
          " -ArgumentList '/c','$cmd'"
          " -Verb RunAs -Wait -PassThru; exit \$p.ExitCode";
      await Process.run(
          'powershell', ['-NoProfile', '-NonInteractive', '-Command', ps]);
    } catch (e) {
      debugPrint('RL resume resident failed: $e');
    }
  }

  Future<void> _connect() async {
    final pin = _ctrl.text.replaceAll(RegExp(r'\D'), '');
    if (pin.length != 6) {
      setState(() => _error = '6桁の認証コードを入力してください');
      return;
    }
    _enteredCode = pin;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // 1) PIN → shortId
      final vr = await http.post(
        Uri.parse('$_kApiBase/api/customer/verify-pin'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'slug': _kSlug, 'pin': pin}),
      );
      if (vr.statusCode != 200) {
        throw Exception('認証コードが違うか、有効期限が切れています');
      }
      final vjson = jsonDecode(vr.body) as Map;
      final shortId = vjson['shortId'] as String;
      final mode = (vjson['mode'] as String?) ?? 'view_only';
      // 顧客セッショントークンを保存（以降の grant-control / session-end に添付する）。
      _custToken = vjson['customerToken'] as String?;

      // モード分岐：閲覧(カメラ／画面共有)は LiveKit、操作(遠隔操作)は RustDesk。
      //   camera=カメラ配信 / view_only=画面共有 → どちらも LiveKit（操作員はブラウザ/opで視聴）。
      //   pending_control=遠隔操作 → RustDesk（grant-control で操作許可）。
      //   ※ 画面共有(view_only)で grant-control を呼ぶと mode不一致で 409 になるため、
      //     操作員側(op)の LivekitViewer 視聴と揃えて LiveKit 経路にする。
      // 🔴 PC で画面共有(view_only)のコードを入れたら、アプリで画面共有まで通す（2026-07-26）。
      //   それまでは「このコードはブラウザでご利用ください」と突き返していた。
      //   お客様は**すでにアプリを起動している**のに、そこからブラウザを開いて
      //   同じ番号を入れ直せ、という案内になっていた。電話で誘導する相談員の手間が倍になる。
      //   アプリを入れた人ほど不便になるのは筋が通らない。
      //
      //   ⚠ 画面共有は「見せるだけ」の約束なので、操作系を**顧客側で全部切ってから**
      //     繋ぐ。RustDesk の権限は被操作側（＝お客様のPC）が判定するので、
      //     相談員側の画面を制限するのではなく、**実際に操作できない**状態になる。
      //     ここを緩めると、画面共有と言って操作できてしまう＝同意違反になる。
      if (mode == 'view_only' &&
          (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
        for (final k in const [
          'enable-keyboard',
          'enable-clipboard',
          'enable-file-transfer',
          'enable-file-copy-paste',
          'enable-terminal',
          'enable-tunnel',
          'enable-remote-printer',
        ]) {
          await bind.mainSetOption(key: k, value: 'N');
        }
        await _finishRemotePairing(shortId, viewOnly: true);
        return;
      }

      if (mode == 'camera' || mode == 'view_only') {
        // カメラはブラウザ（PC版アプリはカメラ配信を持たない）。
        if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
          throw Exception(
              'このコードは「ブラウザ」でご利用ください。\n'
              'ブラウザで svr.remohelppro.jp を開き、同じ認証コードを入力してください。\n'
              '（カメラはアプリ不要でご利用いただけます）');
        }
        final isCamera = mode == 'camera';
        if (!mounted) return;
        setState(() => _busy = false);
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => RemohelpproLiveKitScreen(
              shortId: shortId, camera: isCamera, custToken: _custToken),
        ));
        return;
      }

      // 2)〜4) 自分のID取得 → grant-control → 一時PW設定 → 待機（自動接続と共通）。
      await _finishRemotePairing(shortId);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// shortId 確定後の共通処理（手入力・自動接続の両方から呼ぶ）。
  ///   自分のRustDesk ID取得（リレー登録待ちのリトライ付き）→ grant-control で
  ///   onetimeToken → それを一時パスワードに設定 → 準備完了表示＋終了監視を開始。
  Future<void> _finishRemotePairing(String shortId,
      {bool viewOnly = false}) async {
    // 🔴 遠隔操作のときは、操作系を必ず戻してから繋ぐ（2026-07-26）。
    //   直前に同じPCで画面共有を使っていると 'N' が残ったままで、
    //   相談員が繋いでもキーボードもマウスも効かない。原因が見えないので厄介。
    //   画面共有側で切っているのだから、遠隔操作側で戻すのが対。
    if (!viewOnly) {
      for (final k in const [
        'enable-keyboard',
        'enable-clipboard',
        'enable-file-transfer',
        'enable-file-copy-paste',
        'enable-terminal',
        'enable-tunnel',
        'enable-remote-printer',
      ]) {
        await bind.mainSetOption(key: k, value: 'Y');
      }
    }

    // ★build-27 最重要修正：ここで被操作サービスを起動する。
    //   これが無いと端末は当社サーバー(hbbs)へ一度も登録されない。
    //   それでも mainGetMyId() は「ローカル生成のID」を返してしまうため、
    //   アプリは「準備完了」と表示するのに相談員側は必ず
    //   「IDが存在しません」になっていた（実測: hbbsのpeerテーブルに該当ID 0件）。
    await _startServiceAndWaitRegistered();

    // 自分の RustDesk ID（登録済みの9桁）。起動直後は空のことがあるので少し待つ。
    final myId = await _waitForMyId();
    if (myId == null) {
      throw Exception('接続の準備中です。数秒後にもう一度お試しください');
    }

    // grant-control → onetimeToken
    final gr = await http.post(
      Uri.parse('$_kApiBase/api/remote/grant-control'),
      headers: {
        'Content-Type': 'application/json',
        if (_custToken != null) 'x-customer-token': _custToken!,
      },
      body: jsonEncode({
        'shortId': shortId,
        'rustdeskId': myId,
        // 画面共有なら「見るだけ」であることをサーバーにも伝える。
        // 相談員の画面に「操作はできません」と出すのに使う。
        if (viewOnly) 'viewOnly': true,
      }),
    );
    if (gr.statusCode != 200) {
      throw Exception('接続の準備に失敗しました（${gr.statusCode}）');
    }
    final token = (jsonDecode(gr.body) as Map)['onetimeToken'] as String;

    // token を自分のパスワードに設定（担当者が ID＋token で接続）
    await bind.mainSetPermanentPasswordWithResult(password: token);

    if (!mounted) return;
    _shortId = shortId;
    _connectedAt = DateTime.now();
    _clock?.cancel();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    setState(() {
      _ready = true;
      _busy = false;
    });
    // R2: 相談員が終了したら自動で被操作を止めるための監視を開始
    _startStatusPoll(shortId);

    // 端末のネットワーク情報を送る（プリンタ等の IP 調査に使う）。
    //   🔴 await しない。取得に数秒かかることがあり、待たせると
    //     「準備完了」の表示が遅れてお客様が不安になる。
    //   🔴 失敗しても接続は続く（sendNetworkInfo は例外を投げない）。
    // 🔴 再起動に備えて、**接続できた時点で**復帰の合言葉を用意しておく。
    //   相談員からの再起動指示を待つ作りにすると、Windows Update や
    //   お客様自身の操作による再起動を拾えない。実際の現場では、
    //   ソフトの導入後に勝手に再起動がかかる場面もある。
    //   合言葉は1回きり・30分で失効するので、先に持っていても危険は増えない。
    unawaited(armReboot(
        apiBase: _kApiBase, shortId: shortId, custToken: _custToken));
    // 🔴 合言葉だけでは戻れない。再起動後に**自分を起動し直す**控えも要る。
    //   これが無いまま合言葉だけ用意していたため、再起動後の自動再接続は
    //   一度も成立していなかった（2026-07-30 実機指摘）。
    unawaited(prepareRebootResume());
    // 長いサポートで失効しないよう、10分ごとに取り直す。
    _rearm?.cancel();
    _rearm = Timer.periodic(const Duration(minutes: 10), (_) {
      if (!_terminated) {
        unawaited(armReboot(
            apiBase: _kApiBase, shortId: shortId, custToken: _custToken));
      }
    });

    unawaited(sendNetworkInfo(
      apiBase: _kApiBase,
      shortId: shortId,
      customerToken: _custToken,
    ));
  }

  /// 被操作サービスを起動し、当社サーバーへの「登録完了」まで待つ。
  ///   status_num: 1=登録済み（相談員から見つけられる）/ 0=接続中 / -1=未接続。
  ///   登録できていないまま「準備完了」を出すと相談員側が「IDが存在しません」に
  ///   なるため、ここで必ず実際の登録状態を確認してから先へ進む。
  Future<void> _startServiceAndWaitRegistered() async {
    final sm = gFFI.serverModel;
    // Android だけが「ユーザー操作でサービスを開始する」仕様（＝今回の不具合の元）。
    //   PC版は起動時に自動で登録済みなので、ここで触ると余計な
    //   プラットフォーム呼び出しになるため何もしない（登録確認だけ行う）。
    if (Platform.isAndroid && !sm.isStart) {
      // Android 13+ は通知許可が無いと前景サービスを開始できない（＝登録も走らない）。
      await sm.checkRequestNotificationPermission();
      // 画面キャプチャの同意ダイアログはこの中でOSが表示する。
      await sm.startService();
    }
    for (var i = 0; i < 30; i++) {
      try {
        final st =
            jsonDecode(await bind.mainGetConnectStatus()) as Map<String, dynamic>;
        if ((st['status_num'] as int) == 1) return; // 登録完了
      } catch (_) {
        /* 起動直後は取得できないことがあるのでリトライ */
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
    // 🔴 「通信のせい」と決めつけない（2026-08-04 実機で判明）。
    //
    //   このPCに REMOHELP PRO が**インストールされている**と、
    //   そちらのサービスが先に登録の口を押さえるため、
    //   一時的なこのアプリは登録できず、必ずここで止まる。
    //   ところが今までは「Wi-Fi をご確認ください」としか出ず、
    //   **お客様も相談員も通信の問題だと誤解した**。
    //   しかもアンインストールしてもサービスは動いたまま残るので、
    //   **再起動するまで直らない**。原因が見えないと永久に分からない。
    //
    //   ⚠ 判定は「入っているか」だけ。常駐版か相談員版かまでは分からないので、
    //     断定せず、確かめる手順の形で伝える。
    bool installed = false;
    try {
      installed = bind.mainIsInstalled(); // 同期で返る
    } catch (_) {
      /* 判定できなければ、下の一般的な案内にする */
    }
    if (installed) {
      // 🔴 行き止まりにしない（2026-08-05 ご指示）。
      //   「常駐が入っているせいで繋がりません」で終わらせると、
      //   **お客様は今この瞬間サポートを受けられない**。
      //   常駐が半端に入って登録もできていない状態だと、常駐からも繋げず、
      //   逃げ道が「アンインストールして再起動」しか無くなる。
      //   電話口のお客様にそれを頼むのは無理がある。
      //   → その場で常駐を一時停止して繋げるようにする（下のボタン）。
      if (mounted) setState(() => _residentBlocking = true);
      throw Exception('このパソコンには REMOHELP PRO の常駐版が入っています。\n'
          'その常駐版が動いている間は、この方法では接続できません。\n\n'
          '下の「常駐を一時停止して接続する」を押すと、そのまま繋げます。');
    }
    throw Exception('サーバーに接続できませんでした。\n'
        'Wi-Fi／モバイル通信の状態を確認して、もう一度お試しください。');
  }

  /// リレー登録が済んで自分のIDが得られるまで、少し待ちながらリトライする。
  ///   （手入力ではユーザーが入力する間に登録が済んでいたが、自動接続では起動直後に
  ///     呼ぶため、空IDのことがある。）
  Future<String?> _waitForMyId() async {
    for (var i = 0; i < 20; i++) {
      final myId = await bind.mainGetMyId();
      if (myId.isNotEmpty && myId != '-') return myId;
      await Future.delayed(const Duration(milliseconds: 800));
    }
    return null;
  }

  // ───────────────────────── UI（ブルー系） ─────────────────────────

  /// デスクトップ・ダイアログ風の外枠（白カード＋ヘアライン罫＋やわらかい影）。
  Widget _shell({required Widget child}) {
    return Center(
      child: Container(
        // 🔴 幅を広げた（2026-08-05 ご指摘）。
        //   392px では、案内の文が短い行で何度も折り返して読みにくかった。
        //   特に常駐が入っているときの案内は行数が多く、意味の切れ目と
        //   関係ない所で折れる。お客様は電話をしながらこれを読む。
        //   ⚠ 窓が狭いときは窓に合わせる（はみ出して読めなくなる方が悪い）。
        width: 520,
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width - 32,
        ),
        margin: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE3E6EA)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.14),
              blurRadius: 30,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // タイトルバー
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: const BoxDecoration(
                color: Color(0xFFF6F7F9),
                border: Border(bottom: BorderSide(color: _line)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: _accent,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: const Icon(Icons.screen_share_outlined,
                        size: 12, color: Colors.white),
                  ),
                  const SizedBox(width: 9),
                  const Expanded(
                    child: Text('REMOHELP PRO ― リモートサポート',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF374151))),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
              child: child,
            ),
          ],
        ),
      ),
    );
  }

  /// 6マス（3−3）認証コード入力。透明の TextField で入力を受け、上に6マスを描画。
  Widget _codeBoxes() {
    final text = _ctrl.text.replaceAll(RegExp(r'\D'), '');
    Widget cell(int i) {
      final has = i < text.length;
      final isCur = i == text.length && _focus.hasFocus;
      return Container(
        width: 44,
        height: 56,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isCur ? _accent : const Color(0xFFD3D8DF),
            width: isCur ? 2 : 1.5,
          ),
          boxShadow: isCur
              ? [
                  BoxShadow(
                      color: _accent.withOpacity(0.14),
                      blurRadius: 0,
                      spreadRadius: 3),
                ]
              : null,
        ),
        child: Text(has ? text[i] : '',
            style: const TextStyle(
                fontSize: 26, fontWeight: FontWeight.bold, color: _ink)),
      );
    }

    const gap = SizedBox(width: 8);
    return GestureDetector(
      onTap: () => _focus.requestFocus(),
      behavior: HitTestBehavior.opaque,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              cell(0), gap, cell(1), gap, cell(2),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: Text('–',
                    style: TextStyle(
                        fontSize: 22,
                        color: Color(0xFFCBD2DB),
                        fontWeight: FontWeight.bold)),
              ),
              cell(3), gap, cell(4), gap, cell(5),
            ],
          ),
          // 入力を受ける透明フィールド（見えないが focus とキー入力を担う）
          Positioned.fill(
            child: Opacity(
              opacity: 0.0,
              child: TextField(
                controller: _ctrl,
                focusNode: _focus,
                autofocus: true,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                maxLength: 6,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) {
                  if (_codeReady && !_busy) _connect();
                },
                decoration: const InputDecoration(
                    counterText: '', border: InputBorder.none),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pill(String label, IconData icon) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
      decoration: BoxDecoration(
        color: _accentSoft,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        children: [
          Icon(icon, size: 17, color: _accent),
          const SizedBox(width: 8),
          Text(label,
              style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: _accentDeep)),
        ],
      ),
    );
  }

  Widget _primaryButton(String label, VoidCallback? onTap,
      {IconData? trailing}) {
    final enabled = onTap != null;
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: enabled ? _accent : const Color(0xFFE6E8EC),
          foregroundColor: enabled ? Colors.white : const Color(0xFFAAB0B9),
          elevation: 0,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(label,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            if (trailing != null) ...[
              const SizedBox(width: 6),
              Icon(trailing, size: 18),
            ],
          ],
        ),
      ),
    );
  }

  Widget _outlineButton(String label, IconData icon, VoidCallback onTap,
      {Color color = _ink, Color border = _line}) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          side: BorderSide(color: border, width: 1.5),
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        icon: Icon(icon, size: 18),
        label: Text(label,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      ),
    );
  }

  Widget _infoRow(IconData icon, String k, String v, {bool top = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        border: top ? null : const Border(top: BorderSide(color: Color(0xFFEEF1F4))),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: _faint),
          const SizedBox(width: 10),
          Expanded(
              child: Text(k,
                  style: const TextStyle(fontSize: 13.5, color: _muted))),
          Text(v,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.bold, color: _ink)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // ── 接続中（ワンクリック自動 or 手入力後） ──
    if (_busy && !_ready && !_terminated) {
      return _shell(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 6),
            const SizedBox(
              width: 56,
              height: 56,
              child: CircularProgressIndicator(strokeWidth: 5, color: _accent),
            ),
            const SizedBox(height: 18),
            const Text('接続しています',
                style: TextStyle(
                    fontSize: 19, fontWeight: FontWeight.bold, color: _ink)),
            if (_enteredCode.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('コード ${_enteredCode.substring(0, 3)} – ${_enteredCode.substring(3)}',
                  style: const TextStyle(fontSize: 13, color: _muted)),
            ],
            const SizedBox(height: 10),
            const Text('担当者につないでいます。少しお待ちください。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13.5, color: _muted)),
            const SizedBox(height: 8),
          ],
        ),
      );
    }

    // ── 終了 ──
    if (_terminated) {
      return _shell(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle, color: _accent, size: 50),
            const SizedBox(height: 8),
            const Text('サポートを終了しました',
                style: TextStyle(
                    fontSize: 20, fontWeight: FontWeight.bold, color: _ink)),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _accentSoft,
                border: Border.all(color: _accentLine),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Icon(Icons.lock_outline, size: 20, color: _accent),
                  SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('もう誰もあなたのパソコンに入れません',
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: _accentDeep)),
                        SizedBox(height: 3),
                        Text('このアプリと接続用ファイルは自動で消えました。',
                            style: TextStyle(
                                fontSize: 12.5, color: Color(0xFF3A4D78))),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            const Text('この画面は閉じて大丈夫です。',
                style: TextStyle(fontSize: 13, color: _muted)),
          ],
        ),
      );
    }

    // ── 接続済み（ステータスパネル：接続コード／このPC／接続時間＋終了） ──
    if (_ready) {
      return _shell(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.screen_share_outlined, color: _accent, size: 50),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 6),
              decoration: BoxDecoration(
                color: _accent,
                borderRadius: BorderRadius.circular(7),
              ),
              child: const Text('接続済み',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.white)),
            ),
            const SizedBox(height: 16),
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFFF6F7F9),
                border: Border.all(color: _line),
                borderRadius: BorderRadius.circular(9),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  _infoRow(Icons.vpn_key_outlined, '接続コード',
                      _enteredCode.isEmpty ? '—' : _enteredCode,
                      top: true),
                  _infoRow(Icons.desktop_windows_outlined, 'このPC', _hostName),
                  _infoRow(Icons.schedule, '接続時間', _elapsed()),
                ],
              ),
            ),
            // 🔴 常駐化の許可はここに出す（2026-07-27 実機で判明）。
            //   これまでブラウザの顧客ページにしか実装しておらず、
            //   アプリで接続しているお客様には**何も出ていなかった**。
            //   ＝ 相談員が「常駐にする」を押しても常駐にできなかった。
            //   遠隔操作は常にアプリ経由なので、実運用ではこちらが本流。
            if (_shortId != null)
              RemohelpproResidentCard(
                  apiBase: _kApiBase, shortId: _shortId!, custToken: _custToken),
            const SizedBox(height: 16),
            _outlineButton('終了する', Icons.stop_circle_outlined, _endByCustomer,
                color: _danger, border: const Color(0xFFF3C9C9)),
            const SizedBox(height: 8),
            const Text('押すと接続を切り、それ以降は誰も操作できません',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, color: _faint)),
          ],
        ),
      );
    }

    // ── 認証コード入力（ブルー系） ──
    return _shell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _pill('接続コードを入力', Icons.vpn_key_outlined),
          const SizedBox(height: 14),
          const Text('リモートサポートに接続',
              style: TextStyle(
                  fontSize: 22, fontWeight: FontWeight.bold, color: _ink)),
          const SizedBox(height: 6),
          const Text('担当者から案内された6桁の接続コードを入力すると\n画面共有が開始されます。',
              style: TextStyle(fontSize: 13, color: _muted, height: 1.5)),
          const SizedBox(height: 18),
          _codeBoxes(),
          const SizedBox(height: 8),
          Center(
            child: Text(
              _error ?? '担当者から受け取ったコードを入力してください。',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12.5,
                  color: _error != null ? _danger : _faint),
            ),
          ),
          // 常駐が邪魔をしているときだけ出す逃げ道。普段は出さない。
          if (_residentBlocking) ...[
            const SizedBox(height: 12),
            _outlineButton(
              _pausing ? '一時停止しています…' : '常駐を一時停止して接続する',
              Icons.pause_circle_outline,
              // 押している最中は何もしない（二重に走らせない）。
              _pausing ? () {} : _pauseResidentAndRetry,
              color: _accentDeep,
              border: _accentLine,
            ),
            const SizedBox(height: 6),
            const Text(
              '管理者の確認が一度出ます。\n'
              '常駐は次にパソコンを起動したときに自動で戻ります。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, color: _muted, height: 1.5),
            ),
          ],
          const SizedBox(height: 14),
          _primaryButton(
            '接続する',
            (_codeReady && !_busy) ? _connect : null,
            trailing: Icons.arrow_forward,
          ),
        ],
      ),
    );
  }
}
