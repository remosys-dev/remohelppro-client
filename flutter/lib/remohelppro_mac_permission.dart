import 'dart:io';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';

/// macOS の許可（画面収録・アクセシビリティ）の案内。
///
/// 🔴🔴 なぜ要るか（2026-08-16 実機で判明）。
///
///   Mac は繋がっても、許可が無いと**映像が出ない・操作できない**。
///   ところが当社のアプリは**許可について一言も出していなかった**。
///   ＝ Mac のお客様は全員ここで止まり、相談員が電話で説明するしかない。
///   実際、「接続完了、画像を待機しています」から進まない状態になった。
///
///   ★お客様の画面に手順を出し、**設定画面を直接開くボタン**まで置く。
///     探させない。macOS はアプリから該当の画面を開ける。
///
/// ⚠ Windows にはこの手間が無い。**macOS だけ**に出す。
/// ⚠ 「終了して開き直す」は macOS が求める。1回で済むよう、
///   2つの許可を**続けて**取ってから開き直していただく。
class MacPermissionCard extends StatelessWidget {
  const MacPermissionCard({super.key, required this.accent});

  final Color accent;

  static bool get shouldShow => Platform.isMacOS;

  /// システム環境設定の該当ページを直接開く。
  /// ⚠ 開けなくても止めない（案内の文だけでも進める）。
  static Future<void> _open(String pane) async {
    try {
      await launchUrlString(
        'x-apple.systempreferences:com.apple.preference.security?$pane',
      );
    } catch (_) {
      // 古い macOS では URL の形が違うことがある。せめて設定を開く。
      try {
        await Process.run('open', ['/System/Library/PreferencePanes/Security.prefPane']);
      } catch (_) {
        /* ここまで駄目なら、下の手順を読んでいただく */
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!shouldShow) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E6),
        border: Border.all(color: const Color(0xFFEFD08A)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Mac をお使いの方へ　画面が映らないときは',
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.bold,
              color: Color(0xFF7A5A12),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Mac は、はじめて使うときだけ「許可」が必要です。'
            '下のボタンから2つとも許可してください。',
            style: TextStyle(fontSize: 13, color: Color(0xFF7A5A12), height: 1.6),
          ),
          const SizedBox(height: 10),
          _Step(
            n: 1,
            title: '画面収録　… 画面を見てもらうために必要です',
            button: '画面収録の設定を開く',
            onTap: () => _open('Privacy_ScreenCapture'),
            accent: accent,
          ),
          const SizedBox(height: 8),
          _Step(
            n: 2,
            title: 'アクセシビリティ　… 操作してもらうために必要です',
            button: 'アクセシビリティの設定を開く',
            onTap: () => _open('Privacy_Accessibility'),
            accent: accent,
          ),
          const SizedBox(height: 10),
          const Text(
            '設定の画面が開いたら、左下の鍵をクリックして解除し、'
            '一覧の「REMOHELP PRO」にチェックを入れてください。',
            style: TextStyle(fontSize: 12.5, color: Color(0xFF7A5A12), height: 1.6),
          ),
          const SizedBox(height: 6),
          // ⚠ ここが抜けると「許可したのに映らない」になる。必ず書く。
          const Text(
            '★ 2つとも許可してから、このアプリを一度閉じて開き直してください。'
            '開き直さないと、許可が効きません。',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.bold,
              color: Color(0xFFB4540A),
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.n,
    required this.title,
    required this.button,
    required this.onTap,
    required this.accent,
  });

  final int n;
  final String title;
  final String button;
  final VoidCallback onTap;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFFB4540A),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Text('$n',
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white)),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF7A5A12))),
              const SizedBox(height: 5),
              SizedBox(
                height: 32,
                child: OutlinedButton(
                  onPressed: onTap,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: accent,
                    side: BorderSide(color: accent),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(7),
                    ),
                  ),
                  child: Text(button, style: const TextStyle(fontSize: 12.5)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
