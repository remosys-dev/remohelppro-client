import 'dart:async';
import 'dart:convert';
import 'dart:math' show sqrt;

// Offset/Canvas/Path/Paint などは material が dart:ui を再輸出しているので
// dart:ui を直接 import しない（曖昧な参照を避ける）。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../common.dart';
import '../consts.dart';
import 'model.dart';
import 'platform_model.dart';

/// 画面注釈（双方向お絵かき）。
///
/// 相談員が顧客の画面に線を引いて指し示すための機能。**操作は一切しない** ――
/// カーソルも動かず、クリックも起きないので、遠隔操作の許可が下りていない
/// 画面共有だけの場面でも使える。
///
/// 座標は「相手の画面の実ピクセル」で送る。拡大・スクロールしても位置がずれない
/// ように、既存の入力系と同じ変換（InputModel.handlePointerDevicePos）を通す。
class AnnotationModel with ChangeNotifier {
  final WeakReference<FFI> parent;

  AnnotationModel(this.parent);

  /// 相談員＝赤、顧客＝青の固定。どちらが描いたか一目で分かるようにする。
  static const int colorLocal = 0xFFE03131;
  static const int colorRemote = 0xFF1971C2;

  /// 線の太さ（相手の画面の実ピクセル基準）
  static const int strokeWidth = 4;

  /// 何ミリ秒ぶんの点をまとめて送るか。毎秒60回が上限。
  static const _sendIntervalMs = 16;

  /// 送信側で直線とみなして間引く許容ずれ（相手の実ピクセル）
  static const _simplifyTolerance = 2.0;

  bool _enabled = false;
  bool _autoFade = true;

  /// お絵かきモードか
  bool get enabled => _enabled;

  /// 線を自動で消すか（既定 true＝7秒で薄れて消える）
  bool get autoFade => _autoFade;

  /// 自分が描いた線（相手の実座標）
  final List<_Stroke> _local = [];

  /// 相手が描いた線（相手の実座標＝こちらの表示座標に変換して描く）
  final List<_Stroke> _remote = [];

  List<_Stroke> get localStrokes => _local;
  List<_Stroke> get remoteStrokes => _remote;

  // ── 送信のまとめ ──────────────────────────────────────────────
  final List<int> _pendingXs = [];
  final List<int> _pendingYs = [];
  Timer? _flushTimer;

  SessionID get _sid => parent.target!.sessionId;

  void setEnabled(bool v) {
    if (_enabled == v) return;
    _enabled = v;
    if (!v) {
      _endStroke();
    }
    // 顧客側の告知帯を出し分けるため、開始／終了を相手にも伝える。
    _send(jsonEncode({'kind': 'enable', 'enable': v}));
    notifyListeners();
  }

  void setAutoFade(bool v) {
    if (_autoFade == v) return;
    _autoFade = v;
    notifyListeners();
  }

  /// ひと筆の開始。offset は描画ウィジェット上の位置。
  void onPanStart(Offset offset) {
    if (!_enabled) return;
    _local.add(_Stroke(color: colorLocal, width: strokeWidth.toDouble()));
    _addPoint(offset);
  }

  void onPanUpdate(Offset offset) {
    if (!_enabled) return;
    _addPoint(offset);
  }

  void onPanEnd() {
    if (!_enabled) return;
    _endStroke();
  }

  // ── レーザーポインター ─────────────────────────────────────────
  //   お絵かきとは別物。線を残さず、今指している場所だけを光点で見せる。
  //   通信は既存のお絵かきの経路をそのまま使う（新しい橋渡しは要らない）。
  bool _laserMode = false;
  bool get laserMode => _laserMode;
  Offset? _laser; // 相手から届いた光点（相手の画面の実ピクセル）
  Offset? get laser => _laser;
  Timer? _laserTimer;
  DateTime _lastLaserSent = DateTime.fromMillisecondsSinceEpoch(0);

  void setLaserMode(bool on) {
    if (_laserMode == on) return;
    _laserMode = on;
    if (!on) {
      // 消えたことを相手にも伝える。伝えないと光点が残ったままになる。
      _send(jsonEncode({'kind': 'laser'}));
    }
    notifyListeners();
  }

  /// 相談員がマウスを動かしたとき。offset は描画ウィジェット上の位置。
  void onLaserMove(Offset offset) {
    if (!_laserMode) return;
    final c = parent.target?.canvasModel;
    if (c == null) return;
    final scale = c.scale;
    if (!scale.isFinite || scale <= 0) return;
    // 送りすぎない。1秒に約20回で、目で見て十分に滑らか。
    final now = DateTime.now();
    if (now.difference(_lastLaserSent).inMilliseconds < 50) return;
    _lastLaserSent = now;
    _send(jsonEncode({
      'kind': 'laser',
      'x': (offset.dx - c.x) / scale,
      'y': (offset.dy - c.y) / scale,
      'display': parent.target?.ffiModel.pi.currentDisplay ?? 0,
    }));
  }

  /// 自分が描いたものを全部消す（相手側からも消える）。
  void clear() {
    _local.clear();
    _pendingXs.clear();
    _pendingYs.clear();
    _send(jsonEncode({'kind': 'clear'}));
    notifyListeners();
  }

  /// 相手から届いた注釈。
  void onRemoteAction(String data) {
    final Map<String, dynamic> m;
    try {
      m = jsonDecode(data) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (m['kind']) {
      case 'stroke':
        final xs = (m['xs'] as List?)?.cast<num>() ?? const [];
        final ys = (m['ys'] as List?)?.cast<num>() ?? const [];
        if (xs.isEmpty || xs.length != ys.length) return;
        final end = m['end'] == true;
        // 続きなら直前の線に繋げる。
        if (_remote.isNotEmpty && !_remote.last.done) {
          _remote.last.addAll(xs, ys);
          _remote.last.done = end;
        } else {
          final s = _Stroke(
            color: (m['color'] as num?)?.toInt() ?? colorRemote,
            width: ((m['width'] as num?)?.toDouble() ?? 4.0),
          );
          s.addAll(xs, ys);
          s.done = end;
          _remote.add(s);
        }
        notifyListeners();
        break;
      case 'laser':
        // レーザーポインター（2026-07-29 ユーザー要望）。
        //   線を残さず、相談員のマウス位置だけを光点で示す。
        //   「そこです」と口で言うより早く、線が残らないので画面も汚れない。
        final lx = (m['x'] as num?)?.toDouble();
        final ly = (m['y'] as num?)?.toDouble();
        if (lx == null || ly == null) {
          _laser = null;
        } else {
          _laser = Offset(lx, ly);
          // 相手が動かすのをやめたら自然に消す。切断や取りこぼしで
          // 光点が画面に残り続けないための保険でもある。
          _laserTimer?.cancel();
          _laserTimer = Timer(const Duration(milliseconds: 1200), () {
            _laser = null;
            notifyListeners();
          });
        }
        notifyListeners();
        break;
      case 'clear':
        _remote.clear();
        _laser = null;
        _laserTimer?.cancel();
        notifyListeners();
        break;
      case 'enable':
        if (m['enable'] != true) {
          // 顧客が「やめてもらう」を押した場合もここに来る。
          // 相手の線を消すだけでなく、こちらの描画も止める（拒否を尊重する）。
          _remote.clear();
          _local.clear();
          if (_enabled) {
            _enabled = false;
            _endStroke();
          }
          notifyListeners();
        }
        break;
    }
  }

  /// セッション終了時に呼ぶ。注釈は記録ではないので残さない。
  void reset() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _local.clear();
    _remote.clear();
    _pendingXs.clear();
    _pendingYs.clear();
    _laserTimer?.cancel();
    _laserTimer = null;
    _laser = null;
    _laserMode = false;
    _enabled = false;
  }

  // ── 内部 ──────────────────────────────────────────────────────

  void _addPoint(Offset offset) {
    // 🔴 遠隔操作の座標変換を借りない（2026-07-29 実機指摘）。
    //
    //   借りていた handlePointerDevicePos は**ウィンドウ全体**の座標を前提に、
    //   タブバーと枠の分（CanvasModel.topToEdge / leftToEdge）を引く。
    //   しかしお絵かきの層は Positioned.fill で**既にその下**に置かれており、
    //   受け取る位置にタブバーは含まれない。＝ **二重に引いていた**。
    //   結果、線がマウスより上（タブバーの高さぶん）にずれて描かれていた。
    //
    //   ここは描画専用なので、**絵を出すときの計算をそのまま逆にする**のが正しい。
    //   下の _AnnotationPainter は  画面 = 画像 * scale + canvas.x/y  で描く。
    //   その逆をとれば必ずマウスの真下に線が乗る（式が1つなのでずれようがない）。
    final c = parent.target?.canvasModel;
    if (c == null) return;
    final scale = c.scale;
    if (!scale.isFinite || scale <= 0) return;
    final x = ((offset.dx - c.x) / scale).round();
    final y = ((offset.dy - c.y) / scale).round();

    final s = _local.isNotEmpty ? _local.last : null;
    if (s == null) return;

    // ほぼ一直線に並ぶ点は捨てる（見た目は変わらず、点数はおおむね半分以下になる）。
    if (s.xs.length >= 2) {
      final n = s.xs.length;
      if (_isNearlyCollinear(
          s.xs[n - 2], s.ys[n - 2], s.xs[n - 1], s.ys[n - 1], x, y)) {
        // 直前の点を新しい点で置き換える
        s.xs[n - 1] = x;
        s.ys[n - 1] = y;
        if (_pendingXs.isNotEmpty) {
          _pendingXs[_pendingXs.length - 1] = x;
          _pendingYs[_pendingYs.length - 1] = y;
        } else {
          // 🔴 直前の送信で出し切った直後はここに来る。以前は何もしていなかったので、
          //   間引きに入った点が**相手に一度も届かず**、顧客側の線だけが途中で
          //   止まっていた（こちらの画面には見えているので気づきにくい）。
          _pendingXs.add(x);
          _pendingYs.add(y);
        }
        notifyListeners();
        _scheduleFlush();
        return;
      }
    }

    s.xs.add(x);
    s.ys.add(y);
    _pendingXs.add(x);
    _pendingYs.add(y);
    notifyListeners();
    _scheduleFlush();
  }

  bool _isNearlyCollinear(
      int x1, int y1, int x2, int y2, int x3, int y3) {
    // 点3が直線(1,2)からどれだけ外れているか（＝垂線の長さ・ピクセル）。
    final dx = (x2 - x1).toDouble();
    final dy = (y2 - y1).toDouble();
    final lenSq = dx * dx + dy * dy; // ★長さの「2乗」
    if (lenSq == 0) return true;
    final cross = ((x3 - x1) * dy - (y3 - y1) * dx).abs();
    // 🔴 必ず平方根を取ること（2026-07-27 実機で判明したバグ）。
    //   lenSq のまま割ると、値は「ずれ ÷ 点の間隔」になってしまう。
    //   描いている最中の点の間隔は数px しかないので、**直角に折れ曲がっても**
    //   許容値 2.0 を下回り、すべての点が「直線上」と判定されていた。
    //   その結果ひと筆が常に2点しか持たず、何を描いても直線になっていた。
    return cross / sqrt(lenSq) < _simplifyTolerance;
  }

  void _scheduleFlush() {
    _flushTimer ??= Timer(const Duration(milliseconds: _sendIntervalMs), () {
      _flushTimer = null;
      _flush(false);
    });
  }

  void _endStroke() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_local.isNotEmpty) {
      _local.last.done = true;
    }
    // 描き終わりは必ず送り切る。取りこぼすと線が途中で切れる。
    _flush(true);
    notifyListeners();
  }

  void _flush(bool end) {
    if (_pendingXs.isEmpty && !end) return;
    if (_pendingXs.isEmpty && end) {
      // 送る点は無いが、ひと筆の終わりだけは伝えたい。
      // 🔴 ここで (0,0) を送ってはいけない（2026-07-27 実機で判明したバグ）。
      //   受け取った側は届いた点をそのまま線に繋ぐので、**画面の左上隅へ
      //   一直線が引かれてしまう**。お客様の画面にだけ出るので気づきにくい。
      //   終わりを伝えるだけなら、相手が既に持っている「最後の点」をもう一度
      //   送ればよい（同じ点＝長さ0なので見た目は変わらない）。
      final s = _local.isNotEmpty ? _local.last : null;
      if (s == null || s.xs.isEmpty) return;
      _send(jsonEncode({
        'kind': 'stroke',
        'xs': [s.xs.last],
        'ys': [s.ys.last],
        'color': colorLocal,
        'width': strokeWidth,
        'display': parent.target?.ffiModel.pi.currentDisplay ?? 0,
        'end': true,
      }));
      return;
    }
    _send(jsonEncode({
      'kind': 'stroke',
      'xs': List<int>.from(_pendingXs),
      'ys': List<int>.from(_pendingYs),
      'color': colorLocal,
      'width': strokeWidth,
      'display': parent.target?.ffiModel.pi.currentDisplay ?? 0,
      'end': end,
    }));
    _pendingXs.clear();
    _pendingYs.clear();
  }

  void _send(String data) {
    bind.sessionSendDraw(sessionId: _sid, data: data);
  }
}

/// ひと筆。座標は相手の画面の実ピクセル。
class _Stroke {
  final List<int> xs = [];
  final List<int> ys = [];
  final int color;
  final double width;
  bool done = false;
  DateTime born = DateTime.now();

  _Stroke({required this.color, required this.width});

  void addAll(List<num> nxs, List<num> nys) {
    for (var i = 0; i < nxs.length; i++) {
      xs.add(nxs[i].toInt());
      ys.add(nys[i].toInt());
    }
    born = DateTime.now();
  }

  /// 自動で消えるときの不透明度（0.0-1.0）。
  double opacity(bool autoFade) {
    if (!autoFade) return 1.0;
    final ms = DateTime.now().difference(born).inMilliseconds;
    const hold = 7000;
    const fade = 800;
    if (ms <= hold) return 1.0;
    final f = ms - hold;
    if (f >= fade) return 0.0;
    return 1.0 - f / fade;
  }
}

/// 相談員側の描画層。映像の上に重ねる。
class AnnotationOverlay extends StatefulWidget {
  final FFI ffi;
  const AnnotationOverlay({Key? key, required this.ffi}) : super(key: key);

  @override
  State<AnnotationOverlay> createState() => _AnnotationOverlayState();
}

class _AnnotationOverlayState extends State<AnnotationOverlay> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // 自動フェードを進めるための再描画。描く線が無いときは回さない。
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final m = widget.ffi.annotationModel;
      if (m.localStrokes.isNotEmpty || m.remoteStrokes.isNotEmpty) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.ffi.annotationModel;
    return ChangeNotifierProvider.value(
      value: m,
      child: Consumer<AnnotationModel>(
        builder: (context, model, _) {
          final painter = CustomPaint(
            painter: _AnnotationPainter(
              model: model,
              canvas: widget.ffi.canvasModel,
            ),
            size: Size.infinite,
          );
          // レーザーポインター中はマウスの動きだけを見る。
          //   クリックは奪わない（相談員が操作もできるように）。
          if (model.laserMode && !model.enabled) {
            return MouseRegion(
              opaque: false,
              onHover: (e) => model.onLaserMove(e.localPosition),
              onExit: (_) => model.onLaserMove(const Offset(-1, -1)),
              child: IgnorePointer(child: painter),
            );
          }
          // お絵かき OFF のときは入力を一切奪わない。
          if (!model.enabled) {
            return IgnorePointer(child: painter);
          }
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (d) => model.onPanStart(d.localPosition),
            onPanUpdate: (d) => model.onPanUpdate(d.localPosition),
            onPanEnd: (_) => model.onPanEnd(),
            child: painter,
          );
        },
      ),
    );
  }
}

class _AnnotationPainter extends CustomPainter {
  final AnnotationModel model;
  final CanvasModel canvas;

  _AnnotationPainter({required this.model, required this.canvas});

  @override
  void paint(Canvas c, Size size) {
    _paintAll(c, model.localStrokes);
    _paintAll(c, model.remoteStrokes);
    final laser = model.laser;
    if (laser != null) {
      _paintLaser(c, Offset(_lxd(laser.dx), _lyd(laser.dy)));
    }
  }

  void _paintAll(Canvas c, List<_Stroke> strokes) {
    for (final s in strokes) {
      if (s.xs.length < 2) continue;
      final o = s.opacity(model.autoFade);
      if (o <= 0.0) continue;
      final paint = Paint()
        ..color = Color(s.color).withOpacity(o)
        ..strokeWidth = s.width * canvas.scale
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true;
      final path = Path()..moveTo(_lx(s.xs[0]), _ly(s.ys[0]));
      for (var i = 1; i < s.xs.length; i++) {
        path.lineTo(_lx(s.xs[i]), _ly(s.ys[i]));
      }
      c.drawPath(path, paint);
    }
  }

  /// レーザーポインターの光点。線は残さず、今指している場所だけを見せる。
  ///   中心を白く、外側をぼかした赤にする。写真や暗い画面でも埋もれない。
  void _paintLaser(Canvas c, Offset p) {
    final glow = Paint()
      ..color = const Color(0x66FF3B30)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    c.drawCircle(p, 13, glow);
    c.drawCircle(p, 7, Paint()..color = const Color(0xCCFF3B30));
    c.drawCircle(p, 2.5, Paint()..color = const Color(0xFFFFFFFF));
  }

  /// 相手の実座標 → こちらの表示座標。拡大・スクロールに追従させる。
  double _lx(int x) => x * canvas.scale + canvas.x;
  double _lxd(double x) => x * canvas.scale + canvas.x;
  double _lyd(double y) => y * canvas.scale + canvas.y;
  double _ly(int y) => y * canvas.scale + canvas.y;

  @override
  bool shouldRepaint(covariant _AnnotationPainter old) => true;
}
