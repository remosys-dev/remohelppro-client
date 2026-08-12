// REMOHELP PRO: ワンタイム・サポート用ポータブル版フラグ。
// 通常(フリート)ビルド=false(従来どおり画面非表示)。
// サポート版CIで sed により true に書き換える(APP_NAME焼込と同じ流儀・dart-defineより確実)。
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'common.dart';
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
    rlTransferDirPath = dir.path;
    debugPrint('RL: ファイルのやりとりの起点 = ${dir.path}');
  } catch (e) {
    // ⚠ ここで失敗しても起動は止めない。起点が空のままになるだけで、
    //   ファイル送受信が使えないだけ。サポート本体（画面共有・遠隔操作）は動く。
    debugPrint('RL: やりとりの起点を作れませんでした: $e');
  }
}

/// 🔴🔴 受け渡しフォルダの置き場所（2026-08-12）。
///   rlSetAndroidTransferDir() が作ったフォルダを、あとから何度でも引ける。
String? rlTransferDirPath;

/// 受け渡しフォルダの中身（新しい順）。
Future<List<FileSystemEntity>> rlTransferFiles() async {
  final p = rlTransferDirPath;
  if (p == null) return [];
  try {
    final d = Directory(p);
    if (!await d.exists()) return [];
    final list = await d.list().where((e) => e is File).toList();
    list.sort((a, b) {
      try {
        return b.statSync().modified.compareTo(a.statSync().modified);
      } catch (_) {
        return 0;
      }
    });
    return list;
  } catch (e) {
    debugPrint('RL: 受け渡しフォルダを読めません: $e');
    return [];
  }
}

/// お客様が「送るファイルを選ぶ」。
///
///   ⚠ 全ファイルへのアクセス権は使わない。端末の標準の選択画面（SAF）で
///     お客様が選んだものだけを、受け渡しフォルダへ複製する。
///     ＝ 相談員から見えるのは「お客様が渡すと決めたもの」だけ。
///   戻り値は入れられた数。
Future<int> rlPickFilesIntoTransfer() async {
  final dir = rlTransferDirPath;
  if (dir == null) return 0;
  try {
    final res = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (res == null) return 0;
    var n = 0;
    for (final f in res.files) {
      final src = f.path;
      if (src == null) continue;
      // 同じ名前があれば上書きしない（お客様が前に渡した物を消さない）
      var name = f.name;
      var dst = File('$dir/$name');
      var i = 1;
      while (await dst.exists()) {
        final dot = name.lastIndexOf('.');
        final base = dot > 0 ? name.substring(0, dot) : name;
        final ext = dot > 0 ? name.substring(dot) : '';
        dst = File('$dir/$base ($i)$ext');
        i++;
      }
      await File(src).copy(dst.path);
      n++;
    }
    return n;
  } catch (e) {
    debugPrint('RL: ファイルを取り込めません: $e');
    return 0;
  }
}

/// 受け取ったファイルを端末の標準の仕組みへ渡す（開く / 送る）。
///
///   ⚠ Android 11 以降、アプリ専用フォルダは「ファイル」アプリから開けない。
///     ここを通さないと、相談員が送ったファイルを永久に取り出せない。
///   ⚠ file_picker の saveFile() は Android 未実装なので使えない。
Future<bool> rlOpenTransferFile(String path, {bool share = false}) async {
  try {
    final r = await gFFI.invokeMethod(
        share ? 'rl_share_file' : 'rl_open_file', {'path': path});
    return r == true;
  } catch (e) {
    debugPrint('RL: ファイルを開けません: $e');
    return false;
  }
}
