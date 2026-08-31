/// 遠隔サポート中の「AI分析」。相談員が囲った範囲をAIに読ませ、直し方の下書きを出す。
///
/// 経緯（2026-08-28 ご指示）:
///   相談員が原因に辿り着くまでに時間がかかる。画面の一部を読ませて助ける。
///
/// 🔴🔴 **送るのは「囲った範囲」だけ**（設計の要）。
///
///   ⚠ 画面には、お客様の個人情報・取引先・業務ソフトの名前が写っている。
///     自動で隠す（黒塗り）方式は**必ず取りこぼす**——名前や社名は
///     形が決まっておらず、写真や図の中の情報は文字として拾えない。
///   ★人が囲った所だけを送れば、⚠ **囲わなかった物は原理的に出ていかない**。
///     「隠せるから安全」ではなく「送る物を人が決める」設計にする。
///   ⚠ 画面全体を既定にしない。楽な方が既定になると、必ずそちらが使われる。
///
/// 🔴 送る前に、**送る画像そのものを相談員に見せる**。黙って送らない。
///   ⚠ 「送る」は押しやすい見た目にするが、⚠ **Enter の既定は「やめる」**。
///     取り返しがつかない方を既定にしない（再起動待ちで28秒差でお客様を
///     締め出した件と同じ考え方）。
///
/// 🔴 画面を1枚取るのは**既存の仕組みをそのまま使う**。
///   ⚠ 新しい取り方を作らない。ツールバーの「スクリーンショット」と同じ道
///     （`sessionTakeScreenshot` → 'screenshot' の合図 → `'0:<パス>'` で保存）。
///     ここを自作すると、片方だけ壊れたときに気づけない。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'models/model.dart';
import 'models/platform_model.dart';
import 'remohelppro_trace.dart' show rlTrace;

const String _kApiBase = 'https://svr.remohelppro.jp';

/// 送る画像の長辺の上限。
///
/// 🔴🔴 **ここが「1回いくら」を決める**（2026-08-28）。
///   ⚠ 費用は画像の大きさ（縦×横）で効いてくる。画面全体（1920×1080）を
///     送ると、エラーの窓だけを送る場合の**何十倍**にもなる。
///   ★縮めてから送ることで、1回の最大費用が確定する。
///     ＝ 会社ごとの「回数制限」だけで定額運用が成り立つ。
///   ⚠ 1200px あれば、エラーの文字は読める（文字が潰れると意味が無い）。
const int kAiMaxLongSide = 1200;

/// AI分析の状態。⚠ 1つの値をみんなで見る（ツールバーと画面が別の部品のため）。
class RlAiState {
  /// いま範囲を選んでいる最中か。
  final selecting = ValueNotifier<bool>(false);

  /// 結果パネルを出しているか。
  final showPanel = ValueNotifier<bool>(false);

  /// 分析中か。
  final busy = ValueNotifier<bool>(false);

  /// 直近の結果（無ければ null）。
  final result = ValueNotifier<RlAiResult?>(null);

  /// 直近の失敗の理由（無ければ null）。
  ///
  /// ⚠ 黙って何も起きないのが一番困る。断られた理由は必ず画面に出す。
  final error = ValueNotifier<String?>(null);
}

/// 相談員ごと・接続ごとに1つ持つ。
final rlAi = RlAiState();

class RlAiCause {
  final String text;
  final String confidence; // high / medium / low
  const RlAiCause(this.text, this.confidence);
}

class RlAiResult {
  final String seen;
  final List<RlAiCause> causes;
  final List<String> steps;
  final String prevention;
  final int used;
  final int limit;
  final int width;
  final int height;
  const RlAiResult({
    required this.seen,
    required this.causes,
    required this.steps,
    required this.prevention,
    required this.used,
    required this.limit,
    required this.width,
    required this.height,
  });
}

/// お客様の画面を1枚取って、指定の範囲だけを切り出す。
///
/// [rectOnImage] は**画像の座標**（画面上の座標ではない）。呼ぶ側で換算する。
/// 取れなければ null（⚠ 理由は記録に残す）。
Future<({Uint8List bytes, int w, int h})?> rlAiCaptureAndCrop({
  required FFI ffi,
  required Rect rectOnImage,
}) async {
  final dir = await Directory.systemTemp.createTemp('rl-ai-');
  final path = '${dir.path}/shot.png';
  try {
    // ① 既存の仕組みで1枚取る。⚠ 相手の返事を待つ必要がある。
    final done = Completer<void>();
    ffi.ffiModel.timerScreenshot?.cancel();
    // 'screenshot' の合図が来たら保存する、という約束をここで結ぶ。
    _pending = () async {
      final err = await bind.sessionHandleScreenshot(
          sessionId: ffi.sessionId, action: '0:$path');
      if (err.isNotEmpty) {
        rlTrace('ai_capture_save_failed', {'e': err});
      }
      if (!done.isCompleted) done.complete();
    };
    await bind.sessionTakeScreenshot(
        sessionId: ffi.sessionId, display: ffi.ffiModel.pi.currentDisplay);
    await done.future.timeout(const Duration(seconds: 20));

    final f = File(path);
    if (!await f.exists()) {
      rlTrace('ai_capture_no_file');
      return null;
    }
    final raw = await f.readAsBytes();

    // ② 囲った範囲だけを切り出し、長辺 1200px まで縮める。
    final codec = await ui.instantiateImageCodec(raw);
    final frame = await codec.getNextFrame();
    final src = frame.image;

    final crop = Rect.fromLTRB(
      rectOnImage.left.clamp(0, src.width.toDouble()),
      rectOnImage.top.clamp(0, src.height.toDouble()),
      rectOnImage.right.clamp(0, src.width.toDouble()),
      rectOnImage.bottom.clamp(0, src.height.toDouble()),
    );
    if (crop.width < 8 || crop.height < 8) {
      rlTrace('ai_capture_too_small', {'w': crop.width, 'h': crop.height});
      return null;
    }

    final longSide = crop.width > crop.height ? crop.width : crop.height;
    final scale = longSide > kAiMaxLongSide ? kAiMaxLongSide / longSide : 1.0;
    final outW = (crop.width * scale).round();
    final outH = (crop.height * scale).round();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      src,
      crop,
      Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble()),
      Paint()..filterQuality = FilterQuality.medium,
    );
    final picture = recorder.endRecording();
    final out = await picture.toImage(outW, outH);
    final png = await out.toByteData(format: ui.ImageByteFormat.png);
    src.dispose();
    out.dispose();
    if (png == null) return null;
    return (bytes: png.buffer.asUint8List(), w: outW, h: outH);
  } catch (e) {
    rlTrace('ai_capture_failed', {'e': e.toString()});
    return null;
  } finally {
    // ⚠ 一時ファイルは必ず消す。お客様の画面がPCに残らないようにする。
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }
}

/// 'screenshot' の合図が来たときに実行する約束。⚠ 1回きり。
Future<void> Function()? _pending;

/// model.dart の 'screenshot' 分岐から呼ぶ。
///
/// 🔴 AI分析が待っているときは、⚠ **いつもの保存ダイアログを出さない**。
///   出すと、相談員に二重の操作をさせることになる。
/// 戻り値 true ＝ こちらで処理した（呼び出し側は何もしない）。
bool rlAiConsumeScreenshot() {
  final p = _pending;
  if (p == null) return false;
  _pending = null;
  unawaited(p());
  return true;
}

/// 切り出した画像をサーバーへ送って、下書きを受け取る。
///
/// ⚠ 断られた理由は、そのまま画面に出す（黙って何も起きないのをやめる）。
Future<void> rlAiSend({
  required FFI ffi,
  required Uint8List png,
  required int w,
  required int h,
  String note = '',
}) async {
  rlAi.busy.value = true;
  rlAi.error.value = null;
  try {
    final id = ffi.id;
    final token = ffi.presetPassword ?? '';
    if (id.isEmpty || token.isEmpty) {
      rlAi.error.value = 'この接続では使えません。';
      return;
    }
    final r = await http
        .post(
          Uri.parse('$_kApiBase/api/customer/ai-analyze-by-viewer'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'rustdeskId': id,
            'token': token,
            'image': base64Encode(png),
            'mediaType': 'image/png',
            'note': note,
            'width': w,
            'height': h,
          }),
        )
        .timeout(const Duration(seconds: 40));

    Map<String, dynamic> j;
    try {
      j = jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      j = {};
    }

    if (r.statusCode != 200 || j['ok'] != true) {
      // ⚠ サーバーが理由を返してくれる。そのまま出す。
      final msg = (j['message'] as String?) ??
          '分析できませんでした（${r.statusCode}）。もう一度お試しください。';
      rlAi.error.value = msg;
      rlTrace('ai_analyze_refused',
          {'status': r.statusCode, 'reason': j['reason']?.toString() ?? ''});
      return;
    }

    final quota = (j['quota'] as Map?) ?? const {};
    rlAi.result.value = RlAiResult(
      seen: (j['seen'] as String?) ?? '',
      causes: ((j['causes'] as List?) ?? const [])
          .map((c) => RlAiCause(
                (c is Map ? c['text'] as String? : null) ?? '',
                (c is Map ? c['confidence'] as String? : null) ?? 'low',
              ))
          .where((c) => c.text.isNotEmpty)
          .toList(),
      steps: ((j['steps'] as List?) ?? const [])
          .map((s) => s.toString())
          .where((s) => s.isNotEmpty)
          .toList(),
      prevention: (j['prevention'] as String?) ?? '',
      used: (quota['used'] as num?)?.toInt() ?? 0,
      limit: (quota['limit'] as num?)?.toInt() ?? 0,
      width: w,
      height: h,
    );
    rlAi.showPanel.value = true;
    rlTrace('ai_analyze_ok', {'w': w, 'h': h});
  } catch (e) {
    rlAi.error.value = '分析できませんでした。通信をご確認ください。';
    rlTrace('ai_analyze_error', {'e': e.toString()});
  } finally {
    rlAi.busy.value = false;
  }
}

// ═══════════════════════════════════════════════════════════════
// 範囲を選ぶ膜
// ═══════════════════════════════════════════════════════════════

/// 画面を暗くして、ドラッグで範囲を囲ってもらう膜。
///
/// 🔴 お絵かきのオーバーレイと**同じ作り**にする（映像の上に1枚重ねる）。
///   ⚠ 新しい仕組みを増やさない。座標の換算も同じ式を使う:
///     画面 = 画像 × scale + canvas.x/y
///   ここを自作すると、片方の直しがもう片方に伝わらない。
///
/// ⚠ 選んでいないときは何も出さない（`IgnorePointer` ですらなく、空を返す）。
///   通常の遠隔操作の邪魔を、一切しないため。
class RlAiSelectOverlay extends StatefulWidget {
  final FFI ffi;
  const RlAiSelectOverlay({Key? key, required this.ffi}) : super(key: key);

  @override
  State<RlAiSelectOverlay> createState() => _RlAiSelectOverlayState();
}

class _RlAiSelectOverlayState extends State<RlAiSelectOverlay> {
  Offset? _start;
  Offset? _now;

  @override
  void initState() {
    super.initState();
    rlAi.selecting.addListener(_onChanged);
  }

  @override
  void dispose() {
    rlAi.selecting.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) {
      setState(() {
        _start = null;
        _now = null;
      });
    }
  }

  /// 画面の座標 → 画像の座標。⚠ お絵かきと同じ式。
  Rect? _toImageRect(Rect onScreen) {
    final c = widget.ffi.canvasModel;
    final scale = c.scale;
    if (!scale.isFinite || scale <= 0) return null;
    return Rect.fromLTRB(
      (onScreen.left - c.x) / scale,
      (onScreen.top - c.y) / scale,
      (onScreen.right - c.x) / scale,
      (onScreen.bottom - c.y) / scale,
    );
  }

  Future<void> _finish(Rect onScreen) async {
    rlAi.selecting.value = false;
    final imageRect = _toImageRect(onScreen);
    if (imageRect == null || imageRect.width < 8 || imageRect.height < 8) {
      rlAi.error.value = '範囲が小さすぎます。もう一度囲ってください。';
      return;
    }
    rlAi.busy.value = true;
    final shot = await rlAiCaptureAndCrop(ffi: widget.ffi, rectOnImage: imageRect);
    rlAi.busy.value = false;
    if (shot == null) {
      rlAi.error.value = '画面を取り込めませんでした。もう一度お試しください。';
      return;
    }
    if (!mounted) return;
    // ⚠ 黙って送らない。送る物そのものを見せてから。
    await rlAiShowConfirm(context: context, ffi: widget.ffi, shot: shot);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: rlAi.selecting,
      builder: (context, selecting, _) {
        if (!selecting) return const SizedBox.shrink();
        final rect = (_start != null && _now != null)
            ? Rect.fromPoints(_start!, _now!)
            : null;
        return Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (d) => setState(() {
              _start = d.localPosition;
              _now = d.localPosition;
            }),
            onPanUpdate: (d) => setState(() => _now = d.localPosition),
            onPanEnd: (_) {
              final r = rect;
              if (r != null && r.width >= 8 && r.height >= 8) {
                _finish(r);
              } else {
                setState(() {
                  _start = null;
                  _now = null;
                });
              }
            },
            child: Stack(
              children: [
                // 暗くする膜。囲った所だけ明るく見せる。
                Positioned.fill(
                  child: CustomPaint(painter: _DimPainter(rect)),
                ),
                if (rect != null)
                  Positioned(
                    left: rect.left,
                    top: rect.top,
                    width: rect.width,
                    height: rect.height,
                    child: IgnorePointer(
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(
                              color: const Color(0xFF22D3EE), width: 2),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 28,
                  child: IgnorePointer(
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xEE0C121C),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          '送りたい所をドラッグで囲ってください　／　Esc でやめる',
                          style: TextStyle(color: Color(0xFFE2E8F0), fontSize: 13),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 囲った所以外を暗くする。
class _DimPainter extends CustomPainter {
  final Rect? hole;
  _DimPainter(this.hole);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0x9E030912);
    final full = Rect.fromLTWH(0, 0, size.width, size.height);
    final h = hole;
    if (h == null) {
      canvas.drawRect(full, paint);
      return;
    }
    // 囲った所だけ抜く（4辺を塗る形。Path の差分より読み違えにくい）。
    canvas.drawRect(Rect.fromLTRB(0, 0, size.width, h.top), paint);
    canvas.drawRect(Rect.fromLTRB(0, h.bottom, size.width, size.height), paint);
    canvas.drawRect(Rect.fromLTRB(0, h.top, h.left, h.bottom), paint);
    canvas.drawRect(Rect.fromLTRB(h.right, h.top, size.width, h.bottom), paint);
  }

  @override
  bool shouldRepaint(covariant _DimPainter old) => old.hole != hole;
}

// ═══════════════════════════════════════════════════════════════
// 送る前の確認
// ═══════════════════════════════════════════════════════════════

/// 送る画像そのものを見せて、確かめてもらう。
///
/// 🔴 **黙って送らない**（2026-08-28 の設計）。
///   ⚠ ここで初めて、相談員は「何が出ていくのか」を目で見る。
///   ★「送る」は押しやすい見た目にするが、⚠ **既定（Esc・外側を押す）は「やめる」**。
///     取り返しがつかない方を既定にしない。
Future<void> rlAiShowConfirm({
  required BuildContext context,
  required FFI ffi,
  required ({Uint8List bytes, int w, int h}) shot,
}) async {
  final noteCtrl = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => AlertDialog(
      title: const Text('この画像をAIに送ります', style: TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ★送る物そのもの。ここを省くと「確認」の意味が無い。
            Container(
              constraints: const BoxConstraints(maxHeight: 260),
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFFD1D5DB)),
              ),
              child: Image.memory(shot.bytes, fit: BoxFit.contain),
            ),
            const SizedBox(height: 6),
            Text('${shot.w} × ${shot.h} ピクセル',
                style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
            const SizedBox(height: 10),
            TextField(
              controller: noteCtrl,
              maxLength: 200,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                labelText: 'お客様から伺っている症状（任意）',
                helperText: '電話で聞いた内容を入れると、切り分けが深くなります',
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(9),
              color: const Color(0xFFFEF3C7),
              child: const Text(
                '⚠ お客様の画面の一部が、当社の外（AI）へ送られます。\n'
                '画像は保存しません。使った記録（日時・相談員）だけが残ります。',
                style: TextStyle(fontSize: 11.5, color: Color(0xFF713F12)),
              ),
            ),
          ],
        ),
      ),
      actions: [
        // ⚠ 危ない方を目立たせない。
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('やめる'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('この画像を送る'),
        ),
      ],
    ),
  );
  // ⚠ 閉じられた（Esc・外側を押した）ときは送らない。
  if (ok != true) {
    rlTrace('ai_confirm_cancelled');
    return;
  }
  await rlAiSend(
    ffi: ffi,
    png: shot.bytes,
    w: shot.w,
    h: shot.h,
    note: noteCtrl.text.trim(),
  );
}

// ═══════════════════════════════════════════════════════════════
// 結果パネル
// ═══════════════════════════════════════════════════════════════

/// 右に寄せて出す下書き。
///
/// 🔴 「AIが判断しました」とは書かない（2026-08-28 の設計）。
///   ⚠ 断定して見せると、相談員が確かめずに実行する。
///     お客様のPCを壊す操作を勧めてしまう恐れがある。
///   ★「下書き」と明記し、確かめる手順を先に置く。
class RlAiPanel extends StatelessWidget {
  const RlAiPanel({Key? key}) : super(key: key);

  static const _bg = Color(0xFF0F1A26);
  static const _line = Color(0xFF24394A);
  static const _muted = Color(0xFF8EA3B5);
  static const _accent = Color(0xFF45C3DA);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: rlAi.showPanel,
      builder: (context, show, _) {
        if (!show) return const SizedBox.shrink();
        return ValueListenableBuilder<RlAiResult?>(
          valueListenable: rlAi.result,
          builder: (context, r, _) {
            if (r == null) return const SizedBox.shrink();
            return Container(
              width: 320,
              color: _bg,
              padding: const EdgeInsets.all(14),
              child: ListView(
                children: [
                  Row(
                    children: [
                      // 🔴 「下書き」→「判断」（2026-08-30 ご指示）。
                      //   ⚠ 下の注意書きも同時に変えること。片方だけ変えると
                      //     画面の中で言い方が食い違う。
                      const Text('AI判断',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.bold)),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close, size: 16, color: _muted),
                        onPressed: () => rlAi.showPanel.value = false,
                        tooltip: '閉じる',
                      ),
                    ],
                  ),
                  _title('見えていること'),
                  _body(r.seen),
                  if (r.causes.isNotEmpty) _title('考えられる原因'),
                  ...r.causes.map(_cause),
                  if (r.steps.isNotEmpty) _title('次にやること'),
                  ...r.steps.asMap().entries.map((e) => _step(e.key + 1, e.value)),
                  if (r.prevention.isNotEmpty) _title('再発させないために'),
                  if (r.prevention.isNotEmpty) _body(r.prevention),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: const BoxDecoration(
                      color: Color(0xFF33280F),
                      border: Border(
                          left: BorderSide(color: Color(0xFFDDA63F), width: 3)),
                    ),
                    child: const Text(
                      '⚠ これはAI判断です。実行する前に、相談員が内容を確かめてください。',
                      style: TextStyle(color: Color(0xFFF5E0B4), fontSize: 11),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Divider(color: _line, height: 1),
                  const SizedBox(height: 8),
                  Text(
                    '送った範囲　${r.width}×${r.height} px\n'
                    '今月の利用　${r.used} / ${r.limit} 回',
                    style:
                        const TextStyle(color: _muted, fontSize: 10, height: 1.7),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _title(String t) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 4),
        child: Text(t,
            style: const TextStyle(
                color: _muted,
                fontSize: 10,
                letterSpacing: 1.2,
                fontWeight: FontWeight.bold)),
      );

  Widget _body(String t) => Text(t,
      style: const TextStyle(color: Colors.white, fontSize: 12, height: 1.7));

  Widget _cause(RlAiCause c) {
    final w = c.confidence == 'high'
        ? 0.85
        : c.confidence == 'medium'
            ? 0.45
            : 0.15;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6, right: 7),
            child: SizedBox(
              width: 34,
              height: 5,
              child: LinearProgressIndicator(
                value: w,
                backgroundColor: _line,
                valueColor: const AlwaysStoppedAnimation<Color>(_accent),
              ),
            ),
          ),
          Expanded(
            child: Text(c.text,
                style: const TextStyle(
                    color: Colors.white, fontSize: 11.5, height: 1.6)),
          ),
        ],
      ),
    );
  }

  Widget _step(int n, String t) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 18,
              height: 18,
              margin: const EdgeInsets.only(right: 8, top: 2),
              decoration: BoxDecoration(
                  color: _accent, borderRadius: BorderRadius.circular(4)),
              child: Center(
                child: Text('$n',
                    style: const TextStyle(
                        color: Color(0xFF06212A),
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold)),
              ),
            ),
            Expanded(
              child: Text(t,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 11.5, height: 1.6)),
            ),
          ],
        ),
      );
}

// ═══════════════════════════════════════════════════════════════
// 残り回数（押す前に分かるように）
// ═══════════════════════════════════════════════════════════════

/// この会社でAI分析が使えるか。⚠ 未確認のうちは null（ボタンを出さない）。
final rlAiEnabled = ValueNotifier<bool?>(null);

/// 今月の残り回数。⚠ 未確認は null。
final rlAiRemaining = ValueNotifier<int?>(null);

/// 今月の上限（表示用）。
final rlAiLimit = ValueNotifier<int>(0);

/// 残り回数をサーバーへ聞く。
///
/// 🔴 押す前に分かるようにするため（2026-08-28 ご指示）。
///   ⚠ 「押したら断られた」では遅い。今日ずっと直してきた
///     「黙って何も起きない／押してから知る」と同じ形なので、最初から出す。
///   ⚠ 会社が許可していなければ **enabled=false** が返る → ボタンごと出さない。
///     押せるのに毎回断られる釦は、置いてあるだけで邪魔になる。
/// ⚠ 失敗しても何も壊さない（未確認のまま＝ボタンを出さないだけ）。
Future<void> rlAiRefreshQuota(FFI ffi) async {
  try {
    final id = ffi.id;
    final token = ffi.presetPassword ?? '';
    if (id.isEmpty || token.isEmpty) return;
    final r = await http
        .post(
          Uri.parse('$_kApiBase/api/customer/ai-quota-by-viewer'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'rustdeskId': id, 'token': token}),
        )
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) return;
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    if (j['ok'] != true) return;
    rlAiEnabled.value = j['enabled'] == true;
    rlAiLimit.value = (j['limit'] as num?)?.toInt() ?? 0;
    rlAiRemaining.value = (j['remaining'] as num?)?.toInt() ?? 0;
  } catch (_) {
    // ⚠ 聞けなくても何も壊さない。ボタンが出ないだけ。
  }
}
