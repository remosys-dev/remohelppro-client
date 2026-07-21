import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:livekit_client/livekit_client.dart';
import 'package:flutter_background/flutter_background.dart';

/// REMOHELP PRO 統合アプリ：LiveKit 配信画面。
///   camera=false → 画面共有（RustDesk一本化後は通常使わないが、LiveKitへ戻せるよう温存）
///   camera=true  → カメラ配信（現地の様子を見せる。操作員はブラウザ/opで視聴）
/// 遠隔操作(view/control)は RustDesk 経路（remohelppro_pairing.dart）。
const String _kApiBase = 'https://svr.remohelppro.jp';

class RemohelpproLiveKitScreen extends StatefulWidget {
  final String shortId;
  final bool camera; // true=カメラ / false=画面共有
  final String? custToken; // 顧客セッショントークン（あれば livekit-token に添付）
  const RemohelpproLiveKitScreen({
    Key? key,
    required this.shortId,
    this.camera = false,
    this.custToken,
  }) : super(key: key);
  @override
  State<RemohelpproLiveKitScreen> createState() =>
      _RemohelpproLiveKitScreenState();
}

class _RemohelpproLiveKitScreenState extends State<RemohelpproLiveKitScreen> {
  Room? _room;
  LocalVideoTrack? _cameraTrack;
  String _status = '接続の準備をしています…';
  bool _live = false;
  String? _error;
  // REMOHELP PRO: 顧客が自分の声を止められるようにする（プライバシー配慮）
  bool _micOn = true;

  // 相談員からの「カメラを動かす方向」指示（矢印オーバーレイ）
  EventsListener<RoomEvent>? _dataListener;
  String? _arrow; // 'up' | 'down' | 'left' | 'right'
  Timer? _arrowTimer;

  // REMOHELP PRO: カメラ映像への描画（Web版と同じ DataChannel プロトコル）
  //   受信/送信 {type:'draw', from, pts:[[x,y]...]} と {type:'draw-clear'}
  //   ※ pts は映像に対する 0..1 の正規化座標。相談員の線=黄 / 自分(顧客)=水色。
  //   ※ Web版に合わせ 8 秒で自動的に消える。
  final List<_Stroke> _strokes = [];
  List<Offset>? _curStroke; // 指でなぞっている最中の線（正規化座標）
  Timer? _strokeGc;

  // REMOHELP PRO: 描画のズレ防止。
  //   LiveKit の VideoTrackRenderer は fit=Contain 既定のため、枠比と映像比が違うと
  //   枠内にレターボックス（余白）ができ、「枠基準」で正規化した座標が相談員側
  //   （映像の実表示領域基準）とズレる。→ 自前レンダラで実映像サイズを取得し、
  //   枠の比＝映像の比 に合わせる（余白ゼロ＝座標が 1:1 で一致）。
  webrtc.RTCVideoRenderer? _previewRenderer;
  double _videoAspect = 4 / 3; // 実サイズ判明までの暫定値

  bool get _isCamera => widget.camera;

  /// 相談員が送る指示（DataChannel）を受ける。矢印＋描画に対応。
  void _setupDataListener(Room room) {
    final listener = room.createListener();
    listener.on<DataReceivedEvent>((event) {
      try {
        final j = jsonDecode(utf8.decode(event.data)) as Map;
        final t = j['type'];
        if (t == 'arrow' && j['dir'] is String) {
          _showArrow(j['dir'] as String);
        } else if (t == 'draw' && j['pts'] is List) {
          _addStroke(j['pts'] as List, mine: false);
        } else if (t == 'draw-clear') {
          if (mounted) setState(() => _strokes.clear());
        }
      } catch (_) {
        /* 不正payloadは無視 */
      }
    });
    _dataListener = listener;
  }

  void _showArrow(String dir) {
    _arrowTimer?.cancel();
    if (mounted) setState(() => _arrow = dir);
    _arrowTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _arrow = null);
    });
  }

  /// 線を追加（pts は 0..1 の正規化座標）。mine=false は相談員から届いた線。
  void _addStroke(List raw, {required bool mine}) {
    final pts = <Offset>[];
    for (final p in raw) {
      if (p is List && p.length >= 2 && p[0] is num && p[1] is num) {
        pts.add(Offset(
          (p[0] as num).toDouble().clamp(0.0, 1.0),
          (p[1] as num).toDouble().clamp(0.0, 1.0),
        ));
      }
    }
    if (pts.length < 2 || !mounted) return;
    setState(() => _strokes
        .add(_Stroke(pts, DateTime.now().millisecondsSinceEpoch, mine)));
    _ensureStrokeGc();
  }

  /// Web版と同じく 8 秒経過した線を消す。
  void _ensureStrokeGc() {
    _strokeGc ??= Timer.periodic(const Duration(milliseconds: 500), (_) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final before = _strokes.length;
      _strokes.removeWhere((s) => now - s.ts > 8000);
      if (mounted && _strokes.length != before) setState(() {});
      if (_strokes.isEmpty) {
        _strokeGc?.cancel();
        _strokeGc = null;
      }
    });
  }

  /// 自分（顧客）が描いた線を相談員へ送る（Web版と同形式・最大60点に間引き）。
  Future<void> _sendDraw(List<Offset> pts) async {
    final room = _room;
    if (room == null || pts.length < 2) return;
    var step = (pts.length / 60).ceil();
    if (step < 1) step = 1;
    final thin = <List<double>>[];
    for (var i = 0; i < pts.length; i++) {
      if (i % step == 0 || i == pts.length - 1) {
        thin.add([
          double.parse(pts[i].dx.toStringAsFixed(3)),
          double.parse(pts[i].dy.toStringAsFixed(3)),
        ]);
      }
    }
    try {
      final payload = utf8.encode(
          jsonEncode({'type': 'draw', 'from': 'customer', 'pts': thin}));
      await room.localParticipant?.publishData(payload, reliable: true);
    } catch (_) {
      /* 送信失敗は無視（表示は自分側に残る） */
    }
  }

  /// マイクのオン/オフ。顧客が自分の声を止められるようにする（プライバシー配慮）。
  Future<void> _toggleMic() async {
    final next = !_micOn;
    try {
      await _room?.localParticipant?.setMicrophoneEnabled(next);
      if (mounted) setState(() => _micOn = next);
    } catch (_) {
      /* 切替に失敗したら状態は変えない */
    }
  }

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      // 1) LiveKit JWT
      setState(() => _status = 'サーバから接続情報を取得しています…');
      final r = await http.post(
        Uri.parse('$_kApiBase/api/livekit/token'),
        headers: {
          'Content-Type': 'application/json',
          if (widget.custToken != null) 'x-customer-token': widget.custToken!,
        },
        body: jsonEncode({'shortId': widget.shortId, 'role': 'customer'}),
      );
      if (r.statusCode != 200) {
        throw Exception('接続情報の取得に失敗しました（${r.statusCode}）');
      }
      final j = jsonDecode(r.body) as Map;
      final url = j['url'] as String;
      final token = j['token'] as String;

      if (_isCamera) {
        // カメラモード：MediaProjection 不要。前面サービスで維持しつつ背面カメラを publish。
        setState(() => _status = 'カメラの準備をしています…');
        await _enableForegroundService();
        setState(() => _status = 'サーバに接続しています…');
        final room = Room();
        await room.connect(url, token);
        _room = room;
        // REMOHELP PRO: 音声（マイク）も publish して相談員と通話できるようにする。
        //   相談員の声は LiveKit が自動で購読・再生する（Web版と同じ挙動）。
        try {
          await room.localParticipant?.setMicrophoneEnabled(true);
        } catch (_) {
          /* マイク不許可でも映像は続ける */
        }
        final pub = await room.localParticipant?.setCameraEnabled(
          true,
          cameraCaptureOptions: const CameraCaptureOptions(
            cameraPosition: CameraPosition.back,
          ),
        );
        _cameraTrack =
            pub?.track is LocalVideoTrack ? pub!.track as LocalVideoTrack : null;
        if (_cameraTrack != null) await _initPreviewRenderer(_cameraTrack!);
      } else {
        // 画面共有モード（温存・通常はRustDesk一本化で未使用）
        setState(() => _status = '画面共有の許可を確認しています…');
        final ok = await webrtc.Helper.requestCapturePermission();
        if (!ok) throw Exception('画面共有が許可されませんでした。もう一度お試しください。');
        await _enableForegroundService(screen: true);
        setState(() => _status = 'サーバに接続しています…');
        final room = Room();
        await room.connect(url, token);
        _room = room;
        // REMOHELP PRO: 画面共有時もマイクを publish（相談員と通話できる）。
        try {
          await room.localParticipant?.setMicrophoneEnabled(true);
        } catch (_) {
          /* マイク不許可でも共有は続ける */
        }
        await room.localParticipant?.setScreenShareEnabled(true);
      }

      // 相談員からの矢印指示を受信開始
      if (_room != null) _setupDataListener(_room!);

      if (!mounted) return;
      setState(() {
        _live = true;
        _status = _isCamera ? 'カメラ映像を配信中' : '画面共有中';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// カメラ映像の実サイズ（縦持ち/横持ちで入れ替わる）を取得するための自前レンダラ。
  ///   取得できた比率をプレビュー枠の比率に反映し、余白を作らない＝描画座標を一致させる。
  Future<void> _initPreviewRenderer(LocalVideoTrack track) async {
    try {
      final r = webrtc.RTCVideoRenderer();
      await r.initialize();
      r.srcObject = track.mediaStream;
      r.onResize = () {
        final w = r.videoWidth, h = r.videoHeight;
        if (w <= 0 || h <= 0 || !mounted) return;
        final a = w / h;
        if ((a - _videoAspect).abs() > 0.001) {
          setState(() => _videoAspect = a);
        }
      };
      if (!mounted) {
        await r.dispose();
        return;
      }
      setState(() => _previewRenderer = r);
    } catch (_) {
      // 取れなくても VideoTrackRenderer にフォールバックして配信は続ける
    }
  }

  void _disposePreviewRenderer() {
    final r = _previewRenderer;
    _previewRenderer = null;
    if (r == null) return;
    unawaited(() async {
      try {
        r.srcObject = null;
        await r.dispose();
      } catch (_) {}
    }());
  }

  Future<void> _enableForegroundService({bool screen = false}) async {
    final cfg = FlutterBackgroundAndroidConfig(
      notificationTitle: screen ? 'REMOHELP PRO 画面共有中' : 'REMOHELP PRO カメラ配信中',
      notificationText:
          screen ? '担当者があなたの画面を見ています' : '担当者がカメラの映像を見ています',
      notificationImportance: AndroidNotificationImportance.normal,
      notificationIcon:
          const AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
    );
    await FlutterBackground.initialize(androidConfig: cfg);
    await FlutterBackground.enableBackgroundExecution();
  }

  Future<void> _end() async {
    _cameraTrack = null;
    _disposePreviewRenderer();
    try {
      await _room?.disconnect();
    } catch (_) {}
    try {
      if (FlutterBackground.isBackgroundExecutionEnabled) {
        await FlutterBackground.disableBackgroundExecution();
      }
    } catch (_) {}
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    _cameraTrack = null;
    _disposePreviewRenderer();
    _arrowTimer?.cancel();
    _strokeGc?.cancel();
    unawaited(() async {
      try {
        await _dataListener?.dispose();
      } catch (_) {}
      try {
        await _room?.dispose();
      } catch (_) {}
    }());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _live ? Colors.red.shade50 : Colors.teal.shade50,
      appBar: AppBar(
        title: Text(_isCamera ? 'カメラで見せる' : '画面共有'),
        backgroundColor: _live ? Colors.red.shade700 : Colors.teal.shade700,
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
      ),
      body: Stack(
        children: [
          SingleChildScrollView(
        // ★build-27修正：カメラ映像を出している間はスクロールを止める。
        //   スクロールが生きていると、映像の上を指でなぞったとき
        //   「描画」と「縦スクロール」がジェスチャの取り合いになり、
        //   画面が動いて線がずれていた（お客様報告）。
        //   下の maxH で映像に高さ上限を付け、ミュート・終了ボタンまで
        //   1画面に収まるようにしたのでスクロールは不要。
        physics: (_live && _isCamera && _cameraTrack != null)
            ? const NeverScrollableScrollPhysics()
            : null,
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            if (_error != null) ...[
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16, color: Colors.red)),
            ] else ...[
              Icon(
                  _live
                      ? (_isCamera ? Icons.videocam : Icons.screen_share)
                      : Icons.hourglass_top,
                  size: 64,
                  color: _live ? Colors.red.shade700 : Colors.teal),
              const SizedBox(height: 14),
              Text(_status,
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              // カメラ配信中は「いま相談員に見えている映像」を本人にも表示（プライバシー配慮）
              if (_live && _isCamera && _cameraTrack != null) ...[
                const SizedBox(height: 16),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.teal.shade400, width: 2),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        color: Colors.teal.shade700,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        child: const Text('📷 いま相談員に見えている映像',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.bold)),
                      ),
                      // ★build-27修正：映像に高さの上限を付ける。
                      //   以前は幅いっぱい＝縦長映像だと画面からはみ出すほど大きくなり、
                      //   マイクのミュートボタンが下に隠れて押せなかった（お客様報告）。
                      //   幅を基準に高さを出し、上限を超えるときは高さ基準に切り替える。
                      //   ※比率は必ず実映像どおりに保つ（レターボックスを作らないことで、
                      //     枠基準で正規化した座標が相談員側の映像座標と 1:1 で一致する）。
                      LayoutBuilder(builder: (ctx, outer) {
                        final maxH = MediaQuery.of(ctx).size.height * 0.40;
                        var vw = outer.maxWidth;
                        var vh = vw / _videoAspect;
                        if (vh > maxH) {
                          vh = maxH;
                          vw = vh * _videoAspect;
                        }
                        return Center(
                          child: SizedBox(
                            width: vw,
                            height: vh,
                            // REMOHELP PRO: 映像の上に描画レイヤ。
                            //   相談員から届いた線を表示し、指でなぞれば自分の線を送れる。
                            child: LayoutBuilder(
                          builder: (ctx, box) {
                            final w = box.maxWidth;
                            final h = box.maxHeight;
                            Offset norm(Offset local) => Offset(
                                  (local.dx / (w == 0 ? 1 : w)).clamp(0.0, 1.0),
                                  (local.dy / (h == 0 ? 1 : h)).clamp(0.0, 1.0),
                                );
                            return Stack(
                              fit: StackFit.expand,
                              children: [
                                // 自前レンダラが使えるときはそれで描画（fit=Cover・鏡像なし）。
                                //   枠比＝映像比なので Cover でも切れず、余白も出ない。
                                //   ※鏡像は相談員側の見え方とズレるため明示的に無効。
                                if (_previewRenderer != null)
                                  webrtc.RTCVideoView(
                                    _previewRenderer!,
                                    mirror: false,
                                    filterQuality: FilterQuality.medium,
                                    objectFit: webrtc.RTCVideoViewObjectFit
                                        .RTCVideoViewObjectFitCover,
                                  )
                                else
                                  VideoTrackRenderer(
                                    _cameraTrack!,
                                    mirrorMode: VideoViewMirrorMode.off,
                                  ),
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onPanStart: (d) => setState(() =>
                                      _curStroke = [norm(d.localPosition)]),
                                  onPanUpdate: (d) {
                                    if (_curStroke == null) return;
                                    setState(() =>
                                        _curStroke!.add(norm(d.localPosition)));
                                  },
                                  onPanEnd: (_) {
                                    final pts = _curStroke;
                                    setState(() => _curStroke = null);
                                    if (pts != null && pts.length >= 2) {
                                      _addStroke(
                                          pts
                                              .map((o) => <double>[o.dx, o.dy])
                                              .toList(),
                                          mine: true);
                                      _sendDraw(pts);
                                    }
                                  },
                                  child: CustomPaint(
                                    painter:
                                        _StrokePainter(_strokes, _curStroke),
                                  ),
                                ),
                              ],
                            );
                          },
                            ), // 内側 LayoutBuilder（描画レイヤ）
                          ), // SizedBox（映像サイズ確定）
                        ); // Center
                      }), // 外側 LayoutBuilder（高さ上限の計算）
                    ],
                  ),
                ),
              ],
            ],
            // REMOHELP PRO: マイクのオン/オフ。顧客が自分の声を止められるようにする。
            //   配信中のみ表示。オフ時はグレー＋「ミュート中」で状態が一目で分かる。
            if (_live) ...[
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _toggleMic,
                  icon: Icon(_micOn ? Icons.mic : Icons.mic_off, size: 26),
                  label: Text(
                    _micOn ? 'マイク オン（声が届いています）' : 'マイク オフ（ミュート中）',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        _micOn ? Colors.teal.shade600 : Colors.grey.shade600,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 26),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _end,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red.shade600,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                ),
                child: const Text('サポートを終了',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
          if (_arrow != null) _arrowOverlay(),
        ],
      ),
    );
  }

  /// 相談員から届いた「カメラを動かす方向」を、画面いっぱいの大きな矢印で表示。
  Widget _arrowOverlay() {
    IconData icon;
    String label;
    Color iconColor = Colors.yellowAccent;
    Color labelBg = Colors.black87;
    switch (_arrow) {
      case 'up':
        icon = Icons.keyboard_double_arrow_up;
        label = 'カメラを上に向けてください';
        break;
      case 'down':
        icon = Icons.keyboard_double_arrow_down;
        label = 'カメラを下に向けてください';
        break;
      case 'left':
        icon = Icons.keyboard_double_arrow_left;
        label = 'カメラを左に向けてください';
        break;
      case 'right':
        icon = Icons.keyboard_double_arrow_right;
        label = 'カメラを右に向けてください';
        break;
      case 'stop':
        icon = Icons.pan_tool; // ✋
        label = 'そこでOK！止めてください';
        iconColor = Colors.greenAccent;
        labelBg = Colors.green.shade700;
        break;
      default:
        return const SizedBox.shrink();
    }
    return Positioned.fill(
      child: IgnorePointer(
        child: Container(
          color: Colors.black.withOpacity(0.35),
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 160, color: iconColor),
              const SizedBox(height: 12),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  color: labelBg,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(label,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// REMOHELP PRO: カメラ映像に重ねる線（座標は映像に対する 0..1 の正規化）。
class _Stroke {
  final List<Offset> pts;
  final int ts; // 追加時刻(ms)。Web版と同じく8秒で消す。
  final bool mine; // true=自分(顧客) / false=相談員
  const _Stroke(this.pts, this.ts, this.mine);
}

/// Web版と同じ見た目：黒フチ(太8)＋本線(太4)。相談員=黄 / 自分=水色。
class _StrokePainter extends CustomPainter {
  final List<_Stroke> strokes;
  final List<Offset>? current; // なぞっている最中の線（自分）
  const _StrokePainter(this.strokes, this.current);

  void _drawOne(Canvas canvas, Size size, List<Offset> pts, bool mine) {
    if (pts.length < 2) return;
    final path = Path();
    for (var i = 0; i < pts.length; i++) {
      final x = pts[i].dx * size.width;
      final y = pts[i].dy * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 8
      ..color = const Color(0xD9000000);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 4
      ..color = mine ? const Color(0xFF00E5FF) : const Color(0xFFFFE500);
    canvas.drawPath(path, outline);
    canvas.drawPath(path, line);
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in strokes) {
      _drawOne(canvas, size, s.pts, s.mine);
    }
    final cur = current;
    if (cur != null) _drawOne(canvas, size, cur, true);
  }

  @override
  bool shouldRepaint(covariant _StrokePainter old) => true;
}
