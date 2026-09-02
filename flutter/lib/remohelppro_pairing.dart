import 'dart:async';
import 'dart:convert';
// Process / ProcessStartMode は Mac の自己削除で使う（自分を消す後始末を切り離して走らせる）。
import 'dart:io' show Platform, File, Directory, exit, Process, ProcessStartMode;
import 'package:flutter/material.dart';
import 'remohelppro_mac_permission.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/common.dart' show gFFI;
import 'remohelppro_livekit.dart';
import 'rl_support.dart' show kRlSupportShowWindow;
import 'remohelppro_netinfo.dart' show sendNetworkInfo;
import 'remohelppro_trace.dart'
    show rlTrace, rlTraceBind, rlTraceSetRole, rlTraceFlushNow;
import 'remohelppro_resident.dart' show RemohelpproResidentCard;
import 'remohelppro_reconnect.dart'
    show
        armReboot,
        hasResumeToken,
        hasResumeTokenAnywhere,
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

/// 顧客が窓の「×」を押したときに、サポートを**本当に終わらせる**ための受け口。
///
/// 🔴🔴 「×」は窓を隠すだけだった（2026-08-27 ご指摘・重大）。
///
///   本体の作りでは、主窓の「×」は `windowManager.hide()` である
///   （desktop/widgets/tabbar_widget.dart の onWindowClose）。
///   ＝ ⚠ **お客様が閉じたつもりでも、アプリも被操作サービスも動いたままで、
///     一時パスワードも生きている。相談員はそのまま入れる。**
///   お客様には「閉じた」としか見えないので、入られていることに気づけない。
///   顧客ページに書いている「使い終わったら誰も入れません」という約束に反する。
///
///   ★「×」は終了と同じ扱いにする。サーバーへ終了を伝え、被操作を止め、
///     合言葉を潰してから窓を消す（＝以降は誰も入れない）。
///   ⚠ 確認は挟まない。挟むと、押し間違えたときに**開いたまま**が残る。
///     もう一度サポートを受けるには認証コードを入れ直すだけでよい。
Future<void> Function()? rlEndByCustomerOnClose;


/// 常駐を一時停止したときに置く「戻す予定」の名前。
///
/// 🔴 止めたら**必ず戻る**ようにするための仕掛け（2026-08-05）。
///   止めた事実をアプリのメモリだけに置くと、アプリが消えた瞬間に
///   誰も戻せなくなる。Windows 自身に予定を持たせて、外の誰かを当てにしない。
const String _kResumeTask = 'REMOHELPPRO_RESUME';

/// 常駐版のサービス名（＝ APP_NAME）。
///
/// 🔴 2つある（2026-08-07）。
///   常駐版は 1.4.29 から `remohelppro-agent` に名前を分けた。
///   ワンタイム版と同じ名前・同じフォルダ・同じ接続番号を奪い合っていたため。
///   ⚠ **分ける前に入った常駐は `remohelppro` のまま残る。**
///     新版を入れても旧版は消えない（消す対象の名前が違うので届かない）。
///     だから**両方**を見る必要がある。片方しか見ないと、
///     「入っているのに入っていないことになる」。
const List<String> _kResidentServices = ['remohelppro-agent', 'remohelppro'];

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

  // 🔴 お客様に「どこの誰につながっているか」を見せる（2026-08-29 ご指摘）。
  //
  //   ⚠ これまで画面には「接続済み」としか出ておらず、
  //     ⚠ **いまつながっている相手が、電話した相手と同じかどうかを
  //       確かめる方法が1つも無かった。**
  //   ★社名と**電話番号**を出す。
  //   ⚠ 効くのは電話番号のほう。社名は偽物にも真似できるので、
  //     それ自体は本物である証明にならない。番号があれば、
  //     お客様が**ご自分で調べた番号と照合**できる。
  //   ⚠ 番号が無い会社では、サーバーが null を返す（社名だけは出さない）。
  //     体験のお申し込みでは番号を聞いていないので、null は普通に起きる。
  String? _supportName;
  String? _supportTel;
  String? _supportOperator; // 担当者名（2026-08-29 ご指示で追加）

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
  /// 「接続しています」の下に出す途中経過（接続番号の登録を待っている間）。
  ///   ⚠ 何も出さずに長く待たせると、お客様は固まったと思って窓を閉じる。
  String? _prepNote;
  /// 常駐を一時停止する処理の最中か。
  bool _pausing = false;
  /// このサポートのために常駐を止めたか（終わるときに戻す）。
  bool _residentPaused = false;
  /// 直前に「操作を許可した」状態だったか。view_only へ戻ったことを検知するために持つ。
  bool _wasFullControl = false;
  /// 生存確認を何回まわしたか（記録用・2026-08-27）。
  int _pollTicks = 0;
  /// 生存確認が連続で失敗している回数（記録用・2026-08-27）。
  int _pollErrors = 0;

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
    // 「×」で閉じられたときも、終了と同じ後始末をする（説明は宣言の所）。
    rlEndByCustomerOnClose = _endByCustomer;
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

  /// いま動いているこの実行ファイルが、常駐版か。
  ///
  /// 判定は**自分の実行ファイルの場所**。常駐版は
  /// `<Program Files>\remohelppro-agent\remohelppro-agent.exe` に入る
  /// （src/platform/windows.rs:1343-1357 / 1415）。
  ///
  /// 🔴🔴 `mainGetAppNameSync()` を使ってはいけない（2026-08-08 実機で判明）。
  ///   APP_NAME を返すと思い込んでいたが、中身は**固定の文字列**だった:
  ///     flutter_ffi.rs:1116  SyncReturn("REMOHELP PRO".to_string())
  ///   リブランドのときに、表示名を統一するため書き換えられている。
  ///   ＝ 判定は**常に false** になり、常駐版でも固定パスワードを壊す処理が
  ///     走り続けていた。build-30 の修正は一度も効いていなかった。
  ///   ⚠ 名前を返す関数が「どの名前」を返すのかは、必ず中身を見て確かめる。
  ///
  /// ⚠ 「常駐が入っているか」（_residentInstalledByPath）と混同しない。
  ///   あちらはPCに入っているかを見るので、常駐が入ったPCでワンタイム版を
  ///   動かしても true になる。ここで使うと、**使い捨てのはずのワンタイム版が
  ///   後始末をやめてしまう**（前回の合言葉が残る）。
  ///   ここが見るのは「**自分自身**が常駐版か」。
  bool get _isResidentBuild {
    if (!Platform.isWindows) return false;
    try {
      return Platform.resolvedExecutable
          .toLowerCase()
          .contains('remohelppro-agent');
    } catch (_) {
      return false;
    }
  }

  /// 前回の一時パスワードを使えなくする。失敗しても起動は妨げない。
  Future<void> _invalidateLeftoverPassword() async {
    if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) return;
    // 🔴🔴 常駐版では**絶対に**やってはいけない（2026-08-07 判明）。
    //
    //   常駐版は登録のときに固定パスワードを作り、それをサーバーへ預ける
    //   （src/agent.rs:248-249, 267 `fixedPassword`）。相談員が常駐端末へ
    //   繋ぐときは、サーバーが預かっているその固定パスワードを使う。
    //   ★固定パスワードを作り直すのは**登録のとき1回だけ**。
    //     登録が済むと ensure_enrolled() は先頭で戻るので、二度と作り直さない。
    //
    //   ところがこの画面は常駐版のウィンドウにも出る
    //   （desktop_home_page.dart:146 は常駐版でも RemohelpproPairingCard を描く）。
    //   その initState でここが走ると、**サーバーが預かっている固定パスワードと
    //   PCの中身が食い違う**。しかも作り直す者はもう居ない。
    //   ＝ 常駐端末へ繋ぐと必ず「パスワードが間違っています」になる。
    //   ＝ お客様がログオンしてこの窓が一度開いた時点で、常駐は死ぬ。
    //
    //   実機で「常駐を入れ直したがパスワード間違いで接続できない」が
    //   繰り返し起きていた。その筋が通る。
    //   ⚠ ワンタイム版では今までどおり必要（残った一時パスワードを潰す）。
    //     消す理由が「毎回使い捨てだから」なので、常駐には当てはまらない。
    if (_isResidentBuild) {
      debugPrint('RL: 常駐版なので固定パスワードは触らない');
      return;
    }
    // 🔴🔴 復帰の合言葉を持っているときは**消してはいけない**
    //   （2026-08-27 実機で確定。両方のPCで毎回再現した）。
    //
    //   起動のたびにここで合言葉を `boot-乱数` に潰している。ところが
    //   ⚠ **設定は %LOCALAPPDATA% の固定の場所に残る**ので、再起動しても
    //     接続番号も合言葉もそのままである。相談員のビュアーは、再起動前の
    //     合言葉のまま、番号が戻ってくるのを待って繋ぎ直す。
    //   ＝ 本来そのまま繋がるはずのものを、こちらが**自分で潰していた**。
    //
    //   潰してから正しい合言葉を書き戻すまでには、
    //     中継サーバーへの登録待ち（最大60秒）＋番号の取得（最大16秒）＋通信
    //   がある。⚠ **その間ずっと合言葉が違う。**
    //   ビュアーは番号が生き返った瞬間に繋ぎに来るので、必ずその窓に当たり、
    //   「パスワードが間違っています」を出して**そこで止まる**
    //   （一度お客様に訊く形になると、あとで正しくなっても自動では戻らない）。
    //   ＝「再起動して続ける、を押すと必ずパスワードを訊かれる」の正体。
    //
    //   ★消す目的は「終了処理を通らずに落ちた前回の使い捨て合言葉を残さない」こと。
    //     復帰の合言葉があるなら、それは**まだ終わっていない同じサポート**であり、
    //     お客様の同意もその回に対して生きている。潰す理由が当てはまらない。
    //   ⚠ 復帰の合言葉は1回きり・30分で失効し、サポート終了時に
    //     clearRebootResume が消す。残り続けることはない。
    // 🔴🔴 **共有の場所も見る**（2026-09-01 実測で判明）。
    //
    //   ⚠ `hasResumeToken()` は `%LOCALAPPDATA%`（利用者ごとの場所）しか見ない。
    //     ログイン前の一時サービスは SYSTEM で動くので、⚠ **そこが見えない。**
    //     見えないと「復帰中ではない」と判断して、⚠ **合言葉を潰していた。**
    //   ＝ 実機で「再起動して繋ぎ直すと必ずパスワードを訊かれる」の正体。
    //     共有の設定ファイルで `password = ''` になっていたのを実測で確認した。
    //   ★どちらか一方にあれば復帰中とみなす。⚠ **潰さない側に倒す。**
    //     潰し忘れの害（前回の使い捨て合言葉が残る）は、
    //     30分で失効し、サポート終了時に消えるので小さい。
    //     潰しすぎの害（繋がらない）の方がはるかに大きい。
    if (hasResumeTokenAnywhere()) {
      debugPrint('RL: 復帰の合言葉があるので、前回の合言葉は残す');
      rlTrace('boot_keep_password');
      return;
    }
    rlTrace('boot_wipe_password');
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
      // ⚠ ワンクリック接続は**認証コードの画面を通らない**ので、
      //   ここで取らないと、お客様は最後まで相手が誰か分からないままになる。
      _readSupportContact(j);
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
      // 🔴🔴 合言葉の有無を**いちばん先に**見る（2026-08-27 実機で判明）。
      //
      //   元は「15秒だけ登録を待つ → 駄目なら諦める」だった。ところが
      //   ⚠ **再起動の直後がいちばん登録に時間がかかる**。ログオンした瞬間は
      //     回線も周辺の部品もまだ揃っていない。＝ ここで15秒で諦めるのは、
      //     いちばん失敗しやすい所にいちばん短い砂時計を置いていたことになる。
      //
      //   諦めるとどうなるか（2026-08-27 実機・お客様2台とも再現）:
      //     アプリは「認証コードを入力してください」に落ちる。
      //     ⚠ ところが**接続番号は変わらない**（MACアドレス由来なので、
      //       展開先が変わっても同じ番号になる → [[remohelppro-id-from-mac-address]]）。
      //     一方この端末の合言葉は、展開先が変わったため**まっさら**である
      //       （ワンタイム版は起動のたびに別の場所へ展開する ＝ 設定も別物）。
      //     相談員のビュアーは、再起動前の合言葉のまま同じ番号へ繋ぎ直す。
      //     ＝ **番号は生きているのに合言葉だけ違う** →
      //       相談員の画面に「パスワードが間違っています」が出る。
      //     これが「再起動して続ける、を押すと必ずパスワードを訊かれる」の正体。
      //
      //   ★合言葉が無ければ復帰ではないので、**待たずに**入力画面へ。
      //   ★合言葉があるなら、お客様は席に居ない前提なので**60秒粘る**。
      if (!hasResumeToken()) return false;
      await _startServiceAndWaitRegistered(waitSeconds: 60);
      final myId = await _waitForMyId();
      if (myId == null) return false;

      final res = await tryResume(apiBase: _kApiBase, rustdeskId: myId);
      if (res == null) {
        // 🔴🔴 **戻れなかったなら、仕掛けを自分で片付ける**（2026-08-28 ご指摘）。
        //
        //   ⚠ 実機で「1回しか落としていないのに窓が2つ出る」が起きた。
        //     正体は、前のサポートで仕掛けた**復帰の命令書が残っていた**こと。
        //     ログインのたびに勝手に起動し、戻れずに認証コードの画面を出す。
        //     そこへお客様が落としてきた物を開くと、⚠ **窓が2つ並ぶ**。
        //   ⚠ 片付けはサポート終了時に行う作りだが、⚠ **異常終了すると残る**。
        //     今日だけでも、落ちる・強制終了される形を何度も見ている。
        //   ★戻れなかった時点で、その仕掛けにはもう用が無い。ここで消す。
        //     ＝ 次のログインからは勝手に立ち上がらない（自分で治る）。
        rlTrace('resume_failed_cleanup');
        try {
          await clearRebootResume();
        } catch (e) {
          rlTrace('resume_cleanup_failed', {'e': e.toString()});
        }
        return false;
      }

      // 新しいワンタイムトークンを自分のパスワードにする。
      //   ⚠ 書けなかったら復帰を成立させない。書けていないのに「復帰した」と
      //     すると、相談員の画面には**繋がるように見えて**、実際に繋ぐと
      //     「パスワードが間違っています」になる（下の _writeOnetimePassword 参照）。
      await _writeOnetimePassword(res.onetimeToken);
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
  /// サーバーが返した「お客様に見せる連絡先」を取り込む。
  ///
  /// ⚠ 返ってこない／`null` のこともある（会社が電話番号を入れていない）。
  ///   そのときは**何も出さない**。社名だけを出すと、
  ///   確かめる手立てが無いのに「それらしく見える」だけの飾りになる。
  void _readSupportContact(Map j) {
    try {
      final c = j['supportContact'];
      if (c is Map) {
        final n = (c['name'] as String?)?.trim() ?? '';
        final t = (c['tel'] as String?)?.trim() ?? '';
        if (n.isNotEmpty && t.isNotEmpty) {
          _supportName = n;
          _supportTel = t;
          // 🔴 接続管理の窓へ渡す（2026-09-01 ご判断）。
          //   ⚠ あちらは**別のプロセス**なので、変数では届かない。
          //     設定ファイルは両方が読むので、そこに預ける。
          //   ⚠ お客様の画面に出ていた `相談員PCのユーザー名`（相談員PCの Windows ユーザー名）を
          //     この会社名に差し替えるために使う。
          //   ⚠ 取れないときは何も書かない＝あちらは従来どおりの表示に戻る。
          try {
            bind.mainSetLocalOption(key: 'rl-support-company', value: n);
          } catch (_) {}
        }
      }
      // 担当者名。⚠ 返し方が2つある（verify-pin は入れ子、pair-init は平ら）。
      //   どちらの経路でも同じ画面を出すので、両方を見る。
      final op = j['operator'];
      final opName = op is Map
          ? (op['name'] as String?)?.trim() ?? ''
          : (j['operatorName'] as String?)?.trim() ?? '';
      // ⚠ 「担当者」は名前が無いときの既定値。それを名前として出さない
      //   （「担当 担当者」という間の抜けた表示になる）。
      if (opName.isNotEmpty && opName != '担当者') _supportOperator = opName;
    } catch (_) {
      // ⚠ 読めなくても接続は進める。表示のためだけの値なので、
      //   ここで失敗して繋がらなくなる方がはるかに困る。
    }
  }

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
    // 🔴 ポーリングが止まる経路は3つしかない（2026-08-27 コードで確認）:
    //   ① ここ（画面が捨てられた） ② サポート終了 ③ プロセスそのものの消滅。
    //   ⚠ ①と②は残るようにした。**残っていなければ③**＝プロセスが消えた、
    //     と読める。これで初めて「消える」を切り分けられる。
    rlTrace('pairing_dispose', {
      'polling': _statusPoll != null,
      'terminated': _terminated,
      'ticks': _pollTicks,
    });
    rlNotifySupportEnded = null;
    rlEndByCustomerOnClose = null;
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
    rlTrace('terminate_by_support_end', {'ticks': _pollTicks});
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
    // 🔴🔴 **合言葉を潰すのは、ここ**（2026-08-27 ご指示で順番を入れ替えた）。
    //
    //   元はこの下の「常駐を元に戻す」より**後**に置いていた。
    //   ⚠ ところが常駐を元に戻す処理は **UAC（管理者の確認）を出して待つ**。
    //     お客様が押さなければ、そこで止まったまま先へ進まない。
    //     ＝ **合言葉が潰されないまま**になる。
    //   ★「誰も入れない」を決める2つ（サービスを止める・合言葉を潰す）は、
    //     途中で止まりうる処理より**必ず先**に済ませる。
    try {
      final rnd = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      await bind.mainSetPermanentPasswordWithResult(password: 'end-$rnd');
    } catch (_) {}
    // 再起動復帰の控えと自動起動の登録を消す。
    //   🔴 残すと、次にPCを起動したときに勝手にアプリが立ち上がる。
    //     お客様は「勝手に動いた」と受け取る。
    try {
      await clearRebootResume();
    } catch (_) {}
    // サポートのために常駐を止めていたら、元に戻す。
    //   ⚠ 戻せなくても、次にパソコンを起動すれば自動で戻る。
    //   ⚠ ここは UAC を出して待つので、**待ち続けない**（30秒で見切る）。
    //     終了そのものは上で済んでいるので、待つ理由が無い。
    try {
      await _resumeResidentIfPaused().timeout(const Duration(seconds: 30));
    } catch (_) {}
    if (mounted) setState(() {});
    // 穴B対策: ワンタイム版は終了後にプロセスを確実に終了させ、ランナーの自己削除(穴C)を発火させる。
    //   接続前に顧客が終了した場合(_hasEverConnected=false)は server_model の自動終了が働かないため、
    //   ここで保険をかける。「終了しました」を読む数秒を残してから exit(0)。
    if (kRlSupportShowWindow) {
      // 🔴🔴 **仲間の片付けは、20秒待たずに今すぐやる**（2026-08-27 ご指摘）。
      //
      //   ⚠ 元は「20秒後に片付けて自分も終わる」だった。ところが
      //     お客様も相談員も、終了した**直後**にタスクマネージャーを見る。
      //     そこに残っていれば「終わっていない」と受け取られる。実際そうなった。
      //   ★裏方(--server)・トレイ・接続の窓(--cm)は、終了した時点で用が無い。
      //     20秒待つ理由があるのは「終了しました」を**読んでいただく画面**だけ。
      //   ＝ 片付けは今すぐ、自分（画面の窓）だけ20秒残す。
      try {
        await bind.mainGetCommon(key: 'rl-kill-siblings');
      } catch (_) {}
      // Mac は自己展開ランナーが無いので、アプリが自分で後始末する。
      await _selfDeleteMacApp();
      // 🔴 4秒 → 20秒（2026-08-02 実機指摘）。
      //   「サポートを終了しました」を出しているのに、4秒で消えるため
      //   **お客様が読む前に画面ごと無くなっていた**。
      //   ご高齢のお客様は、画面が変わったことに気づくまでに時間がかかる。
      //   終わったことが伝わらないと「まだ繋がっているのでは」と不安が残る。
      //   ⚠ 接続はこの時点で既に切れており、待っている間に何かできる状態ではない。
      //     待つのは**読んでいただくため**だけなので、危険は増えない。
      Future.delayed(const Duration(seconds: 20), () async {
        // 🔴🔴 **自分だけ終わっても残る**（2026-08-27 実機のタスクマネージャーで確認）。
        //
        //   アプリは画面の窓・裏方(--server)・トレイ・接続の窓(--cm)と
        //   複数のプロセスで動いている。ここで exit(0) しているのは
        //   ⚠ **画面の窓だけ**なので、残りは動いたまま居座っていた。
        //   実害:
        //     ① 使い終わったはずのものがお客様のPCに残る（自己削除も効かない）
        //     ② 次に起動したとき、残骸が通信路を握ったままで
        //        ⚠ **接続番号が取れない**。今日の「接続番号がまだ取れていません」
        //        「Loading で落ちる」の正体。再起動で直るのは残骸が消えるから。
        //   ★消すのは「自分と同じフォルダから動いているもの」だけ。
        //     名前で消すと、表示名が同じ常駐版・相談員版まで巻き込む。
        //   ⚠ 上で一度片付けているが、20秒の間に立ち上がり直した物が
        //     居ることがあるので、終わる直前にもう一度やる。
        try {
          await bind.mainGetCommon(key: 'rl-kill-siblings');
        } catch (e) {
          // 片付けられなくても、自分は終わる（今までと同じ状態に戻るだけ）。
          rlTrace('kill_siblings_failed', {'e': e.toString()});
        }
        // 🔴 設定と記録も消す（2026-08-28 ご指摘「サポート終了後は削除が必要」）。
        //
        //   ⚠ ワンタイム版は利用者フォルダに**接続番号と合言葉**を書いている。
        //     展開先へ隔離するつもりだったが、⚠ Windows では効いていなかった。
        //     消さないと、お客様のPCに残り続ける＝「何も残らない」の約束に反する。
        //   ⚠ **アプリ名を分けたから消せる**（remohelppro-support）。
        //     分ける前は相談員版と同じフォルダで、消すと巻き添えになった。
        //   ⚠ 常駐版・相談員版では Rust 側で断るので、ここから呼んでも安全。
        //   ★消すのは**最後**。記録を先に消すと、この後の失敗が残らない。
        try {
          await bind.mainGetCommon(key: 'rl-wipe-onetime');
        } catch (e) {
          rlTrace('wipe_onetime_failed', {'e': e.toString()});
        }
        rlTrace('onetime_exit_after_end');
        await rlTraceFlushNow();
        exit(0);
      });
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

  /// 接続の窓（別プロセス）が置く「終了して」の合図。
  ///   ⚠ 置き場は %LOCALAPPDATA% の固定の場所。展開先(APP_DIR)は起動ごとに
  ///     変わりうるので使わない（復帰の合言葉と同じ考え）。
  File _endRequestFile() {
    final base = Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    return File('$base/REMOHELP PRO/end-requested');
  }

  void _clearEndRequest() {
    try {
      final f = _endRequestFile();
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// 合図があれば true を返し、**同時に消す**（二重に走らせない）。
  bool _consumeEndRequest() {
    try {
      final f = _endRequestFile();
      if (!f.existsSync()) return false;
      f.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 相談員の終了を検知するポーリング（被操作が繋がったままにならないように）。
  void _startStatusPoll(String shortId) {
    // 🔴 ここから先の出来事を、当社のサーバーでも読めるようにする（2026-08-27）。
    //   ⚠ このポーリングが止まること自体が「アプリが消えた」の唯一の兆候だった。
    //     止まった理由を残さない限り、何度直しても確かめようがない。
    rlTraceSetRole('main');
    rlTraceBind(shortId: shortId, custToken: _custToken);
    rlTrace('poll_start');
    _statusPoll?.cancel();
    // 接続の窓（別プロセス）から「切断」が押されたときの合図を消しておく。
    //   ⚠ 前回の合図が残っていると、繋がった直後に終わってしまう。
    _clearEndRequest();
    _statusPoll = Timer.periodic(const Duration(seconds: 4), (_) async {
      // 🔴 顧客が接続の窓の「切断」を押したか（2026-08-27 ご指摘）。
      //   あちらは別プロセスなので、決まった場所の合図で受け取る。
      //   ⚠ サーバーへの問い合わせより先に見る。通信が遅くても終われるように。
      if (_consumeEndRequest()) {
        rlTrace('poll_end_request_file');
        await _endByCustomer();
        return;
      }
      // 🔴 生きている印を、一定の間隔で残す（2026-08-27）。
      //   ⚠ 4秒ごとに全部送ると量が多すぎる。1分に1回だけ「生きている」を出す。
      //     ★これが**途切れた時刻**が、アプリが消えた時刻そのものになる。
      _pollTicks++;
      if (_pollTicks % 15 == 1) {
        rlTrace('alive', {'tick': _pollTicks});
      }
      try {
        final r = await http.get(
          Uri.parse('$_kApiBase/api/customer/session-status?shortId=$shortId'),
        );
        if (r.statusCode == 200) {
          if (_pollErrors > 0) {
            // 繋がらなかった時間の長さを残す（どれだけ孤立していたか）。
            rlTrace('poll_recovered', {'after': _pollErrors});
            _pollErrors = 0;
          }
          final j = jsonDecode(r.body) as Map;
          if (j['active'] == false) {
            rlTrace('poll_active_false');
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
            rlTrace('prelogon_requested');
            unawaited(_runPrelogon(shortId));
          }
        } else {
          // ⚠ 200 以外を黙って捨てていた（2026-08-27）。
          //   429（叩きすぎ）で止められていても気づけなかった。
          rlTrace('poll_http_status', {'status': r.statusCode});
        }
      } catch (e) {
        // ⚠ ここは「一時的な通信エラー」として握りつぶしていた。
        //   実際には切れっぱなしでも同じ見た目になり、
        //   何分繋がっていないのかが誰にも分からなかった。
        _pollErrors++;
        if (_pollErrors <= 3 || _pollErrors % 15 == 0) {
          rlTrace('poll_error', {'n': _pollErrors, 'e': e.toString()});
        }
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
    } catch (e) {
      // ⚠ 何に失敗したのかを残す。ここが空白だったせいで、
      //   「管理者の確認で断られた」のか「対策ソフトに止められた」のかが
      //   区別できなかった。相談員には同じ `failed` に見える。
      rlTrace('prelogon_exception', {'e': e.toString()});
      r = PrelogonResult.failed;
    }
    final name = r == PrelogonResult.ok
        ? 'ok'
        : (r == PrelogonResult.noAdmin ? 'noAdmin' : 'failed');
    rlTrace('prelogon_result', {'result': name});
    try {
      await http.post(
        Uri.parse('$_kApiBase/api/customer/prelogon-result'),
        headers: {
          'Content-Type': 'application/json',
          if (_custToken != null) 'x-customer-token': _custToken!,
        },
        body: jsonEncode({'shortId': shortId, 'result': name}),
      );
    } catch (e) {
      // 返せなくても、相談員側は「返事が無い」ことで気づける（画面に出す）。
      rlTrace('prelogon_report_failed', {'e': e.toString()});
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
      } catch (e) {
        // ⚠ ここが失敗すると、当社の画面は「接続中」のまま嘘をつく。
        //   握りつぶさずに残す（2026-08-27）。
        rlTrace('session_end_post_failed', {'e': e.toString()});
      }
    }
    try {
      await clearRebootResume();
    } catch (e) {
      rlTrace('clear_resume_failed', {'e': e.toString()});
    }
  }

  /// 顧客が自分で「終了する」を押したとき。
  ///   セッションを ended にし（相談員ダッシュボードにも伝わる）、被操作を停止・
  ///   一時パスワードを無効化する（＝以降は誰も操作できない）。
  Future<void> _endByCustomer() async {
    // 🔴🔴 **先に止める。伝えるのは後**（2026-08-27 ご指示で作り直し）。
    //
    //   元は「サーバーへ伝える → それから止める」だった。しかも
    //   ⚠ この `http.post` には**時間切れが無かった**。
    //     通信が失敗するのではなく**返事が来ないまま止まる**と、
    //     `await` はそこで待ち続け、⚠ **止める処理に一生たどり着かない**。
    //     ＝ お客様は「終了」を押したのに、遠隔接続は開いたまま。
    //     「通信失敗でもローカル停止は行う」と書いてあったが、
    //     **失敗と無応答は別物**で、無応答は救えていなかった。
    //
    //   ★終わらせるのに通信は要らない。被操作を止めて合言葉を潰せば、
    //     その時点で誰も入れない。サーバーへの連絡は**記録のため**であって、
    //     終了の条件ではない。だから先に止める。
    //   ⚠ 連絡には必ず時間切れを付ける（5秒）。届かなくても、
    //     相談員の画面は接続が切れたことで気づける。
    //   🔴🔴 **2026-09-02 追記：送り「始める」のは先。ただし待たない。**
    //
    //     ⚠ 実機で分かったこと（スクショ・サーバーの記録）:
    //       お客様が本体の「×」を押すと
    //         ・合言葉は無効になる（ビュアーに「パスワードが間違っています」）
    //         ・⚠ しかしコンソールは**「対応中」のまま**（14:07開始・終了なし）
    //         ・さらにコンソールが**「お客様の端末が再起動中です」**と誤表示
    //     ⚠ 原因: 呼び出し側（tabbar_widget の onWindowClose）は**6秒で打ち切る**。
    //       ところが `_terminateBySupportEnd()` の中には
    //       `_resumeResidentIfPaused()`（最大30秒待つ）が入っている。
    //       ＝ ⚠ **サーバーへ伝える所まで一度も辿り着いていなかった。**
    //
    //     ★上の教訓（通信で止める処理を止めない）は守る。**待たない**。
    //       送り始めてすぐ止める処理へ進む。結果は記録にだけ残す。
    //     ⚠ 順番を戻すだけにしない。戻すと 8/27 の事故（無応答で止まる）が再発する。
    final sid = _shortId;
    rlTrace('end_by_customer', {'ticks': _pollTicks, 'sid': sid ?? ''});
    if (sid != null) {
      // ⚠ await しない。送り始めるだけ。
      http
          .post(
            Uri.parse('$_kApiBase/api/customer/session-end'),
            headers: {
              'Content-Type': 'application/json',
              if (_custToken != null) 'x-customer-token': _custToken!,
            },
            body: jsonEncode({'shortId': sid}),
          )
          .timeout(const Duration(seconds: 5))
          .then((r) => rlTrace('end_notified', {'status': r.statusCode}))
          .catchError((Object e) {
        // ⚠ 伝えられなかったことを**必ず残す**。空白だと原因に辿り着けない。
        rlTrace('end_notify_failed', {'e': e.toString()});
      });
    } else {
      // ⚠ 接続番号が無い＝サーバーには伝えられない。黙って通り過ぎない。
      rlTrace('end_no_shortid');
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
      // 🔴 名前が2つある（2026-08-07）。片方だけ止めても、もう片方が
      //   登録の口を押さえたままになる。止める予定・戻す予定も両方に置く。
      //   ⚠ 入っていない方に sc stop をかけても害は無い（見つからないだけ）。
      const cmd = 'sc stop remohelppro'
          ' & sc stop remohelppro-agent'
          ' & schtasks /create /tn $_kResumeTask'
          ' /sc minute /mo 60'
          ' /tr "sc.exe start remohelppro"'
          ' /ru SYSTEM /rl HIGHEST /f'
          ' & schtasks /create /tn ${_kResumeTask}_AGENT'
          ' /sc minute /mo 60'
          ' /tr "sc.exe start remohelppro-agent"'
          ' /ru SYSTEM /rl HIGHEST /f';
      final ps = "\$ErrorActionPreference='Stop';"
          "\$p=Start-Process -FilePath 'cmd.exe'"
          " -ArgumentList '/c','$cmd'"
          " -Verb RunAs -WindowStyle Hidden -Wait -PassThru;"
          "exit \$p.ExitCode";
      // 🔴 黒い窓を出さない（2026-09-01・8/27 の直しの取り残し）。
      final out = await bind.mainGetCommon(
          key: 'rl-run-hidden:${jsonEncode([
            'powershell', '-NoProfile', '-NonInteractive', '-Command', ps
          ])}');
      // sc stop は「既に止まっている」でも 0 以外を返すことがある。
      // 成否は次の登録確認で判断する（止まっていれば通る）。
      debugPrint('RL pause resident: $out');
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
          ' & sc start remohelppro-agent'
          ' & schtasks /delete /tn $_kResumeTask /f'
          ' & schtasks /delete /tn ${_kResumeTask}_AGENT /f';
      const ps = "\$p=Start-Process -FilePath 'cmd.exe'"
          " -ArgumentList '/c','$cmd'"
          " -Verb RunAs -WindowStyle Hidden -Wait -PassThru; exit \$p.ExitCode";
      // 🔴 黒い窓を出さない（2026-09-01・8/27 の直しの取り残し）。
      await bind.mainGetCommon(
          key: 'rl-run-hidden:${jsonEncode([
            'powershell', '-NoProfile', '-NonInteractive', '-Command', ps
          ])}');
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
        // 🔴 会社名を名乗らない（2026-08-08 実機で判明）。
        //   ここは `slug: 'remohelppro'` と**焼き付け**られていた。
        //   ＝ リモシス以外の会社のお客様は、正しい認証コードを入れても
        //     必ず「認証コードが違うか、有効期限が切れています」になっていた。
        //   しかも症状が「番号が違う」なので、相談員は番号を読み上げ直すばかりで
        //   原因に辿り着けない。会社が増えるほど確実に踏む。
        //   ★アプリは会社を知らなくてよい。認証コードは全社で一意なので、
        //     サーバーが番号から会社を引ける（2026-08-08 の索引が前提）。
        body: jsonEncode({'pin': pin}),
      );
      if (vr.statusCode != 200) {
        throw Exception('認証コードが違うか、有効期限が切れています');
      }
      final vjson = jsonDecode(vr.body) as Map;
      final shortId = vjson['shortId'] as String;
      final mode = (vjson['mode'] as String?) ?? 'view_only';
      // 顧客セッショントークンを保存（以降の grant-control / session-end に添付する）。
      _custToken = vjson['customerToken'] as String?;
      _readSupportContact(vjson);

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
    // 🔴🔴 常駐版のウィンドウからワンタイム接続をさせない（2026-08-07 判明）。
    //
    //   下で mainSetPermanentPasswordWithResult() を呼び、一時トークンを
    //   **固定パスワードとして**書き込んでいる。ワンタイム版では正しいが、
    //   常駐版でこれをやると、サーバーが預かっている固定パスワードが
    //   PCの中身と食い違い、常駐端末へ二度と繋げなくなる（上の説明と同じ穴）。
    //
    //   さらに接続番号も常駐のものが使われるため、
    //   **ワンタイムのつもりで常駐の口を使ってしまう**。
    //   実際、本日つながった2件はどちらも常駐の接続番号
    //   （1060458689 / 688619419＝どちらも 0x20000000 の印つき）だった。
    //   ＝ 動いているように見えて、ワンタイムの導線は一度も通っていなかった。
    //
    //   ⚠ 行き止まりにしない。やることを書く。
    if (_isResidentBuild) {
      throw Exception('このパソコンには常駐版が入っています。\n'
          '常駐でお使いの場合、相談員は電話なしで接続できますので、\n'
          '認証コードの入力は不要です。\n\n'
          '一時的な接続をご希望の場合は、担当者からご案内する\n'
          '「お客様アプリ」からお願いします。');
    }
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
    await _writeOnetimePassword(token);

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
  /// その回限りの合言葉を、この端末に書き込む。
  ///
  /// 🔴🔴 **戻り値を捨てていた**（2026-08-27 実機で判明）。
  ///
  ///   `mainSetPermanentPasswordWithResult` は名前のとおり成否を返すが、
  ///   呼び出し側は `await` するだけで**結果を見ていなかった**。
  ///   ⚠ 書き込みは被操作サービスへの**通信路（名前付きパイプ）越し**に行われる
  ///     （src/ui_interface.rs:644 → ipc::set_permanent_password_with_ack）。
  ///     通信路が塞がっていれば false が返るだけで、例外は飛ばない。
  ///
  ///   その結果どうなるか:
  ///     アプリは何事もなく「準備完了」を出し、サーバーには合言葉を預ける。
  ///     相談員の画面にも `token: xxxx（自動入力）` と正しく出る。
  ///     ところが**端末側には何も書かれていない**ので、実際に繋ぐと
  ///     ⚠ **「パスワードが間違っています」**になる。
  ///     ＝ 画面のどこにも失敗が出ないまま、相談員だけが弾かれる。
  ///     2026-08-27 の実機（短ID 146298 / token Rk4cElis）がこれ。
  ///
  /// ★書けるまで少し粘り、それでも駄目なら**はっきり失敗させる**。
  ///   黙って「準備完了」を出すより、やり直していただく方がずっと早い。
  Future<void> _writeOnetimePassword(String token) async {
    // 被操作サービスが立ち上がりきる前だと最初の1回は落ちることがある。
    for (var i = 0; i < 6; i++) {
      final ok = await bind.mainSetPermanentPasswordWithResult(password: token);
      if (ok) return;
      await Future.delayed(const Duration(milliseconds: 700));
    }
    throw Exception('接続の合言葉をこのパソコンに書き込めませんでした。\n'
        'このまま進めても、担当者は「パスワードが間違っています」で\n'
        '弾かれてしまいます。\n\n'
        '次の順にお試しください。\n'
        '① このアプリを一度閉じて、開き直す\n'
        '② それでも駄目なら、パソコンを再起動する');
  }

  /// 被操作サービスを起動し、中継サーバーへの登録が済むまで待つ。
  ///
  /// 🔴🔴 待ち時間が**短すぎた**（2026-08-27 実機とサーバー記録で確定）。
  ///
  ///   元は 30回×0.5秒＝**15秒**であきらめていた。ところが、
  ///   ⚠ 21116 が使えず **443 の逃げ道**に落ちた端末は、
  ///     接続そのものに `CONNECT_TIMEOUT = 18秒`（libs/hbb_common/src/config.rs）
  ///     まで掛かることがある。＝ **繋がる前にこちらが先にあきらめる**。
  ///     どれだけ待っても成功しない、という当たり外れの正体。
  ///
  ///   実測（2026-08-27・お客様2台）:
  ///     失敗した回だけ `/ws/id`（443の逃げ道）を使っていた。
  ///     06:29:51 /ws/id 101 → 06:29:55 認証コード照合OK → **その先が一度も来ない**
  ///     （grant-control も session-status も記録に無い＝接続番号を渡せていない）。
  ///     2分後にアプリを開き直した回は逃げ道を使わず、そのまま成功している。
  ///
  ///   ★逃げ道の接続待ち(18秒)より**長く**待つ。60秒。
  ///   ⚠ 黙って待たない。途中経過を出す（[_prepNote]）。
  ///     何も出ないまま長く待たせると、お客様は固まったと思って窓を閉じる。
  ///   ⚠ 再起動からの復帰だけは短いまま（15秒）。あちらは失敗しても
  ///     「認証コードを入れてください」に落ちるだけなので、待たせる意味が無い。
  Future<void> _startServiceAndWaitRegistered({int waitSeconds = 60}) async {
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
    final rounds = waitSeconds * 2; // 0.5秒きざみ
    for (var i = 0; i < rounds; i++) {
      try {
        final st =
            jsonDecode(await bind.mainGetConnectStatus()) as Map<String, dynamic>;
        if ((st['status_num'] as int) == 1) {
          if (mounted) setState(() => _prepNote = null);
          return; // 登録完了
        }
      } catch (_) {
        /* 起動直後は取得できないことがあるのでリトライ */
      }
      // 8秒を過ぎたら、待っていることが分かるように途中経過を出す。
      //   ⚠ 秒数を出す。止まっているのか進んでいるのか、お客様に分かる形にする。
      if (i >= 16 && i % 4 == 0 && mounted) {
        setState(() => _prepNote = '接続の準備をしています（${i ~/ 2}秒）…');
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
    if (mounted) setState(() => _prepNote = null);
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
    // 🔴 mainIsInstalled() だけでは足りない（2026-08-07 名前を分けた副作用）。
    //
    //   この判定は Rust 側の is_installed() を呼ぶだけで、中身は
    //   `<Program Files>\<APP_NAME>\<APP_NAME>.exe` があるかを見ている
    //   （src/platform/windows.rs:1933 → 1415）。
    //   ★見るのは**自分の APP_NAME だけ**。
    //     このアプリ（ワンタイム版）の APP_NAME は `remohelppro` なので、
    //     常駐版 `remohelppro-agent` が入っていても **必ず false を返す**。
    //
    //   その結果どうなるか:
    //     常駐が邪魔をして繋がらないのに「サーバーに接続できませんでした。
    //     Wi-Fi をご確認ください」という**まったく違う案内**が出て、
    //     逃げ道のボタン（常駐を一時停止して接続する）も出ない。
    //     ＝ お客様も相談員も、通信の問題だと思って延々と時間を使う。
    //
    //   ⚠ 名前を分けたのは正しいが、**探す側を分け忘れていた**。
    //     入っているかどうかは、両方の名前で確かめる。
    if (!installed && Platform.isWindows) {
      installed = _residentInstalledByPath();
    }
    if (installed) {
      // 🔴 行き止まりにしない（2026-08-05 ご指示）。
      //   「常駐が入っているせいで繋がりません」で終わらせると、
      //   **お客様は今この瞬間サポートを受けられない**。
      //   常駐が半端に入って登録もできていない状態だと、常駐からも繋げず、
      //   逃げ道が「アンインストールして再起動」しか無くなる。
      //   電話口のお客様にそれを頼むのは無理がある。
      //   → その場で常駐を一時停止して繋げるようにする（下のボタン）。
      // 🔴🔴 常駐のせいだと**断定しない**（2026-08-08 実機で誤診が判明）。
      //
      //   元の文は「常駐版が動いている間は、この方法では接続できません」と
      //   言い切っていた。ところが同じ日に、**常駐が入っているPCで
      //   ワンタイムが問題なく使えること**を実機で確認している
      //   （同一PCで 1060458689 と 523587777 が並び、遠隔操作まで成立）。
      //   ＝ この文は**事実に反していた**。
      //
      //   実害: お客様も相談員も「常駐が悪い」と信じて一時停止を試み、
      //   直らないので途方に暮れる。実際「常駐を一時停止しても接続できない」
      //   というご報告になった。原因から**遠ざける**案内は、無い方がましである。
      //
      //   ★分かっているのは「中継サーバーから自分の番号を取れなかった」ことだけ。
      //     分かっていることだけを言い、試せる手を順に並べる。
      if (mounted) setState(() => _residentBlocking = true);
      throw Exception('中継サーバーに接続できませんでした。\n'
          'このパソコンの接続番号が取れていないため、まだ繋げません。\n\n'
          '次の順にお試しください。\n'
          '① このアプリを一度閉じて、開き直す\n'
          '② Wi-Fi／有線がつながっているか確認する\n'
          '③ それでも駄目なら、下の「常駐を一時停止して接続する」\n\n'
          '※ 常駐版が入っていても、通常はこのまま接続できます。③ は最後の手段です。');
    }
    // 🔴 「通信のせい」と言い切らない（2026-08-15 実機で確定）。
    //
    //   お客様の MacBook Pro（macOS 10.15.8）で、この文言のまま
    //   「ネットワークに接続できません」が出た。ところが実際は通信は正常で
    //   （中継サーバーの 21115〜21119・443 すべて到達を実測）、
    //   本当の理由は **アプリが macOS 11 以降にしか無い命令を呼んで落ちていた**
    //   （dyld: Symbol not found: _VTRegisterSupplementalVideoDecoderIfAvailable）。
    //
    //   実害: お客様も相談員も Wi-Fi を疑い、原因から遠ざかったまま時間を使う。
    //   ★分かっているのは「接続番号が取れなかった」ことだけ。
    //     それだけを言い、試せる手を順に並べる。
    final more = Platform.isMacOS
        ? '\n\n※ Mac で何度も出るときは、担当者にお知らせください。\n'
            '  原因を調べる道具があります（Mac の診断）。'
        : '';
    throw Exception('サーバーに接続できませんでした。\n'
        'このパソコンの接続番号が取れていないため、まだ繋げません。\n\n'
        '次の順にお試しください。\n'
        '① このアプリを一度閉じて、開き直す\n'
        '② Wi-Fi／有線がつながっているか確認する$more');
  }

  /// 常駐版がこのPCに入っているかを、**インストール先の実体**で確かめる。
  ///
  /// 置き場所は Rust 側と同じ規則:
  ///   `<Program Files>\<APP_NAME>\<APP_NAME>.exe`
  ///   （src/platform/windows.rs:1343-1357 / 1415）
  ///
  /// ⚠ ここでは**読むだけ**。止めたり消したりはしない。
  ///   判定を間違えても案内の文が変わるだけで済むようにしておく。
  bool _residentInstalledByPath() {
    if (!Platform.isWindows) return false;
    final pf = Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
    for (final name in _kResidentServices) {
      try {
        if (File('$pf\\$name\\$name.exe').existsSync()) return true;
      } catch (_) {
        /* 権限等で見られなければ、入っていないものとして扱う */
      }
    }
    return false;
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
                  // 🔴 会社が分かっていれば、帯にも社名を出す（2026-08-29 ご指示）。
                  //   ⚠ お客様が最初に目をやるのはここ。
                  //     製品名より「どこの会社か」の方が、お客様には意味がある。
                  //   ⚠ 分かるのは**認証コードを入れた後**。
                  //     入れる前は今までどおり製品名のまま
                  //     （全社共通の入口では、他社のお客様に別会社の名前が
                  //       見えてしまうため。2026-08-18 の決めごと）。
                  //   ⚠ 長い社名でも崩れないよう、はみ出したら「…」で切る。
                  Expanded(
                    child: Text(
                        _supportName == null
                            ? 'REMOHELP PRO ― リモートサポート'
                            : '$_supportName ― リモートサポート',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
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

  /// いまつながっている会社・電話番号・担当者（2026-08-29 ご指摘）。
  ///
  /// 🔴 これまで画面には「接続済み」としか出ていなかった。
  ///   お客様から見て、相手が誰なのかが分からなかった。
  ///
  /// 🔴🔴 **不安を煽る書き方をしない**（2026-08-29 ご指示）。
  ///   ⚠ 最初は「ご自分でお調べになった番号と同じかご確認ください」
  ///     「違うときは画面を閉じて…」と添えていた。⚠ **これは逆効果。**
  ///     ご高齢のお客様に、いま繋がっている相手を疑わせる文になっていた。
  ///     ＝ 安心させるつもりが、**不安にさせていた**。
  ///   ★出すのは**事実だけ**。会社名・電話番号・担当者名。
  ///     判断はお客様に委ねる。こちらから疑い方を教えない。
  ///   ⚠ 見出し（「つないでいる相手」）も要らない。
  ///     何が書いてあるかは見れば分かる。言葉が増えるほど読まれなくなる。
  ///
  /// ⚠ 番号が無ければ**何も出さない**（サーバーが null を返す）。
  ///   体験のお申し込みでは番号を聞いていないので、普通に起きる。
  Widget _supportContactCard() {
    final name = _supportName;
    final tel = _supportTel;
    if (name == null || tel == null) return const SizedBox.shrink();
    final op = _supportOperator;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F7FF),
        border: Border.all(color: const Color(0xFFC7DBFF)),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name,
              style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1F2937))),
          const SizedBox(height: 5),
          Row(
            children: [
              const Icon(Icons.call_outlined, size: 17, color: _accent),
              const SizedBox(width: 6),
              // ⚠ 選んで写せるようにする。掛け直すときに手で書き写させない。
              SelectableText(tel,
                  style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: _accent,
                      letterSpacing: 0.4)),
            ],
          ),
          // ⚠ 担当者名は分かるときだけ出す。
          //   分からないときに「担当者」とだけ出しても、何も伝わらない。
          if (op != null) ...[
            const SizedBox(height: 5),
            Row(
              children: [
                const Icon(Icons.person_outline, size: 16, color: _muted),
                const SizedBox(width: 6),
                Text('担当  $op',
                    style: const TextStyle(fontSize: 13, color: Color(0xFF4B5563))),
              ],
            ),
          ],
        ],
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

  // ══════════════════════════════════════════════════════════════
  // 会社のプロキシ設定（2026-08-17）
  //
  //   🔴🔴 なぜ、ここに自分で書くか。
  //     同じ窓は設定画面（desktop_setting_page.dart の changeSocks5Proxy）に
  //     既にある。⚠ しかし、あれを取り込むと
  //     desktop_tab_page / desktop_home_page まで一緒に付いてくる。
  //     このファイルは **Android の画面（mobile/pages/server_page.dart）も**
  //     使っているので、机上専用の部品を持ち込むと Android が壊れる。
  //     ＝ ここは短く書き写す方が安全。
  //
  //   ⚠ 直すときは**両方**直すこと（設定画面と、ここ）。
  //     ただし保存先は同じ（mainSetSocks）なので、食い違うのは見た目だけ。
  //
  //   ⚠ 窓は showDialog（この画面の context）で出す。
  //     gFFI.dialogManager は土台の登録が要り、お客様版では確実でない。
  // ══════════════════════════════════════════════════════════════
  Future<void> _showProxyDialog(BuildContext context) async {
    // 既に入っている値を出す（入れ直しをさせない）。
    var host = '';
    var user = '';
    var pass = '';
    try {
      final socks = await bind.mainGetSocks();
      if (socks.length == 3) {
        host = socks[0];
        user = socks[1];
        pass = socks[2];
      }
    } catch (e) {
      debugPrint('RL: プロキシ設定を読めませんでした: $e');
    }
    if (!mounted) return;

    final hostC = TextEditingController(text: host);
    final userC = TextEditingController(text: user);
    final passC = TextEditingController(text: pass);
    var saving = false;
    String? msg;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('会社のプロキシを設定する',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '社内からインターネットへ直接出られない会社では、\n'
                  'プロキシを通す必要があります。\n'
                  '設定の値は、会社のネットワーク担当者にご確認ください。',
                  style: TextStyle(fontSize: 12.5, color: _muted, height: 1.6),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: hostC,
                  decoration: const InputDecoration(
                    labelText: 'プロキシの場所',
                    hintText: 'socks5://192.168.1.1:1080',
                    helperText: '空欄にすると、プロキシを使わない設定に戻ります',
                    helperMaxLines: 2,
                    isDense: true,
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: userC,
                  decoration: const InputDecoration(
                      labelText: 'ユーザー名（必要なときだけ）', isDense: true),
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: passC,
                  obscureText: true,
                  decoration: const InputDecoration(
                      labelText: 'パスワード（必要なときだけ）', isDense: true),
                  style: const TextStyle(fontSize: 13),
                ),
                // ⚠ 種類を書いておかないと、http しか知らない担当者が困る。
                const SizedBox(height: 10),
                const Text(
                  '書き方の例：\n'
                  '  socks5://ホスト名:1080\n'
                  '  http://ホスト名:8080\n'
                  '  https://ホスト名:8080',
                  style: TextStyle(fontSize: 11, color: _faint, height: 1.5),
                ),
                if (msg != null) ...[
                  const SizedBox(height: 10),
                  Text(msg!,
                      style: const TextStyle(fontSize: 12, color: _danger)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.of(ctx).pop(),
              child: const Text('やめる'),
            ),
            TextButton(
              onPressed: saving
                  ? null
                  : () async {
                      setLocal(() {
                        saving = true;
                        msg = null;
                      });
                      try {
                        await bind.mainSetSocks(
                          proxy: hostC.text.trim(),
                          username: userC.text.trim(),
                          password: passC.text,
                        );
                      } catch (e) {
                        setLocal(() {
                          saving = false;
                          msg = '保存できませんでした：$e';
                        });
                        return;
                      }
                      if (ctx.mounted) Navigator.of(ctx).pop();
                    },
              child: Text(saving ? '保存しています…' : '保存する'),
            ),
          ],
        ),
      ),
    );

    hostC.dispose();
    userC.dispose();
    passC.dispose();
    if (!mounted) return;
    // 🔴 保存しただけでは繋がらない。**入れ直しが要る**ことを必ず伝える。
    //   ⚠ プロキシは接続を張り直すときに読まれるので、
    //     今出ている「繋がりません」は、閉じて開き直すまで消えない。
    setState(() {
      _error = 'プロキシの設定を保存しました。\n'
          'このアプリを一度閉じて、開き直してからお試しください。';
    });
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
            // 接続番号の登録を待っている間の途中経過。
            //   ⚠ 出るのは8秒を過ぎてからだけ。普通に繋がるときは出ない。
            if (_prepNote != null) ...[
              const SizedBox(height: 6),
              Text(_prepNote!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12.5, color: _faint)),
            ],
            // 🔴 待っている間こそ出す（2026-08-29 ご指摘）。
            //   ⚠ 繋がるまでの数十秒が、お客様がいちばん不安な時間。
            //     ここで相手が分かれば、待つ理由がはっきりする。
            //   ⚠ 認証コードを入れた直後なので、会社はもう分かっている。
            _supportContactCard(),
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
            // 🔴 いちばん上に置く（2026-08-29 ご指摘）。
            //   ⚠ お客様が確かめたいのは「相手が誰か」。
            //     下に置くと、画面を送らないと見えない＝無いのと同じになる。
            _supportContactCard(),
            // 🔴🔴 Mac の許可を、その場で案内する（2026-08-16 ご指摘「動作が多すぎ」）。
            //
            //   Mac は繋がっても、許可が無いと**映像が出ない・操作できない**。
            //   ところが当社のアプリは**許可について一言も出していなかった**。
            //   ＝ Mac のお客様は全員ここで止まり、相談員が電話で説明するしかない。
            //   ⚠ 設定画面を直接開くボタンまで置く。探させない。
            //   ⚠ Windows には出さない（この手間が無い）。
            const MacPermissionCard(accent: _accent),
            // 🔴🔴 いま実際に操作されているかを、お客様の画面に出す
            //   （2026-08-08 ご指摘）。
            //
            //   「接続済み」は**準備ができた**という意味でしかない。
            //   ところがお客様から見ると、繋がっているのか、誰かが今この瞬間
            //   自分の画面を見ているのかが区別できない。
            //   ★見られている最中は、そうと分かるように出す。
            //     これは機能ではなく**約束**にあたる。黙って見ないこと。
            //
            //   ⚠ 判定は「実際に繋がっている相手が居るか」。
            //     server_model が持っている接続中の一覧を見る。
            //     許可した／コードを入れた、では足りない（まだ見られていない）。
            //   ⚠ 1秒ごとの時計(_clock)で作り直されるので、
            //     つながった1秒以内に出て、切れた1秒以内に消える。
            if (gFFI.serverModel.clients.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF1F1),
                  border: Border.all(color: const Color(0xFFF3C9C9)),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Column(
                  children: [
                    const Text('🔴 ただいま遠隔サポート中です',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: _danger)),
                    const SizedBox(height: 3),
                    Text(
                      '担当者がこのパソコンの画面を見ています。'
                      '\nやめるときは下の「終了する」を押してください。',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 11.5, color: Color(0xFF9A3B3B), height: 1.45),
                    ),
                  ],
                ),
              ),
            ],
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
          // 🔴🔴 プロキシの設定への入口（2026-08-17）。
          //
          //   法人のお客様は、社内から直接インターネットへ出られず
          //   **プロキシを通さないと通信できない**ことがある。
          //   RustDesk はプロキシ（Socks5/Http(s)）に対応しているが、
          //   ⚠ その設定は**設定画面の中**にあり、
          //     お客様版には設定画面そのものが無い（認証コード入力だけ）。
          //   ＝ プロキシ必須の会社では、**繋ぐ手立てがまったく無かった**。
          //
          //   ★繋がらなかったときにだけ出す。普段は出さない
          //     （高齢のお客様に、要らない選択肢を見せない）。
          //   ⚠ 相談員が電話口で「会社のプロキシの設定を入れてください」と
          //     言える形にしておくのが目的。
          if (_error != null) ...[
            const SizedBox(height: 10),
            Center(
              child: TextButton.icon(
                onPressed: () => _showProxyDialog(context),
                icon: const Icon(Icons.settings_ethernet, size: 16),
                label: const Text('会社のプロキシを設定する',
                    style: TextStyle(fontSize: 12.5)),
                style: TextButton.styleFrom(foregroundColor: _muted),
              ),
            ),
            const Text(
              '社内からインターネットへ直接出られない会社では、\nプロキシの設定が必要なことがあります（担当者にご確認ください）。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: _faint, height: 1.5),
            ),
          ],
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
