// original cm window in Sciter version.

import 'dart:async';
import 'package:flutter_hbb/remohelppro_trace.dart' show rlTrace;
// 顧客版の「切断」で、本体へ終了の合図を置くのに使う。
import 'dart:io' show Directory, File, Platform;
import 'package:flutter_hbb/rl_support.dart' show kRlSupportShowWindow;
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/audio_input.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/models/chat_model.dart';
import 'package:flutter_hbb/models/cm_file_model.dart';
import 'package:flutter_hbb/utils/platform_channel.dart';
import 'package:get/get.dart';
import 'package:percent_indicator/linear_percent_indicator.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../common.dart';
// 「×」で接続を切らず、窓を隠すだけにするために使う（2026-09-01）。
import '../../main.dart' show hideCmWindow;
import '../../common/widgets/chat_page.dart';
import '../../models/file_model.dart';
import '../../models/platform_model.dart';
import '../../models/server_model.dart';

/// 🔴🔴 **お客様の画面に出す名前**（2026-09-01 ご判断）。
///
///   ⚠ ここに出ていたのは `client.name` ＝**相談員PCの Windows ユーザー名**
///     （実機で確認済み）。⚠ お客様には意味が分からず、
///     ⚠ 「誰が私のPCを触っているのか」の答えになっていなかった。
///   ★左のカードと**同じ会社名**を出す。会社ごとに変わっても必ず一致する。
///   ⚠ 取れないときは空を返す。呼ぶ側は従来どおりの表示に戻る（壊さない）。
/// 常駐版かどうか。
///
/// 🔴 判定は**実行ファイル名**（`remohelppro-agent`）。
///   ⚠ 名前で見分けるのは本来よくない（3製品で名前がぶつかる事故を何度も
///     起こしている）が、⚠ **常駐だけは APP_NAME ごと分けてある**ので、
///     ここは名前が正しい見分けになる。`remohelppro_pairing.dart` の
///     `_isResidentBuild` と同じ流儀。
/// ⚠ ワンタイム版は目印ファイルで見分ける（名前ではない）。混同しないこと。
bool rlIsResidentBuild() {
  if (!Platform.isWindows) return false;
  try {
    return Platform.resolvedExecutable
        .toLowerCase()
        .contains('remohelppro-agent');
  } catch (_) {
    return false;
  }
}

String rlSupportCompanyName() {
  try {
    return bind.mainGetLocalOption(key: 'rl-support-company').trim();
  } catch (_) {
    return '';
  }
}

class DesktopServerPage extends StatefulWidget {
  const DesktopServerPage({Key? key}) : super(key: key);

  @override
  State<DesktopServerPage> createState() => _DesktopServerPageState();
}

class _DesktopServerPageState extends State<DesktopServerPage>
    with WindowListener, AutomaticKeepAliveClientMixin {
  final tabController = gFFI.serverModel.tabController;

  _DesktopServerPageState() {
    gFFI.ffiModel.updateEventListener(gFFI.sessionId, "");
    Get.put<DesktopTabController>(tabController);
    tabController.onRemoved = (_, id) {
      onRemoveId(id);
    };
  }

  @override
  void initState() {
    windowManager.addListener(this);
    super.initState();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() {
    // 🔴🔴 **「×」で接続を切らない**（2026-09-01 ご判断「A案」）。
    //
    //   ⚠ ご質問「× 押したらサポート終了されないよね？」
    //     → ⚠ **切れていました。**`closeAll()` が繋がっている接続を全部閉じる。
    //   ⚠ しかも中途半端: ⚠ **サーバーには終了が伝わらず、合言葉も無効にならない。**
    //     ＝ コンソールは「対応中」のまま、接続だけ切れる。
    //
    //   ⚠ 同じ日に「切断」の釦を消して「終了する」に一本化すると決めた。
    //     ⚠ ところが「×」が**実質「切断」と同じ働き**をしていた。
    //     ＝ ⚠ 消した釦が「×」の形で残ってしまう。
    //   ★「×」は**隠すだけ**にする。⚠ 止める道は「終了する」1つ。
    //   ⚠ 窓を出し直す道は残る（音声通話の着信・自分の画面を見せる で自動で出る）。
    hideCmWindow();
    // ⚠ super は呼ばない。呼ぶと窓が閉じる（＝プロセスが終わる）。
  }

  void onRemoveId(String id) {
    if (tabController.state.value.tabs.isEmpty) {
      windowManager.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: gFFI.serverModel),
        ChangeNotifierProvider.value(value: gFFI.chatModel),
      ],
      child: Consumer<ServerModel>(
        builder: (context, serverModel, child) {
          final body = Scaffold(
            backgroundColor: Theme.of(context).colorScheme.background,
            body: ConnectionManager(),
          );
          return isLinux
              ? buildVirtualWindowFrame(context, body)
              : workaroundWindowBorder(
                  context,
                  Container(
                    decoration: BoxDecoration(
                        border:
                            Border.all(color: MyTheme.color(context).border!)),
                    child: body,
                  ));
        },
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;
}

class ConnectionManager extends StatefulWidget {
  @override
  State<StatefulWidget> createState() => ConnectionManagerState();
}

class ConnectionManagerState extends State<ConnectionManager>
    with WidgetsBindingObserver {
  final RxBool _controlPageBlock = false.obs;
  final RxBool _sidePageBlock = false.obs;

  ConnectionManagerState() {
    gFFI.serverModel.tabController.onSelected = (client_id_str) {
      final client_id = int.tryParse(client_id_str);
      if (client_id != null) {
        final client =
            gFFI.serverModel.clients.firstWhereOrNull((e) => e.id == client_id);
        if (client != null) {
          gFFI.chatModel.changeCurrentKey(MessageKey(client.peerId, client.id));
          if (client.unreadChatMessageCount.value > 0) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              client.unreadChatMessageCount.value = 0;
              gFFI.chatModel.showChatPage(MessageKey(client.peerId, client.id));
            });
          }
          // ⚠ 会社名があればそれを出す（相談員PCのユーザー名を出さない）。
          final co = rlSupportCompanyName();
          windowManager.setTitle(
              co.isNotEmpty ? co : getWindowNameWithId(client.peerId));
          gFFI.cmFileModel.updateCurrentClientId(client.id);
        }
      }
    };
    gFFI.chatModel.isConnManager = true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      if (!allowRemoteCMModification()) {
        shouldBeBlocked(_controlPageBlock, null);
        shouldBeBlocked(_sidePageBlock, null);
      }
    }
  }

  @override
  void initState() {
    gFFI.serverModel.updateClientState();
    // 🔴 窓のタイトルも会社名にする（2026-09-01 ご指摘・2回目）。
    //   ⚠ 前回はタブを選んだときだけ直していた。⚠ 相手が1人のときは
    //     その道を通らないので、⚠ **タイトルだけ古い名前のまま**だった。
    //   ★窓が開いた時点で必ず入れる。⚠ 取れなければ何もしない（壊さない）。
    try {
      final co = rlSupportCompanyName();
      if (co.isNotEmpty) windowManager.setTitle(co);
    } catch (_) {}
    WidgetsBinding.instance.addObserver(this);
    super.initState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final serverModel = Provider.of<ServerModel>(context);
    pointerHandler(PointerEvent e) {
      if (serverModel.cmHiddenTimer != null) {
        serverModel.cmHiddenTimer!.cancel();
        serverModel.cmHiddenTimer = null;
        debugPrint("CM hidden timer has been canceled");
      }
    }

    return serverModel.clients.isEmpty
        ? Column(
            children: [
              buildTitleBar(),
              Expanded(
                child: Center(
                  child: Text(translate("Waiting")),
                ),
              ),
            ],
          )
        : Listener(
            onPointerDown: pointerHandler,
            onPointerMove: pointerHandler,
            child: DesktopTab(
              showTitle: false,
              showMaximize: false,
              showMinimize: true,
              showClose: true,
              onWindowCloseButton: handleWindowCloseButton,
              controller: serverModel.tabController,
              selectedBorderColor: MyTheme.accent,
              maxLabelWidth: 100,
              tail: null, //buildScrollJumper(),
              tabBuilder: (key, icon, label, themeConf) {
                final client = serverModel.clients
                    .firstWhereOrNull((client) => client.id.toString() == key);
                return Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Tooltip(
                        message: key,
                        waitDuration: Duration(seconds: 1),
                        child: label),
                    unreadMessageCountBuilder(client?.unreadChatMessageCount)
                        .marginOnly(left: 4),
                  ],
                );
              },
              pageViewBuilder: (pageView) => LayoutBuilder(
                builder: (context, constrains) {
                  var borderWidth = 0.0;
                  if (constrains.maxWidth >
                      kConnectionManagerWindowSizeClosedChat.width) {
                    borderWidth = kConnectionManagerWindowSizeOpenChat.width -
                        constrains.maxWidth;
                  } else {
                    borderWidth = kConnectionManagerWindowSizeClosedChat.width -
                        constrains.maxWidth;
                  }
                  if (borderWidth < 0 || borderWidth > 50) {
                    borderWidth = 0;
                  }
                  final realClosedWidth =
                      kConnectionManagerWindowSizeClosedChat.width -
                          borderWidth;
                  final realChatPageWidth =
                      constrains.maxWidth - realClosedWidth;
                  final row = Row(children: [
                    if (constrains.maxWidth >
                        kConnectionManagerWindowSizeClosedChat.width)
                      Consumer<ChatModel>(
                          builder: (_, model, child) => SizedBox(
                                width: realChatPageWidth,
                                child: allowRemoteCMModification()
                                    ? buildSidePage()
                                    : buildRemoteBlock(
                                        child: buildSidePage(),
                                        block: _sidePageBlock,
                                        mask: true),
                              )),
                    SizedBox(
                        width: realClosedWidth,
                        child: SizedBox(
                            width: realClosedWidth,
                            child: allowRemoteCMModification()
                                ? pageView
                                : buildRemoteBlock(
                                    child: _buildKeyEventBlock(pageView),
                                    block: _controlPageBlock,
                                    mask: false,
                                  ))),
                  ]);
                  return Container(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    child: row,
                  );
                },
              ),
            ),
          );
  }

  Widget buildSidePage() {
    final selected = gFFI.serverModel.tabController.state.value.selected;
    if (selected < 0 || selected >= gFFI.serverModel.clients.length) {
      return Offstage();
    }
    final clientType = gFFI.serverModel.clients[selected].type_();
    if (clientType == ClientType.file) {
      return _FileTransferLogPage();
    } else {
      return ChatPage(type: ChatPageType.desktopCM);
    }
  }

  Widget _buildKeyEventBlock(Widget child) {
    return ExcludeFocus(child: child, excluding: true);
  }

  Widget buildTitleBar() {
    return SizedBox(
      height: kDesktopRemoteTabBarHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const _AppIcon(),
          Expanded(
            child: GestureDetector(
              onPanStart: (d) {
                windowManager.startDragging();
              },
              child: Container(
                color: Theme.of(context).colorScheme.background,
              ),
            ),
          ),
          const SizedBox(
            width: 4.0,
          ),
          const _CloseButton()
        ],
      ),
    );
  }

  Widget buildScrollJumper() {
    final offstage = gFFI.serverModel.clients.length < 2;
    final sc = gFFI.serverModel.tabController.state.value.scrollController;
    return Offstage(
        offstage: offstage,
        child: Row(
          children: [
            ActionIcon(
                icon: Icons.arrow_left, iconSize: 22, onTap: sc.backward),
            ActionIcon(
                icon: Icons.arrow_right, iconSize: 22, onTap: sc.forward),
          ],
        ));
  }

  Future<bool> handleWindowCloseButton() async {
    var tabController = gFFI.serverModel.tabController;
    final connLength = tabController.length;
    if (connLength <= 1) {
      windowManager.close();
      return true;
    } else {
      final bool res;
      if (!option2bool(kOptionEnableConfirmClosingTabs,
          bind.mainGetLocalOption(key: kOptionEnableConfirmClosingTabs))) {
        res = true;
      } else {
        res = await closeConfirmDialog();
      }
      if (res) {
        windowManager.close();
      }
      return res;
    }
  }
}

Widget buildConnectionCard(Client client) {
  return Consumer<ServerModel>(
    builder: (context, value, child) => Column(
      mainAxisAlignment: MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.start,
      key: ValueKey(client.id),
      children: [
        _CmHeader(client: client),
        // 相談員が画面に印をつけているときは必ず知らせる。黙って線が出ることはない。
        if (client.remoteDrawing && !client.disconnected)
          _RemoteDrawingNotice(client: client),
        // v1.4.6-13: Phase 4 P3 - リスト長の縦溢れ対策に Flexible で包む
        client.type_() == ClientType.file ||
                client.type_() == ClientType.portForward ||
                client.type_() == ClientType.terminal ||
                client.disconnected
            ? Offstage()
            : Flexible(child: _PrivilegeBoard(client: client)),
        Expanded(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: _CmControlPanel(client: client),
          ),
        )
      ],
    ).paddingSymmetric(vertical: 4.0, horizontal: 8.0),
  );
}

class _AppIcon extends StatelessWidget {
  const _AppIcon({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.symmetric(horizontal: 4.0),
      child: loadIcon(30),
    );
  }
}

class _CloseButton extends StatelessWidget {
  const _CloseButton({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: () {
        windowManager.close();
      },
      icon: const Icon(
        IconFont.close,
        size: 18,
      ),
      splashColor: Colors.transparent,
      hoverColor: Colors.transparent,
    );
  }
}

class _CmHeader extends StatefulWidget {
  final Client client;

  const _CmHeader({Key? key, required this.client}) : super(key: key);

  @override
  State<_CmHeader> createState() => _CmHeaderState();
}

class _CmHeaderState extends State<_CmHeader>
    with AutomaticKeepAliveClientMixin {
  Client get client => widget.client;

  final _time = 0.obs;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(Duration(seconds: 1), (_) {
      if (client.authorized && !client.disconnected) {
        _time.value = _time.value + 1;
      }
    });
    // Call onSelected in post frame callback, since we cannot guarantee that the callback will not call setState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      gFFI.serverModel.tabController.onSelected?.call(client.id.toString());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10.0),
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          // v1.4.6-13: Phase 4 - REMOHELP PRO ブランドカラー (シアン → ディープブルー)
          // RustDesk 元: 0xff00bfe1 → 0xff0071ff (シアン → 標準ブルー)
          colors: [
            Color(0xff06b6d4),
            Color(0xff1e40af),
          ],
        ),
      ),
      margin: EdgeInsets.symmetric(horizontal: 5.0, vertical: 10.0),
      padding: EdgeInsets.only(
        top: 10.0,
        bottom: 10.0,
        left: 10.0,
        right: 5.0,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildClientAvatar().marginOnly(right: 10.0),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 🔴 会社名を出す（2026-09-01 ご判断）。
                //   ⚠ ここに出ていたのは相談員PCの Windows ユーザー名。
                //     ★左のカードと**同じ会社名**にする。取れなければ従来どおり。
                // 🔴🔴 **相談員が名乗った会社名を最優先にする**（2026-09-03）。
                //
                //   ⚠ これまでは設定ファイル（`rl-support-company`）だけを見ていた。
                //     ところが常駐では、⚠ 書くのは SYSTEM のサービス・
                //     読むのは利用者の窓で、**別々のファイル**を見ている。
                //     ＝ 会社名が ⚠ **入ったり入らなかったり**した。
                //   ★繋いできた相談員が名乗る値（組織名）を先に使う。
                //     これは接続そのものに乗ってくるので、取りこぼしが無い。
                //   ⚠ 名乗りが無い古い相談員版のときは、従来どおりの順に落ちる。
                FittedBox(
                    child: Text(
                  client.organizationName.isNotEmpty
                      ? client.organizationName
                      : (rlSupportCompanyName().isNotEmpty
                          ? rlSupportCompanyName()
                          : client.displayName),
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 20,
                    overflow: TextOverflow.ellipsis,
                  ),
                  maxLines: 1,
                )),
                // v1.4.6-13: Phase 4 N3 - 部署 / 役職
                // 🔴 常駐は「担当　○○」を1行足す（2026-09-02 ご判断）。
                //   ⚠ お客様（従業員）は、頼んだ覚えなく繋がれることがある。
                //     ⚠ **誰が繋いでいるか**が見えないと不安になる。
                //   ⚠ いま出せるのは相談員PCが名乗る名前。会社に登録した
                //     表示名を出すには、サーバーから届ける仕組みが要る（別途）。
                if (rlIsResidentBuild() && client.displayName.isNotEmpty)
                  FittedBox(
                    child: Text(
                      '担当　${client.displayName}',
                      style: TextStyle(color: Colors.white, fontSize: 13),
                      maxLines: 1,
                    ),
                  ),
                if (client.departmentRole.isNotEmpty)
                  FittedBox(
                    child: Text(
                      client.departmentRole,
                      style: TextStyle(color: Colors.white, fontSize: 13),
                      maxLines: 1,
                    ),
                  ),
                // v1.4.6-13: Phase 4 N3 - 組織名
                if (client.organizationName.isNotEmpty)
                  FittedBox(
                    child: Text(
                      client.organizationName,
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                      maxLines: 1,
                    ),
                  ),
                // v1.4.6-13: Phase 4 - 9 桁 ID 非表示 (削除済)
                if (client.type_() == ClientType.terminal)
                  FittedBox(
                    child: Text(
                      translate("Terminal"),
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                if (client.type_() == ClientType.file)
                  FittedBox(
                    child: Text(
                      translate("File Transfer"),
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                if (client.type_() == ClientType.camera)
                  FittedBox(
                    child: Text(
                      translate("View Camera"),
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                if (client.portForward.isNotEmpty)
                  FittedBox(
                    child: Text(
                      "Port Forward: ${client.portForward}",
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                SizedBox(height: 10.0),
                FittedBox(
                    child: Row(
                  children: [
                    Text(
                      // 🔴 お客様に分かる言葉にする（2026-09-01 ご判断）。
                      //   ⚠ 「接続済み」は**何と接続したのか**が分からない。
                      //     ★「遠隔サポート中です」なら、いま何が起きているかが伝わる。
                      // 🔴 常駐は言い方を変える（2026-09-02 ご判断）。
                      //   ⚠ 常駐は**お客様が呼んでいない**ことがある。
                      //     「サポート中」だと、頼んだ覚えのないお客様には
                      //     何が起きているか伝わらない。
                      //   ★「遠隔制御中！」＝**いま操作されている**とはっきり出す。
                      //   ⚠ ワンタイムは今までどおり（お客様が自分で呼んでいる）。
                      client.authorized
                          ? client.disconnected
                              ? (rlIsResidentBuild()
                                  ? '遠隔制御は終了しました'
                                  : 'サポートは終了しました')
                              : (rlIsResidentBuild()
                                  ? '遠隔制御中！'
                                  : '遠隔サポート中です')
                          : "${translate("Request access to your device")}...",
                      style: TextStyle(color: Colors.white),
                    ).marginOnly(right: 8.0),
                    if (client.authorized)
                      Obx(
                        () => Text(
                          formatDurationToTime(
                            Duration(seconds: _time.value),
                          ),
                          style: TextStyle(color: Colors.white),
                        ),
                      )
                  ],
                ))
              ],
            ),
          ),
          Offstage(
            offstage: !client.authorized ||
                (client.type_() != ClientType.remote &&
                    client.type_() != ClientType.file &&
                    client.type_() != ClientType.camera),
            child: IconButton(
              onPressed: () => checkClickTime(client.id, () {
                if (client.type_() == ClientType.file) {
                  gFFI.chatModel.toggleCMFilePage();
                } else {
                  gFFI.chatModel
                      .toggleCMChatPage(MessageKey(client.peerId, client.id));
                }
              }),
              icon: SvgPicture.asset(client.type_() == ClientType.file
                  ? 'assets/file_transfer.svg'
                  : 'assets/chat2.svg'),
              splashRadius: kDesktopIconButtonSplashRadius,
            ),
          )
        ],
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;

  Widget _buildClientAvatar() {
    // v1.4.6-13: Phase 4 N3 - 顔写真は richAvatarUrl (data URL / http URL) 優先
    // 既存 client.avatar (RustDesk 既定経路) は fallback として残す
    final avatarSource =
        client.richAvatarUrl.isNotEmpty ? client.richAvatarUrl : client.avatar;
    return buildAvatarWidget(
          avatar: avatarSource,
          size: 70,
          borderRadius: 35, // 円形に変更 (元: 15 = 角丸四角)
          fallback: _buildInitialAvatar(),
        ) ??
        _buildInitialAvatar();
  }

  Widget _buildInitialAvatar() {
    // 🔴 丸いロゴは出さない（2026-09-01 ご判断「ロゴはいらない」）。
    //   ⚠ RustDesk 由来の見た目で、⚠ 中の文字は相談員PCのユーザー名の頭文字。
    //     お客様には意味が無く、⚠ 当社の画面らしくない。
    return const SizedBox.shrink();
    // ignore: dead_code
    final initialSource = client.displayName.isNotEmpty
        ? client.displayName
        : client.name;
    return Container(
      width: 70,
      height: 70,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: str2color(initialSource),
        // v1.4.6-13: Phase 4 N3 - 円形 + シアン枠
        shape: BoxShape.circle,
        border: Border.all(color: Color(0xFF06B6D4), width: 2),
      ),
      child: Text(
        initialSource.isNotEmpty ? initialSource[0] : '?',
        style: TextStyle(
          fontWeight: FontWeight.bold,
          color: Colors.white,
          fontSize: 40,
        ),
      ),
    );
  }
}

class _PrivilegeBoard extends StatefulWidget {
  final Client client;

  const _PrivilegeBoard({Key? key, required this.client}) : super(key: key);

  @override
  State<StatefulWidget> createState() => _PrivilegeBoardState();
}

class _PrivilegeBoardState extends State<_PrivilegeBoard> {
  late final client = widget.client;

  // v1.4.6-13: Phase 4 P3 強化版 - リスト型 + 説明文 + セクション分け
  // 元: GridView.count(crossAxisCount=4) のアイコン格子 → 現: 縦リスト + Switch
  // 顧客が「何の機能か」を理解できるよう、各行に説明文を併記
  Widget buildPermissionRow({
    required bool enabled,
    required IconData iconData,
    required String label,
    required String description,
    required Function(bool)? onSwitch,
    required bool canModify,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(iconData,
              size: 22,
              color: enabled ? MyTheme.accent : Colors.grey[500]),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (description.isNotEmpty)
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.color
                          ?.withOpacity(0.6),
                    ),
                  ),
              ],
            ),
          ),
          Switch(
            value: enabled,
            activeColor: MyTheme.accent,
            onChanged: canModify
                ? (v) => checkClickTime(client.id, () => onSwitch?.call(v))
                : null,
          ),
        ],
      ),
    );
  }

  Widget buildSectionHeader(String emoji, String title) {
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Row(
        children: [
          Text(emoji, style: TextStyle(fontSize: 13)),
          SizedBox(width: 6),
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.color
                  ?.withOpacity(0.7),
            ),
          ),
        ],
      ),
    );
  }

  void _setPerm(String name, bool enabled, void Function(bool) update) {
    bind.cmSwitchPermission(
        connId: client.id, name: name, enabled: enabled);
    setState(() => update(enabled));
  }

  @override
  Widget build(BuildContext context) {
    final canModify =
        bind.mainGetBuildinOption(key: kOptionEnablePermChangeInAcceptWindow) !=
            'N';
    final isCamera = client.type_() == ClientType.camera;

    return Container(
      width: double.infinity,
      margin: EdgeInsets.all(5.0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10.0),
        color: Theme.of(context).colorScheme.background,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            spreadRadius: 1,
            blurRadius: 1,
            offset: Offset(0, 1.5),
          ),
        ],
      ),
      // v1.4.6-13: Phase 4 P3 - リストが長い時のスクロール対応
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          // 🔴 常駐ではアクセス権限を出さない（2026-09-02 ご判断）。
          //   ⚠ 常駐は**会社が管理している業務用PC**。
          //     お客様（従業員）が相談員の操作を制限する場面ではない。
          //   ⚠ ワンタイムでは出す。あちらはお客様の私物PCで、
          //     ⚠ **お客様が相談員の操作を制限する手段**として必要（ご判断）。
          //   ⚠ 同じ画面を2製品で使っている。片方だけ変えるつもりが
          //     両方変わる事故を起こしているので、必ず製品で分ける。
          children: rlIsResidentBuild()
              ? const []
              : (isCamera
                  ? _buildCameraSections(canModify)
                  : _buildRemoteSections(canModify)),
        ),
      ),
    );
  }

  List<Widget> _buildRemoteSections(bool canModify) {
    // 🔴🔴 **お客様に出すのは「キーボード・マウス操作」だけ**（2026-09-01 ご判断）。
    //
    //   ご指摘:「他は相談員が使う機能なので、⚠ **お客様が制限すると
    //           サポートに支障が出る**。他のは会社管理者が許可できるように」
    //
    //   ⚠ 分けて考えると:
    //     お客様が決めるべきもの … 「自分のPCを触らせるかどうか」＝お客様の権利
    //     相談員が仕事に使う道具 … クリップボード／ファイル転送／音声／録画／
    //                              入力ブロック／プライバシーモード／再起動
    //   ⚠ 後者をお客様が切ると**サポートができなくなる**のに、
    //     ⚠ お客様には「切ると何が困るか」が分からない。
    //     ⚠ 切ったことを忘れて「なぜできないの」になる。
    //   ⚠ 選べるものが多いほど、お客様は迷い、押し間違える。
    //
    //   ★今日は「1つだけ出す」。⚠ 権限そのものは全部残っている（内部では使う）。
    //   ⚠ 明日: **会社管理者が項目ごとに「お客様に見せる／見せない」を決める**
    //     仕組みを設計する。AI判断の提供方式を会社ごとに決めるのと同じ形。
    //   ⚠ 戻すときは、この関数を git から戻すだけ。
    return [
      buildSectionHeader('📌', 'アクセス権限'),
      buildPermissionRow(
        enabled: client.keyboard,
        iconData: Icons.keyboard,
        label: 'キーボード・マウス操作',
        description: '遠隔から PC を操作可能にする',
        onSwitch: (v) => _setPerm('keyboard', v, (e) => client.keyboard = e),
        canModify: canModify,
      ),
      SizedBox(height: 8),
    ];
  }

  List<Widget> _buildCameraSections(bool canModify) {
    return [
      buildSectionHeader('📌', 'カメラ権限'),
      // 🔴 カメラ側の「音声出力共有」も出さない（2026-09-01 ご指示）。
      //   ⚠ 同じ名前の項目が2か所にある。片方だけ消すと取り残す。
      buildPermissionRow(
        enabled: client.recording,
        iconData: Icons.videocam_rounded,
        label: 'カメラ録画',
        description: 'セッション内容を遠隔側で録画',
        onSwitch: (v) => _setPerm('recording', v, (e) => client.recording = e),
        canModify: canModify,
      ),
      SizedBox(height: 8),
    ];
  }
}

const double buttonBottomMargin = 8;

/// 相談員が画面に印をつけている間の告知帯。
///
/// 顧客が「知らないうちに画面に線が出た」と感じないための表示。
/// 「やめてもらう」でいつでも打ち切れる。
class _RemoteDrawingNotice extends StatelessWidget {
  final Client client;
  const _RemoteDrawingNotice({Key? key, required this.client}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: EdgeInsets.symmetric(vertical: 4.0),
      padding: EdgeInsets.symmetric(horizontal: 10.0, vertical: 8.0),
      decoration: BoxDecoration(
        color: Color(0xFF123A57),
        borderRadius: BorderRadius.circular(8.0),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: Color(0xFFE03131),
              shape: BoxShape.circle,
            ),
          ),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              '相談員が画面に印をつけています',
              style: TextStyle(color: Colors.white, fontSize: 12.5),
            ),
          ),
          InkWell(
            onTap: () => bind.cmSetRemoteDrawingOff(connId: client.id),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Text(
                'やめてもらう',
                style: TextStyle(
                  color: Color(0xFF7FC7EE),
                  fontSize: 12,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 顧客側の「自分も描く」。
///
/// 押している間だけ画面全体のオーバーレイがタップを受け取るので、その間は
/// 顧客が自分のPCを操作できなくなる。**押している間だけ**にしているのはそのため。
/// 離し忘れても、オーバーレイ側に 10 秒で自動的に戻す安全弁がある。
class _CustomerDrawButton extends StatefulWidget {
  final Client client;
  const _CustomerDrawButton({Key? key, required this.client}) : super(key: key);

  @override
  State<_CustomerDrawButton> createState() => _CustomerDrawButtonState();
}

class _CustomerDrawButtonState extends State<_CustomerDrawButton> {
  bool _drawing = false;

  void _set(bool on) {
    if (_drawing == on) return;
    _drawing = on;
    bind.cmSetCustomerDraw(connId: widget.client.id, on: on);
    setState(() {});
  }

  @override
  void dispose() {
    // 画面が閉じても描画モードが残らないようにする。
    if (_drawing) {
      bind.cmSetCustomerDraw(connId: widget.client.id, on: false);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // buildButton は _CmControlPanel のインスタンスメソッドなので使えない。
    // 見た目を揃えた自前のボタンにする。
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: Container(
        width: double.infinity,
        margin: EdgeInsets.symmetric(vertical: 4.0),
        padding: EdgeInsets.symmetric(horizontal: 10.0, vertical: 9.0),
        decoration: BoxDecoration(
          color: _drawing ? Colors.blue.shade700 : MyTheme.accent,
          borderRadius: BorderRadius.circular(8.0),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.draw_outlined, color: Colors.white, size: 14),
            SizedBox(width: 6),
            Flexible(
              child: Text(
                _drawing ? '指を離すと終わります' : '自分も描く（押している間）',
                style: TextStyle(color: Colors.white, fontSize: 12.5),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CmControlPanel extends StatelessWidget {
  final Client client;

  const _CmControlPanel({Key? key, required this.client}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return client.authorized
        ? client.disconnected
            ? buildDisconnected(context)
            : buildAuthorized(context)
        : buildUnAuthorized(context);
  }

  buildAuthorized(BuildContext context) {
    // 🔴🔴 **お客様に「管理者権限を与える」釦を押させない**（2026-08-28 ご判断）。
    //
    //   ⚠ お客様は「昇格」の意味が分からない（社長ご自身が分からないと言われた）。
    //   ⚠ 押すと画面が暗くなって管理者の確認が出る。ご高齢の方には怖い体験。
    //   ⚠⚠ **サポート中に「はい」を押させるのは、詐欺の手口と同じ形**。
    //     お客様には「こういうときは押さないでください」と教えるべき場面なのに、
    //     当社が押させることになる。**そこは製品として作ってはいけない**。
    //
    //   ★入口は**相談員側に既にある**（ツールバーの「権限の昇格をリクエストする」）。
    //     判断は相談員が持ち、お客様は Windows が出す確認に答えるだけでよい。
    //   ⚠ 機能そのものは残す。消したのは**お客様側の釦**だけ。
    //   ⚠ 戻すなら、この false を bind.cmCanElevate() に戻せば元どおり。
    const bool canElevate = false;
    final model = Provider.of<ServerModel>(context);
    final showElevation = canElevate &&
        model.showElevation &&
        client.type_() == ClientType.remote;
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Offstage(
          offstage: !client.inVoiceCall,
          child: Row(
            children: [
              Expanded(
                child: buildButton(context,
                    color: MyTheme.accent,
                    onClick: null, onTapDown: (details) async {
                  final devicesInfo =
                      await AudioInput.getDevicesInfo(true, true);
                  List<String> devices = devicesInfo['devices'] as List<String>;
                  if (devices.isEmpty) {
                    msgBox(
                      gFFI.sessionId,
                      'custom-nocancel-info',
                      'Prompt',
                      'no_audio_input_device_tip',
                      '',
                      gFFI.dialogManager,
                    );
                    return;
                  }

                  String currentDevice = devicesInfo['current'] as String;
                  final x = details.globalPosition.dx;
                  final y = details.globalPosition.dy;
                  final position = RelativeRect.fromLTRB(x, y, x, y);
                  showMenu(
                    context: context,
                    position: position,
                    items: devices
                        .map((d) => PopupMenuItem<String>(
                              value: d,
                              height: 18,
                              padding: EdgeInsets.zero,
                              onTap: () => AudioInput.setDevice(d, true, true),
                              child: IgnorePointer(
                                  child: RadioMenuButton(
                                value: d,
                                groupValue: currentDevice,
                                onChanged: (v) {
                                  if (v != null)
                                    AudioInput.setDevice(v, true, true);
                                },
                                child: Container(
                                  child: Text(
                                    d,
                                    overflow: TextOverflow.ellipsis,
                                    maxLines: 1,
                                  ),
                                  constraints: BoxConstraints(
                                      maxWidth:
                                          kConnectionManagerWindowSizeClosedChat
                                                  .width -
                                              80),
                                ),
                              )),
                            ))
                        .toList(),
                  );
                },
                    icon: Icon(
                      Icons.call_rounded,
                      color: Colors.white,
                      size: 14,
                    ),
                    text: "Audio input",
                    textColor: Colors.white),
              ),
              Expanded(
                child: buildButton(
                  context,
                  color: Colors.red,
                  onClick: () => closeVoiceCall(),
                  icon: Icon(
                    Icons.call_end_rounded,
                    color: Colors.white,
                    size: 14,
                  ),
                  text: "Stop voice call",
                  textColor: Colors.white,
                ),
              )
            ],
          ),
        ),
        Offstage(
          offstage: !client.incomingVoiceCall,
          child: Row(
            children: [
              Expanded(
                child: buildButton(context,
                    color: MyTheme.accent,
                    onClick: () => handleVoiceCall(true),
                    icon: Icon(
                      Icons.call_rounded,
                      color: Colors.white,
                      size: 14,
                    ),
                    text: "Accept",
                    textColor: Colors.white),
              ),
              Expanded(
                child: buildButton(
                  context,
                  color: Colors.red,
                  onClick: () => handleVoiceCall(false),
                  icon: Icon(
                    Icons.phone_disabled_rounded,
                    color: Colors.white,
                    size: 14,
                  ),
                  text: "Dismiss",
                  textColor: Colors.white,
                ),
              )
            ],
          ),
        ),
        // 相談員が画面に印をつけているときだけ出す。
        Offstage(
          offstage: !client.remoteDrawing || client.type_() != ClientType.remote,
          child: _CustomerDrawButton(client: client),
        ),
        // 🔴 相談員の画面を見せてもらっている状態から**元に戻す**ボタン。
        //
        //   ★2026-08-25 復活。相談員側の「自分の画面を見せる」を戻したので、
        //     こちらが**唯一の帰り道**になる。片方だけだと、一度入れ替えたら
        //     二度と戻せない（7/30 に実際そうなった）。
        //
        //   ⚠ `client.fromSwitch` のときだけ出る。＝ 入れ替えでつながった
        //     ときにしか現れない。通常のサポート中や音声通話のときは出ない。
        //     7/29 に「音声通話のときに並ぶ」として消したが、消すべきだったのは
        //     **文言**の方だった（顧客側前提の訳語が相談員側にも出ていた）。
        Offstage(
          offstage: !client.fromSwitch,
          child: buildButton(context,
              color: Colors.purple,
              onClick: () => handleSwitchBack(context),
              icon: Icon(Icons.reply, color: Colors.white),
              text: "Switch back",
              textColor: Colors.white),
        ),
        Offstage(
          offstage: !showElevation,
          child: buildButton(
            context,
            color: MyTheme.accent,
            onClick: () {
              // 🔴🔴 **窓を隠さない**（2026-08-28 ご指摘）。
              //   ⚠ ご報告:「押してもタスクに隠れるだけで何も起きない」。
              //     押した直後に窓を最小化していたため、⚠ **管理者の確認が
              //     出ても、失敗しても、お客様には何も見えなかった**。
              //   ★押した結果が見える所に残す。隠すのは、うまくいってからでよい。
              handleElevate(context);
            },
            icon: Icon(
              Icons.security_rounded,
              color: Colors.white,
              size: 14,
            ),
            // ⚠ お客様に見える文字。英語のままにしない（2026-08-28）。
            text: '管理者として許可する',
            textColor: Colors.white,
          ),
        ),
        // 🔴🔴 **常駐にも「終了する」を出す**（2026-09-04 社長のご判断・A案）。
        //
        //   ⚠ ご指摘:「常駐って顧客が終了する方法がないのね」。⚠ **そのとおりだった。**
        //   ⚠ それまでの考えは「常駐は無人の保守なので、勝手に切られると困る」。
        //     ★しかし⚠ **常駐PCの前に人が座っていることは実際にある**。
        //       ・見られたくない画面を開いている
        //       ・知らない誰かが操作していると感じる
        //     ⚠ そのとき止める手段が1つも無いのは、お客様の安心の面で弱い。
        //   ★出す。⚠ ただし**押し間違いを防ぐ確認**を必ず挟む
        //     （夜間の無人保守を、通りすがりに止められては困る）。
        //   ⚠ ワンタイムは本体の画面に「終了する」があるので、ここでは出さない。
        //     ＝ ⚠ **止める釦が2つある状態を作らない**（迷いの元）。
        // ⚠ 会社が「出さない」を選べる（2026-09-04 ご指示）。
        //   ★既定は**出す**。⚠ 安全側に倒す。
        //     受け取れなかっただけで釦が消えると、⚠ **止める手段が無い状態**に戻る。
        //   ⚠ 明示的に `N` が入っているときだけ隠す（他の許可と同じ考え）。
        if (rlIsResidentBuild() && _residentEndAllowed())
          Row(
            children: [
              Expanded(
                child: buildButton(context,
                    color: const Color(0xFFB91C1C),
                    onClick: () => _confirmEndResident(context),
                    text: '終了する',
                    icon: const Icon(Icons.stop_circle_outlined,
                        color: Colors.white, size: 14),
                    textColor: Colors.white),
              ),
            ],
          ),
        // 🔴 「切断」は出さない（2026-09-01 ご判断）。
        //   ⚠ 止める釦が2つあるとお客様が迷う。しかも働きが違う:
        //     切断     … 接続を切るだけ
        //     終了する … 接続を切る＋被操作を止める＋合言葉を無効にする
        //                ＋自動起動を消す＋サーバーへ終了を伝える
        //   ★確実に止まる「終了する」に一本化する。
        //   ⚠ 処理（handleDisconnect）は消さない。内部で使っている。
        //   ⚠ 戻すときは Offstage の offstage を false にするだけ。
        Offstage(
          offstage: true,
          child: Row(
          children: [
            Expanded(
              child: buildButton(context,
                  color: Colors.redAccent,
                  onClick: handleDisconnect,
                  text: 'Disconnect',
                  icon: Icon(
                    Icons.link_off_rounded,
                    color: Colors.white,
                    size: 14,
                  ),
                  textColor: Colors.white),
            ),
          ],
        ))
      ],
    ).marginOnly(bottom: buttonBottomMargin);
  }

  buildDisconnected(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Expanded(
            child: buildButton(context,
                color: MyTheme.accent,
                onClick: handleClose,
                text: 'Close',
                textColor: Colors.white)),
      ],
    ).marginOnly(bottom: buttonBottomMargin);
  }

  buildUnAuthorized(BuildContext context) {
    // 🔴🔴 **お客様に「管理者権限を与える」釦を押させない**（2026-08-28 ご判断）。
    //
    //   ⚠ お客様は「昇格」の意味が分からない（社長ご自身が分からないと言われた）。
    //   ⚠ 押すと画面が暗くなって管理者の確認が出る。ご高齢の方には怖い体験。
    //   ⚠⚠ **サポート中に「はい」を押させるのは、詐欺の手口と同じ形**。
    //     お客様には「こういうときは押さないでください」と教えるべき場面なのに、
    //     当社が押させることになる。**そこは製品として作ってはいけない**。
    //
    //   ★入口は**相談員側に既にある**（ツールバーの「権限の昇格をリクエストする」）。
    //     判断は相談員が持ち、お客様は Windows が出す確認に答えるだけでよい。
    //   ⚠ 機能そのものは残す。消したのは**お客様側の釦**だけ。
    //   ⚠ 戻すなら、この false を bind.cmCanElevate() に戻せば元どおり。
    const bool canElevate = false;
    final model = Provider.of<ServerModel>(context);
    final showElevation = canElevate &&
        model.showElevation &&
        client.type_() == ClientType.remote;
    final showAccept = model.approveMode != 'password';
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Offstage(
          offstage: !showElevation || !showAccept,
          child: buildButton(context, color: Colors.green[700], onClick: () {
            handleAccept(context);
            handleElevate(context);
            windowManager.minimize();
          },
              text: 'Accept and Elevate',
              icon: Icon(
                Icons.security_rounded,
                color: Colors.white,
                size: 14,
              ),
              textColor: Colors.white,
              tooltip: 'accept_and_elevate_btn_tooltip'),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (showAccept)
              Expanded(
                child: Column(
                  children: [
                    buildButton(
                      context,
                      color: MyTheme.accent,
                      onClick: () {
                        handleAccept(context);
                        windowManager.minimize();
                      },
                      text: 'Accept',
                      textColor: Colors.white,
                    ),
                  ],
                ),
              ),
            Expanded(
              child: buildButton(
                context,
                color: Colors.transparent,
                border: Border.all(color: Colors.grey),
                onClick: handleDisconnect,
                text: 'Cancel',
                textColor: null,
              ),
            ),
          ],
        ),
      ],
    ).marginOnly(bottom: buttonBottomMargin);
  }

  Widget buildButton(BuildContext context,
      {required Color? color,
      GestureTapCallback? onClick,
      Widget? icon,
      BoxBorder? border,
      required String text,
      required Color? textColor,
      String? tooltip,
      GestureTapDownCallback? onTapDown}) {
    assert(!(onClick == null && onTapDown == null));
    Widget textWidget;
    if (icon != null) {
      textWidget = Text(
        translate(text),
        style: TextStyle(color: textColor),
        textAlign: TextAlign.center,
      );
    } else {
      textWidget = Expanded(
        child: Text(
          translate(text),
          style: TextStyle(color: textColor),
          textAlign: TextAlign.center,
        ),
      );
    }
    final borderRadius = BorderRadius.circular(10.0);
    final btn = Container(
      height: 28,
      decoration: BoxDecoration(
          color: color, borderRadius: borderRadius, border: border),
      child: InkWell(
        borderRadius: borderRadius,
        onTap: () {
          if (onClick == null) return;
          checkClickTime(client.id, onClick);
        },
        onTapDown: (details) {
          if (onTapDown == null) return;
          checkClickTime(client.id, () {
            onTapDown.call(details);
          });
        },
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Offstage(offstage: icon == null, child: icon).marginOnly(right: 5),
            textWidget,
          ],
        ),
      ),
    );
    return (tooltip != null
            ? Tooltip(
                message: translate(tooltip),
                child: btn,
              )
            : btn)
        .marginAll(4);
  }

  /// お客様に「終了する」を出してよいか（2026-09-04 ご指示）。
  ///
  /// ⚠ **既定は出す。** 設定が届いていない・古い版のときに釦が消えると、
  ///   ⚠ **お客様が止める手段を失う**（いちばん避けたい形）。
  /// ⚠ 明示的に `N` が入っているときだけ隠す。他の許可と同じ考え。
  bool _residentEndAllowed() {
    try {
      return bind.mainGetLocalOption(key: 'rl-allow-resident-end').trim() != 'N';
    } catch (_) {
      return true;
    }
  }

  /// 🔴 常駐で「終了する」を押したときの確認（2026-09-04 社長のご指示）。
  ///
  /// ⚠ **押し間違いを防ぐ**のが目的。⚠ 夜間の無人保守を、
  ///   通りすがりの人が一押しで止められては困る。
  /// ⚠ 既定は「キャンセル」側にする（うっかり Enter で終わらせない）。
  /// ⚠ 文言で「担当者にひとこと」を促す。⚠ 黙って切られると、
  ///   相談員は原因が分からないまま作業が消える。
  Future<void> _confirmEndResident(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        title: const Text('遠隔サポートを終了しますか？',
            style: TextStyle(fontSize: 16)),
        content: const Text(
          '担当者との接続が切れます。\n'
          '作業中の場合は、担当者にひとこと伝えてからにしてください。',
          style: TextStyle(fontSize: 13.5, height: 1.7),
        ),
        actions: [
          // ⚠ キャンセルを左（既定）に置く。★危ない方を押しやすくしない。
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: const Color(0xFFB91C1C)),
            child: const Text('終了する'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    // ⚠ 誰が止めたかを残す。⚠ 会社管理者が後から確かめられるように。
    rlTrace('resident_end_by_customer');
    await handleDisconnect();
  }

  Future<void> handleDisconnect() async {
    bind.cmCloseConnection(connId: client.id);
    // 🔴🔴 顧客版では「切断」＝**サポートを終わらせる**（2026-08-27 ご指摘）。
    //
    //   ⚠ 元は今つながっている1本を切るだけだった。お客様は
    //     「切断」を押したらサポートが終わったと受け取るのに、
    //     実際は**アプリも被操作サービスも動いたまま・合言葉も生きたまま**で、
    //     相談員はすぐ繋ぎ直せる。＝「×」と同じ形の穴。
    //   ★ここ（接続の窓）は本体とは**別のプロセス**なので、
    //     終了の一式（サーバーへ連絡・控えの片付け）を直接は呼べない。
    //     決まった場所に合図のファイルを置き、本体がそれを見て終わらせる。
    //   ⚠ 置き場は %LOCALAPPDATA% の固定の場所。展開先(APP_DIR)は
    //     起動ごとに変わりうるので使わない（合言葉の控えと同じ考え）。
    //   ⚠ 相談員版・常駐版では今までどおり「1本を切る」だけ。
    //     常駐は切ったあとも待ち受けているのが仕事なので、終わらせてはいけない。
    if (kRlSupportShowWindow) {
      // 🔴🔴 **合図を置くだけでは足りない**（2026-08-28 実機・重大）。
      //
      //   ⚠ ご報告:「顧客が切断してもビュアーが終わるだけでサポートが終わらない」。
      //   ⚠ 原因: この合図を読むのは**本体のアプリ**だが、
      //     ログオン前の再接続で繋がっているときは、⚠ **本体が動いていない**
      //     （応答しているのは画面を持たない一時サービス）。
      //     ＝ 合図を置いても**読む相手がいない**。
      //   ⚠ その結果、お客様は切ったつもりでも
      //     ・サーバーは「対応中」のまま
      //     ・⚠ **合言葉が生きたまま**＝もう一度入れてしまえる
      //     ワンタイムの約束（使い終わったら誰も入れない）が崩れる。
      //
      //   ★**この窓が自分で合言葉を潰す**。他のプロセスを当てにしない。
      //     合言葉さえ消えれば、サーバーの表示がどうであれ**誰も入れない**。
      //     ⚠ 順番が大事: 先に潰してから合図を置く。
      //       合図の側で失敗しても、入口はもう閉じている。
      try {
        // ⚠ 空にすると「合言葉なし」＝入れない状態になる。
        await bind.mainSetPermanentPasswordWithResult(password: '');
      } catch (e) {
        debugPrint('RL: 切断時に合言葉を潰せませんでした: $e');
      }
      try {
        // ⚠ 被操作そのものも止める。止めないと、次の接続を待ち受け続ける。
        await bind.mainStopService();
      } catch (e) {
        debugPrint('RL: 切断時に被操作を止められませんでした: $e');
      }
      try {
        final base = Platform.environment['LOCALAPPDATA'] ?? '';
        if (base.isNotEmpty) {
          final d = Directory('$base/REMOHELP PRO');
          if (!d.existsSync()) d.createSync(recursive: true);
          File('${d.path}/end-requested').writeAsStringSync(
              DateTime.now().toIso8601String());
        }
      } catch (_) {
        // 合図を置けなくても、入口は上で閉じている。
      }
    }
  }

  void handleAccept(BuildContext context) {
    final model = Provider.of<ServerModel>(context, listen: false);
    model.sendLoginResponse(client, true);
  }

  void handleElevate(BuildContext context) {
    final model = Provider.of<ServerModel>(context, listen: false);
    model.setShowElevation(false);
    bind.cmElevatePortable(connId: client.id);
  }

  void handleClose() async {
    await bind.cmRemoveDisconnectedConnection(connId: client.id);
    if (await bind.cmGetClientsLength() == 0) {
      windowManager.close();
    }
  }

  void handleSwitchBack(BuildContext context) {
    bind.cmSwitchBack(connId: client.id);
  }

  void handleVoiceCall(bool accept) {
    bind.cmHandleIncomingVoiceCall(id: client.id, accept: accept);
  }

  void closeVoiceCall() {
    bind.cmCloseVoiceCall(id: client.id);
  }
}

void checkClickTime(int id, Function() callback) async {
  if (allowRemoteCMModification()) {
    callback();
    return;
  }
  var clickCallbackTime = DateTime.now().millisecondsSinceEpoch;
  await bind.cmCheckClickTime(connId: id);
  Timer(const Duration(milliseconds: 120), () async {
    var d = clickCallbackTime - await bind.cmGetClickTime();
    if (d > 120) callback();
  });
}

bool allowRemoteCMModification() {
  return option2bool(kOptionAllowRemoteCmModification,
      bind.mainGetLocalOption(key: kOptionAllowRemoteCmModification));
}

class _FileTransferLogPage extends StatefulWidget {
  _FileTransferLogPage({Key? key}) : super(key: key);

  @override
  State<_FileTransferLogPage> createState() => __FileTransferLogPageState();
}

class __FileTransferLogPageState extends State<_FileTransferLogPage> {
  @override
  Widget build(BuildContext context) {
    return statusList();
  }

  Widget generateCard(Widget child) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.all(
          Radius.circular(15.0),
        ),
      ),
      child: child,
    );
  }

  iconLabel(CmFileLog item) {
    switch (item.action) {
      case CmFileAction.none:
        return Container();
      case CmFileAction.localToRemote:
      case CmFileAction.remoteToLocal:
        return Column(
          children: [
            Transform.rotate(
              angle: item.action == CmFileAction.remoteToLocal ? 0 : pi,
              child: SvgPicture.asset(
                "assets/arrow.svg",
                colorFilter: svgColor(Theme.of(context).tabBarTheme.labelColor),
              ),
            ),
            Text(item.action == CmFileAction.remoteToLocal
                ? translate('Send')
                : translate('Receive'))
          ],
        );
      case CmFileAction.remove:
        return Column(
          children: [
            Icon(
              Icons.delete,
              color: Theme.of(context).tabBarTheme.labelColor,
            ),
            Text(translate('Delete'))
          ],
        );
      case CmFileAction.createDir:
        return Column(
          children: [
            Icon(
              Icons.create_new_folder,
              color: Theme.of(context).tabBarTheme.labelColor,
            ),
            Text(translate('Create Folder'))
          ],
        );
      case CmFileAction.rename:
        return Column(
          children: [
            Icon(
              Icons.drive_file_move_outlined,
              color: Theme.of(context).tabBarTheme.labelColor,
            ),
            Text(translate('Rename'))
          ],
        );
    }
  }

  Widget statusList() {
    return PreferredSize(
      preferredSize: const Size(200, double.infinity),
      child: Container(
          padding: const EdgeInsets.all(12.0),
          child: Obx(
            () {
              final jobTable = gFFI.cmFileModel.currentJobTable;
              statusListView(List<CmFileLog> jobs) => ListView.builder(
                    controller: ScrollController(),
                    itemBuilder: (BuildContext context, int index) {
                      final item = jobs[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: generateCard(
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  SizedBox(
                                    width: 50,
                                    child: iconLabel(item),
                                  ).paddingOnly(left: 15),
                                  const SizedBox(
                                    width: 16.0,
                                  ),
                                  Expanded(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          item.fileName,
                                        ).paddingSymmetric(vertical: 10),
                                        if (item.totalSize > 0)
                                          Text(
                                            '${translate("Total")} ${readableFileSize(item.totalSize.toDouble())}',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: MyTheme.darkGray,
                                            ),
                                          ),
                                        if (item.totalSize > 0)
                                          Offstage(
                                            offstage: item.state !=
                                                JobState.inProgress,
                                            child: Text(
                                              '${translate("Speed")} ${readableFileSize(item.speed)}/s',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: MyTheme.darkGray,
                                              ),
                                            ),
                                          ),
                                        Offstage(
                                          offstage: !(item.isTransfer() &&
                                              item.state !=
                                                  JobState.inProgress),
                                          child: Text(
                                            translate(
                                              item.display(),
                                            ),
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: MyTheme.darkGray,
                                            ),
                                          ),
                                        ),
                                        if (item.totalSize > 0)
                                          Offstage(
                                            offstage: item.state !=
                                                JobState.inProgress,
                                            child: LinearPercentIndicator(
                                              padding:
                                                  EdgeInsets.only(right: 15),
                                              animateFromLastPercent: true,
                                              center: Text(
                                                '${(item.finishedSize / item.totalSize * 100).toStringAsFixed(0)}%',
                                              ),
                                              barRadius: Radius.circular(15),
                                              percent: item.finishedSize /
                                                  item.totalSize,
                                              progressColor: MyTheme.accent,
                                              backgroundColor:
                                                  Theme.of(context).hoverColor,
                                              lineHeight:
                                                  kDesktopFileTransferRowHeight,
                                            ).paddingSymmetric(vertical: 15),
                                          ),
                                      ],
                                    ),
                                  ),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [],
                                  ),
                                ],
                              ),
                            ],
                          ).paddingSymmetric(vertical: 10),
                        ),
                      );
                    },
                    itemCount: jobTable.length,
                  );

              return jobTable.isEmpty
                  ? generateCard(
                      Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SvgPicture.asset(
                              "assets/transfer.svg",
                              colorFilter: svgColor(
                                  Theme.of(context).tabBarTheme.labelColor),
                              height: 40,
                            ).paddingOnly(bottom: 10),
                            Text(
                              translate("No transfers in progress"),
                              textAlign: TextAlign.center,
                              textScaler: TextScaler.linear(1.20),
                              style: TextStyle(
                                  color:
                                      Theme.of(context).tabBarTheme.labelColor),
                            ),
                          ],
                        ),
                      ),
                    )
                  : statusListView(jobTable);
            },
          )),
    );
  }
}
