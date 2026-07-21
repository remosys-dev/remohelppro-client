// REMOHELP PRO: ワンタイム・サポート用ポータブル版フラグ。
// 通常(フリート)ビルド=false(従来どおり画面非表示)。
// サポート版CIで sed により true に書き換える(APP_NAME焼込と同じ流儀・dart-defineより確実)。
import 'package:flutter/material.dart';

const bool kRlSupportShowWindow = false;

/// REMOHELP PRO チェーンリンク ロゴ。
/// ワンタイム版のタイトルバー/入力画面で「R」の代わりに使い、フリート版と区別する。
Widget rlChainLogo(double size) =>
    SizedBox(width: size, height: size, child: const CustomPaint(painter: RlChainLinkPainter()));

class RlChainLinkPainter extends CustomPainter {
  const RlChainLinkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    // viewBox 0 0 64 64 を size に拡大 (正方形前提・幅基準)
    final s = size.width / 64.0;
    final rect = Offset.zero & size;
    final shader = const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF0D9488), Color(0xFF22D3EE)],
    ).createShader(rect);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5 * s
      ..shader = shader;
    final fill = Paint()
      ..style = PaintingStyle.fill
      ..shader = shader;
    canvas.drawRRect(
        RRect.fromLTRBR(10 * s, 22 * s, 36 * s, 42 * s, Radius.circular(10 * s)), stroke);
    canvas.drawRRect(
        RRect.fromLTRBR(28 * s, 22 * s, 54 * s, 42 * s, Radius.circular(10 * s)), stroke);
    canvas.drawCircle(Offset(10 * s, 32 * s), 4.5 * s, fill);
    canvas.drawCircle(Offset(54 * s, 32 * s), 4.5 * s, fill);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
