// REMOHELP PRO: ワンタイム・サポート用ポータブル版フラグ。
// 通常(フリート)ビルド=false(従来どおり画面非表示)。
// サポート版CIで sed により true に書き換える(APP_NAME焼込と同じ流儀・dart-defineより確実)。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'models/platform_model.dart';

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

/// 🔴🔴 Android の「ファイルのやりとりの起点」を、アプリ専用フォルダに定める（2026-08-10）。
///
///   これまで Android では起点が空（＝端末のルート）だった。
///   `main_set_home_dir` はブリッジに用意されているのに、**Dart から一度も
///   呼ばれていなかった**ため。その結果、ファイル送受信には
///   MANAGE_EXTERNAL_STORAGE（全ファイルへのアクセス）が必要になっていた。
///
///   ⚠ その権限は、Google がファイルマネージャ等の決められた用途にしか認めない。
///     遠隔サポートは一覧に無く、Play ストアの審査で最大の論点になる。
///
///   起点をアプリ専用フォルダ（Android/data/<パッケージ>/files/）にすると、
///   **権限がまったく要らないまま**読み書きできる。Rust 側のファイル処理
///   （std::fs / PathBuf。完全にパスで動く）は一行も変えなくてよい。
///
///   ⚠ 引き換えに、相談員はお客様の端末の中を自由に見て回れなくなる。
///     見えるのは「お客様がこのフォルダに置いたもの」と「こちらが送ったもの」だけ。
///     サポートの用途としてはむしろ正しく、同意の説明もしやすい。
///
///   ⚠ このフォルダはお客様も「ファイル」アプリから開ける場所にある。
///     隠し場所ではないので、渡す・取り出すが手作業でもできる。
Future<void> rlSetAndroidTransferDir() async {
  try {
    // Android では getExternalStorageDirectory() が
    //   /storage/emulated/0/Android/data/<パッケージ>/files
    // を返す。権限は要らない。取れなければ端末内部の専用領域に落とす。
    final base = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/REMOHELP PRO');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    await bind.mainSetHomeDir(home: dir.path);
    debugPrint('RL: ファイルのやりとりの起点 = ${dir.path}');
  } catch (e) {
    // ⚠ ここで失敗しても起動は止めない。起点が空のままになるだけで、
    //   ファイル送受信が使えないだけ。サポート本体（画面共有・遠隔操作）は動く。
    debugPrint('RL: やりとりの起点を作れませんでした: $e');
  }
}
