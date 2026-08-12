// 🔴🔴 ファイルの受け渡し（2026-08-12 追加）。
//
//   全ファイルへのアクセス権（MANAGE_EXTERNAL_STORAGE）を外したことで、
//   相談員はお客様の端末の中を自由に見て回れなくなった。
//   代わりに「受け渡し用のフォルダ」1つだけを共有する。
//
//     お客様 → 相談員 : ここで選んだファイルだけが相手から見える
//     相談員 → お客様 : 届いたファイルをここから開く／送る
//
//   ⚠ Android 11 以降、このフォルダはお客様が「ファイル」アプリから開けない。
//     この画面が唯一の出入口になる。無いと、届いたものを取り出せない。
//   ⚠ file_picker の saveFile() は Android 未実装なので、
//     取り出しは端末の標準の仕組み（開く／送る）へ渡す。
import 'dart:io';

import 'package:flutter/material.dart';

import '../../rl_support.dart';

class RlTransferCard extends StatefulWidget {
  const RlTransferCard({Key? key}) : super(key: key);

  @override
  State<RlTransferCard> createState() => _RlTransferCardState();
}

class _RlTransferCardState extends State<RlTransferCard> {
  List<FileSystemEntity> _files = [];
  bool _busy = false;
  bool _open = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final f = await rlTransferFiles();
    if (mounted) setState(() => _files = f);
  }

  Future<void> _pick() async {
    if (_busy) return;
    setState(() => _busy = true);
    final n = await rlPickFilesIntoTransfer();
    await _reload();
    if (mounted) {
      setState(() => _busy = false);
      _toast(n > 0 ? '$n 件を渡せるようにしました' : 'ファイルは選ばれませんでした');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  String _size(File f) {
    try {
      final b = f.lengthSync();
      if (b < 1024) return '$b B';
      if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
      return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    // 受け渡しフォルダが用意できていない端末では、何も出さない。
    if (rlTransferDirPath == null) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
              child: Row(
                children: [
                  const Icon(Icons.folder_shared_outlined, size: 22),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'ファイルの受け渡し',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (_files.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary.withOpacity(0.14),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '${_files.length}',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                      ),
                    ),
                  Icon(_open ? Icons.expand_less : Icons.expand_more),
                ],
              ),
            ),
          ),
          if (_open) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
              child: Text(
                'ここに入れたファイルだけが、担当者から見えます。\n'
                '担当者から届いたファイルも、ここに並びます。',
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.6,
                  color: Theme.of(context).hintColor,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
              child: ElevatedButton.icon(
                onPressed: _busy ? null : _pick,
                icon: const Icon(Icons.add, size: 19),
                label: Text(_busy ? '取り込んでいます…' : '渡すファイルを選ぶ'),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                ),
              ),
            ),
            if (_files.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                child: Text(
                  'まだ何もありません。',
                  style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor),
                ),
              )
            else
              ..._files.map((e) {
                final f = File(e.path);
                final name = e.path.split('/').last;
                return Column(
                  children: [
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  name,
                                  style: const TextStyle(fontSize: 13.5),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  _size(f),
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: Theme.of(context).hintColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: '開く',
                            icon: const Icon(Icons.open_in_new, size: 21),
                            onPressed: () async {
                              final ok = await rlOpenTransferFile(e.path);
                              if (!ok) _toast('開けるアプリが見つかりませんでした');
                            },
                          ),
                          IconButton(
                            tooltip: '保存・送る',
                            icon: const Icon(Icons.ios_share, size: 21),
                            onPressed: () async {
                              final ok = await rlOpenTransferFile(e.path, share: true);
                              if (!ok) _toast('送れるアプリが見つかりませんでした');
                            },
                          ),
                          IconButton(
                            tooltip: '消す',
                            icon: const Icon(Icons.delete_outline, size: 21),
                            onPressed: () async {
                              try {
                                await f.delete();
                              } catch (_) {}
                              await _reload();
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              }),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 2, 14, 12),
              child: TextButton.icon(
                onPressed: _reload,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('一覧を更新'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
