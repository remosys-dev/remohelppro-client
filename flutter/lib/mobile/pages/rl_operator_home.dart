// REMOHELP PRO: 相談員アプリ(Android)の待ち受け画面。
//
// 🔴 なぜ RustDesk 本来の接続画面(ConnectionPage)を出さないか（2026-08-25 ご指示）
//   ① スマートフォンでは、相談員画面の一覧から「▶ 接続」を押して
//      このアプリを起動する運びにしてある。IDを手で打つ場面が無い。
//   ② ⚠ 本来の画面には**過去につないだ端末の一覧が残る**。
//      会社をまたいで端末名（例: 常駐PCのホスト名）が並ぶため、
//      台帳の外で他社の端末が見えてしまう。
//   ③ パソコン版でも本体の窓は開けないようにした。スマホだけ開くのはちぐはぐ。
//
// ⚠ 行き止まりにしない。管理画面へ戻る道をこの画面に必ず置くこと。
//   遠隔が終わるとここに戻ってくるので、次の1台へ進む入口でもある。

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/remohelppro_endpoints.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../common.dart';
import '../../models/platform_model.dart';
import 'home_page.dart';

/// 相談員画面（この一覧の「▶ 接続」からアプリが起動する）。
const String kRlOperatorConsoleUrl = '$kRlApiBase/op/devices';

class RlOperatorHomePage extends StatelessWidget implements PageShape {
  const RlOperatorHomePage({Key? key}) : super(key: key);

  @override
  String get title => 'REMOHELP PRO';

  @override
  Widget get icon => const Icon(Icons.support_agent);

  // ⚠ 相談員に技術設定は出さない（顧客版と同じ扱い）。
  @override
  List<Widget> get appBarActions => const <Widget>[];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // 🔴 新しい版が出ていたら知らせる帯（2026-10-15 社長のご指示）。
              //   更新が無いとき・分からないときは何も出さない（高さ0）。
              const _UpdateBanner(),
              Icon(Icons.support_agent,
                  size: 72, color: MyTheme.accent),
              const SizedBox(height: 20),
              const Text(
                '相談員画面から接続します',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              const Text(
                '常駐PCの一覧で「▶ 接続」を押すと、このアプリが開いて遠隔操作が始まります。\n'
                'このアプリから相手の番号を入力する必要はありません。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, height: 1.6),
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => launchUrl(
                    Uri.parse(kRlOperatorConsoleUrl),
                    // ⚠ アプリ内ブラウザだと intent:// が拾われず、
                    //   「▶ 接続」を押しても何も起きない。既定のブラウザで開く。
                    mode: LaunchMode.externalApplication,
                  ),
                  icon: const Icon(Icons.open_in_new),
                  label: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('相談員画面をひらく', style: TextStyle(fontSize: 16)),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                '遠隔が終わると、この画面に戻ります。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 新しい版が出ていたら知らせる帯（2026-10-15 社長のご指示）。
///
/// 🔴 なぜ要るか
///   相談員アプリが**古いまま**だと、正しい認証コードでも
///   「認証コードが違うか、有効期限が切れています」になって接続できない
///   （古い版のサーバー呼び出しが、今のサーバーと食い違うため）。
///   ⚠ しかも当社アプリは RustDesk 由来の更新チェックが isCustomClient で
///     切られているので、**更新があっても気づけなかった**。
///   ★起動時にサーバーへ「最新版」を聞き、自分の版と違えば帯を出す。
///
/// ⚠ 安全側に倒す：分からないとき（オフライン・版が読めない・入手先が無い）は
///   **何も出さない**。誤って毎回「更新あり」と出す方が害が大きい。
/// ⚠ 版の比較は**一致するかだけ**（大小は見ない。1.4.9 と 1.4.10 の順が狂うため）。
/// ⚠ 「あとで」で閉じると、このアプリを開いている間は再び出さない
///   （閉じても次に開いたときにまた確かめる＝しつこすぎない）。
class _UpdateBanner extends StatefulWidget {
  const _UpdateBanner();

  @override
  State<_UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<_UpdateBanner> {
  String? _latest; // サーバーが配っている最新版
  String? _mine; // いま動いているこのアプリの版
  String? _url; // 更新の入手先（絶対URL）
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    // Android の相談員アプリだけ。分からなければ黙る。
    if (!isAndroid) return;
    try {
      final mine = (await bind.mainGetVersion()).trim();
      if (mine.isEmpty) return;
      final res = await http
          .get(Uri.parse(
              '$kRlApiBase/api/app/latest?product=operator&platform=android'))
          .timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return;
      final j = jsonDecode(res.body) as Map;
      final latest = ((j['version'] as String?) ?? '').trim();
      final path = (j['url'] as String?) ?? '';
      // 版が同じ／どちらか不明／入手先が無いなら出さない。
      if (latest.isEmpty || path.isEmpty || latest == mine) return;
      if (!mounted) return;
      setState(() {
        _mine = mine;
        _latest = latest;
        // url は相対で返る。自分の接続先に継ぎ足して開く。
        _url = path.startsWith('http') ? path : '$kRlApiBase$path';
      });
    } catch (_) {
      // オフライン等。黙る（誤って「更新あり」と出さない）。
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_latest == null || _url == null || _dismissed) {
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4E5), // 薄い橙（注意だが強すぎない）
        border: Border.all(color: const Color(0xFFFFB74D)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '新しい版の相談員アプリがあります',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
          const SizedBox(height: 4),
          Text(
            '最新 $_latest ／ お使い $_mine',
            style: const TextStyle(fontSize: 13, color: Colors.black87),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              ElevatedButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse(_url!),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.system_update, size: 18),
                label: const Text('更新する'),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => setState(() => _dismissed = true),
                child: const Text('あとで'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
