// アプリ内に「常駐を許可する」を出す。
//
// 🔴 なぜアプリ側に要るか（2026-07-27 実機で判明）:
//   許可ボタンはブラウザの顧客ページにしか実装していなかった。
//   しかしお客様が**専用アプリで接続している場合、そのページを見ていない**。
//   ＝ 相談員が「常駐にする」を押しても、お客様側には何も出ず、常駐にできなかった。
//   遠隔操作は常にアプリ経由なので、実運用ではこちらが本流になる。
//
// 動線（ユーザー確定）:
//   ① 相談員が「常駐にする」を押す
//   ② ここに「常駐を許可する」が出る ← お客様の操作はこの1回だけ
//   ③ 許可すると、常駐プログラムの取得が可能になる
//   ④ 相談員が遠隔操作で導入する（既に操作できているので手間をかけない）
//
// 🔴 許可の前はダウンロードできない。勝手に入れられない歯止め。

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher_string.dart';

/// 常駐化の進み具合。サーバーの residentStage と同じ言葉を使う。
enum ResidentStage { none, requested, consented, expired, installed }

ResidentStage _parse(String? s) {
  switch (s) {
    case 'requested':
      return ResidentStage.requested;
    case 'consented':
      return ResidentStage.consented;
    case 'expired':
      return ResidentStage.expired;
    case 'installed':
      return ResidentStage.installed;
    default:
      return ResidentStage.none;
  }
}

/// 相談員からの常駐化の依頼を見張り、来ていれば許可ボタンを出す。
class RemohelpproResidentCard extends StatefulWidget {
  const RemohelpproResidentCard({
    Key? key,
    required this.apiBase,
    required this.shortId,
  }) : super(key: key);

  final String apiBase;
  final String shortId;

  @override
  State<RemohelpproResidentCard> createState() =>
      _RemohelpproResidentCardState();
}

class _RemohelpproResidentCardState extends State<RemohelpproResidentCard> {
  Timer? _poll;
  ResidentStage _stage = ResidentStage.none;
  String? _operatorName;
  String? _token; // 平文はここでしか受け取れない
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _check();
    // 相談員が押してから出るまでの間が空くと、電話口で「まだ出ませんか」に
    // なるので短めに見に行く。通信量は僅か。
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => _check());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    try {
      final r = await http
          .get(Uri.parse(
              '${widget.apiBase}/api/customer/resident-consent?shortId=${widget.shortId}'))
          .timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return;
      final j = jsonDecode(r.body) as Map;
      if (!mounted) return;
      setState(() {
        _stage = _parse(j['stage'] as String?);
        _operatorName = j['operatorName'] as String?;
      });
    } catch (_) {
      // 一時的な通信エラーは無視（次の tick で再確認）
    }
  }

  Future<void> _consent() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await http
          .post(
            Uri.parse('${widget.apiBase}/api/customer/resident-consent'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'shortId': widget.shortId}),
          )
          .timeout(const Duration(seconds: 12));
      final j = jsonDecode(r.body) as Map;
      if (r.statusCode == 200 && j['ok'] == true) {
        if (!mounted) return;
        setState(() {
          _token = j['token'] as String?;
          _stage = ResidentStage.consented;
        });
      } else {
        if (!mounted) return;
        setState(() => _error = '許可を受け付けられませんでした。担当者にお伝えください。');
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '通信に失敗しました。もう一度お試しください。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download() async {
    final t = _token;
    if (t == null) return;
    final url =
        '${widget.apiBase}/download/remohelppro-resident-setup.exe?c=${Uri.encodeComponent(t)}';
    try {
      await launchUrlString(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'ダウンロードを開けませんでした。担当者にお伝えください。');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 依頼が来ていない／導入済みなら何も出さない。
    if (_stage == ResidentStage.none || _stage == ResidentStage.installed) {
      return const SizedBox.shrink();
    }

    // 常駐は今のところ Windows のみ。押せないボタンは出さず、正直に伝える。
    if (!Platform.isWindows) {
      return _box(
        color: const Color(0xFFF3F4F6),
        border: const Color(0xFFD1D5DB),
        children: [
          const Text('常駐のご案内',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          const SizedBox(height: 6),
          const Text('この端末は常駐の対象外です（現在は Windows のみ）。担当者にお伝えください。',
              style: TextStyle(fontSize: 13)),
        ],
      );
    }

    if (_stage == ResidentStage.expired) {
      return _box(
        color: const Color(0xFFF3F4F6),
        border: const Color(0xFFD1D5DB),
        children: const [
          Text('有効期限が切れました。担当者にお伝えください。',
              style: TextStyle(fontSize: 13)),
        ],
      );
    }

    if (_stage == ResidentStage.consented) {
      return _box(
        color: const Color(0xFFECFDF5),
        border: const Color(0xFF34D399),
        children: [
          const Text('ありがとうございます。担当者がこのまま導入します。',
              style: TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF065F46))),
          const SizedBox(height: 10),
          if (_token != null)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _download,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF047857),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: const Text('⬇ 常駐プログラムをダウンロード',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              ),
            )
          else
            const Text('ダウンロードの準備をやり直します。担当者に「もう一度お願いします」とお伝えください。',
                style: TextStyle(fontSize: 12, color: Color(0xFF92400E))),
          const SizedBox(height: 6),
          const Text('このボタンは担当者が押します。お客様の操作は不要です。',
              style: TextStyle(fontSize: 11, color: Color(0xFF065F46))),
        ],
      );
    }

    // requested：お客様に押していただく唯一の場面
    return _box(
      color: const Color(0xFFFFFBEB),
      border: const Color(0xFFFBBF24),
      children: [
        const Text('次回から、お電話なしで接続できるようにします',
            style: TextStyle(
                fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF78350F))),
        const SizedBox(height: 8),
        Text(
          '${_operatorName ?? "担当者"}がこのパソコンに常駐プログラムの導入をお願いしています。',
          style: const TextStyle(fontSize: 13, color: Color(0xFF78350F)),
        ),
        const SizedBox(height: 6),
        const Text(
          '・次回から、認証コードの入力なしでサポートを受けられます\n'
          '・許可のあとの導入作業は、担当者がこのまま行います\n'
          '・導入しても、会社のご担当者が承認するまで誰も接続できません',
          style: TextStyle(fontSize: 12, color: Color(0xFF92400E), height: 1.5),
        ),
        if (_error != null) ...[
          const SizedBox(height: 6),
          Text(_error!,
              style: const TextStyle(fontSize: 12, color: Color(0xFFB91C1C))),
        ],
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _busy ? null : _consent,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFD97706),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: Text(_busy ? '送信中…' : '常駐を許可する',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          ),
        ),
      ],
    );
  }

  Widget _box({
    required Color color,
    required Color border,
    required List<Widget> children,
  }) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color,
        border: Border.all(color: border, width: 2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }
}
