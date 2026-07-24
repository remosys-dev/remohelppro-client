import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../common.dart';
import 'model.dart';

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
      case 'clear':
        _remote.clear();
        notifyListeners();
        break;
      case 'enable':
        // 相手がお絵かきを終えたら、相手の線は残さない。
        if (m['enable'] != true) {
          _remote.clear();
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
    _enabled = false;
  }

  // ── 内部 ──────────────────────────────────────────────────────

  void _addPoint(Offset offset) {
    final pos = parent.target?.inputModel
        .handlePointerDevicePos(kPointerEventKindMouse, offset.dx, offset.dy, false, '');
    if (pos == null) return;
    final x = pos.x.toInt();
    final y = pos.y.toInt();

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
    // 点3が線分(1,2)の延長からどれだけ外れているか
    final dx = (x2 - x1).toDouble();
    final dy = (y2 - y1).toDouble();
    final len = dx * dx + dy * dy;
    if (len == 0) return true;
    final cross = ((x3 - x1) * dy - (y3 - y1) * dx).abs();
    return cross / len.abs() < _simplifyTolerance;
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
      // 送る点は無いが、ひと筆の終わりだけは伝える
      _send(jsonEncode({
        'kind': 'stroke',
        'xs': [0],
        'ys': [0],
        'color': colorLocal,
        'width': strokeWidth,
        'display': 0,
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

  /// 相手の実座標 → こちらの表示座標。拡大・スクロールに追従させる。
  double _lx(int x) => x * canvas.scale + canvas.x;
  double _ly(int y) => y * canvas.scale + canvas.y;

  @override
  bool shouldRepaint(covariant _AnnotationPainter old) => true;
}
