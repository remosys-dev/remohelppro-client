import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, File, Directory, exit;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/common.dart' show gFFI;
import 'remohelppro_livekit.dart';
import 'rl_support.dart' show kRlSupportShowWindow;

const String _kApiBase = 'https://svr.remohelppro.jp';
const String _kSlug = 'remohelppro';

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
  bool _terminated = false;

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
    // ワンクリック接続：ランチャーが置いた DLトークンがあれば、手入力を飛ばして自動接続する。
    _maybeAutoStart();
  }

  /// ワンクリック接続の入口。
  ///   ランチャー(remohelppro-customer-lite.exe)が %TEMP%\remohelppro-pair.dlt に置いた
  ///   DLトークンを読み、あれば pair-init で shortId＋顧客トークンを取得して、6桁手入力を
  ///   スキップしてそのまま自動でペアリングする。トークンが無い／失効していれば、静かに
  ///   従来どおりの手入力カードを表示する（＝壊さない）。
  Future<void> _maybeAutoStart() async {
    if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) return;
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

  /// サイドカー(%TEMP%\remohelppro-pair.dlt)から DLトークンを読み、読めたら削除する（単回）。
  Future<String?> _readAndConsumeDlToken() async {
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
    _statusPoll?.cancel();
    _statusPoll = null;
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
    _clock?.cancel();
    _clock = null;
    try {
      await bind.mainCloseAllConnections();
    } catch (_) {}
    try {
      await bind.mainStopService();
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
      Future.delayed(const Duration(seconds: 4), () => exit(0));
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
          }
        }
      } catch (_) {
        /* 一時的な通信エラーは無視（次のtickで再確認） */
      }
    });
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
      if (mode == 'camera' || mode == 'view_only') {
        // PC(Windows/Mac/Linux)では、カメラ・画面共有は「ブラウザ」で行う（アプリ不要）。
        //   このアプリ(PC版)が担当するのは「遠隔操作」だけ。
        if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
          throw Exception(
              'このコードは「ブラウザ」でご利用ください。\n'
              'ブラウザで svr.remohelppro.jp を開き、同じ認証コードを入力してください。\n'
              '（画面共有・カメラはアプリ不要でご利用いただけます）');
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
  Future<void> _finishRemotePairing(String shortId) async {
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
      body: jsonEncode({'shortId': shortId, 'rustdeskId': myId}),
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
        width: 392,
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
