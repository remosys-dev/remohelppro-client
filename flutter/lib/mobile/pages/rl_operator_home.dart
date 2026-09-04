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

import 'package:flutter/material.dart';
import 'package:flutter_hbb/remohelppro_endpoints.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../common.dart';
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
