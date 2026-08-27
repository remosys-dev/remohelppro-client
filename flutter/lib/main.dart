import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bot_toast/bot_toast.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common/widgets/overlay.dart';
import 'package:flutter_hbb/rl_support.dart';
import 'package:flutter_hbb/remohelppro_trace.dart' show rlTrace, rlTraceSetRole;
import 'package:flutter_hbb/desktop/pages/desktop_tab_page.dart';
import 'package:flutter_hbb/desktop/pages/install_page.dart';
import 'package:flutter_hbb/desktop/pages/server_page.dart';
import 'package:flutter_hbb/desktop/screen/desktop_file_transfer_screen.dart';
import 'package:flutter_hbb/desktop/screen/desktop_view_camera_screen.dart';
import 'package:flutter_hbb/desktop/screen/desktop_port_forward_screen.dart';
import 'package:flutter_hbb/desktop/screen/desktop_remote_screen.dart';
import 'package:flutter_hbb/desktop/screen/desktop_terminal_screen.dart';
import 'package:flutter_hbb/desktop/widgets/refresh_wrapper.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'common.dart';
import 'consts.dart';
import 'mobile/pages/home_page.dart';
import 'mobile/pages/server_page.dart';
import 'models/platform_model.dart';

import 'package:flutter_hbb/plugin/handlers.dart'
    if (dart.library.html) 'package:flutter_hbb/web/plugin/handlers.dart';

/// Basic window and launch properties.
int? kWindowId;
WindowType? kWindowType;
late List<String> kBootArgs;

Future<void> main(List<String> args) async {
  earlyAssert();
  WidgetsFlutterBinding.ensureInitialized();

  // 🔴 落ちた理由を残す（2026-08-27）。
  //
  //   ⚠ これまで、この製品には**受け止め手がひとつも無かった**。
  //     Dart 側で例外が投げられても、記録は画面の裏に消えるだけ。
  //     ＝ お客様のアプリが消えても、落ちたのか消されたのかも分からない。
  //   ★ここに1行残るかどうかで切り分けられる:
  //     行がある → 自分で落ちた。行が無い → **外から止められた**。
  final prevOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails d) {
    rlTrace('flutter_error', {
      'e': d.exception.toString(),
      'lib': d.library ?? '',
    });
    if (prevOnError != null) prevOnError(d);
  };
  WidgetsBinding.instance.platformDispatcher.onError = (Object e, StackTrace st) {
    rlTrace('dart_error', {'e': e.toString()});
    return false; // 既定の扱いは変えない（握りつぶさない）
  };

  debugPrint("launch args: $args");
  kBootArgs = List.from(args);
  rlTrace('app_start', {'args': args.isEmpty ? '' : args.first});

  if (!isDesktop) {
    runMobileApp();
    return;
  }
  // main window
  if (args.isNotEmpty && args.first == 'multi_window') {
    kWindowId = int.parse(args[1]);
    stateGlobal.setWindowId(kWindowId!);
    if (!isMacOS) {
      WindowController.fromWindowId(kWindowId!).showTitleBar(false);
    }
    final argument = args[2].isEmpty
        ? <String, dynamic>{}
        : jsonDecode(args[2]) as Map<String, dynamic>;
    int type = argument['type'] ?? -1;
    // to-do: No need to parse window id ?
    // Because stateGlobal.windowId is a global value.
    argument['windowId'] = kWindowId;
    kWindowType = type.windowType;
    switch (kWindowType) {
      case WindowType.RemoteDesktop:
        desktopType = DesktopType.remote;
        runMultiWindow(
          argument,
          kAppTypeDesktopRemote,
        );
        break;
      case WindowType.FileTransfer:
        desktopType = DesktopType.fileTransfer;
        runMultiWindow(
          argument,
          kAppTypeDesktopFileTransfer,
        );
        break;
      case WindowType.ViewCamera:
        desktopType = DesktopType.viewCamera;
        runMultiWindow(
          argument,
          kAppTypeDesktopViewCamera,
        );
        break;
      case WindowType.PortForward:
        desktopType = DesktopType.portForward;
        runMultiWindow(
          argument,
          kAppTypeDesktopPortForward,
        );
        break;
      case WindowType.Terminal:
        desktopType = DesktopType.terminal;
        runMultiWindow(
          argument,
          kAppTypeDesktopTerminal,
        );
      default:
        // 🔴 種類の分からない子ウィンドウを、そのまま残さない（2026-08-04 実機で確認）。
        //
        //   ここへ来ると **runApp を一度も呼ばない**。Flutter は何も描かないので、
        //   窓は「New Window」という題名のまま
        //   **「Loading...」を出したまま永久に残る**。
        //   お客様の画面に、閉じ方の分からない窓が居座ることになる。
        //   実機では2つ出ていて、どちらも消えなかった。
        //
        //   ⚠ 起きる条件は、渡された合図に種類が入っていないとき（`type` が無い＝-1）
        //     と、あり得ない種類（Main）のとき。どちらも**この窓に用は無い**。
        //     用の無い窓は、黙って残すより閉じるほうが安全。
        //   ⚠ 原因そのものは別に追う。これは「残さない」ための歯止め。
        try {
          debugPrint('unknown multi_window type=$type, closing window $kWindowId');
          await WindowController.fromWindowId(kWindowId!).close();
        } catch (e) {
          debugPrint('failed to close unknown window: $e');
        }
        break;
    }
  } else if (args.isNotEmpty && args.first == '--cm') {
    debugPrint("--cm started");
    desktopType = DesktopType.cm;
    await windowManager.ensureInitialized();
    runConnectionManagerScreen();
  } else if (args.contains('--install')) {
    runInstallPage();
  } else {
    desktopType = DesktopType.main;
    await windowManager.ensureInitialized();
    windowManager.setPreventClose(true);
    if (isMacOS) {
      disableWindowMovable(kWindowId);
    }
    runMainApp(true);
  }
}

Future<void> initEnv(String appType) async {
  // global shared preference
  await platformFFI.init(appType);
  // global FFI, use this **ONLY** for global configuration
  // for convenience, use global FFI on mobile platform
  // focus on multi-ffi on desktop first
  await initGlobalFFI();
  // await Firebase.initializeApp();
  _registerEventHandler();
  // Update the system theme.
  updateSystemWindowTheme();
}

void runMainApp(bool startService) async {
  // register uni links
  await initEnv(kAppTypeMain);
  checkUpdate();
  // trigger connection status updater
  await bind.mainCheckConnectStatus();
  if (startService) {
    gFFI.serverModel.startService();
    bind.pluginSyncUi(syncTo: kAppTypeMain);
    bind.pluginListReload();
  }
  await Future.wait([gFFI.abModel.loadCache(), gFFI.groupModel.loadCache()]);
  gFFI.userModel.refreshCurrentUser();
  runApp(App());

  // 🔴🔴 誰のものでもない子ウィンドウを片付ける（2026-08-08・3回目のご指摘）。
  //
  //   「Loading...」とだけ書かれた窓が閉じられないまま残る事故が続いていた。
  //   2026-08-04 に下の multi_window 分岐へ「自分で閉じる」歯止めを入れたが
  //   **効かなかった**。当然で、あれは**その窓の Dart が動いた場合**の話。
  //   動かないから残っているのに、動いた前提の手当てをしていた。
  //   ★閉じられるのは、外から見ているメインウィンドウだけ。
  //   ⚠ 間隔を 10秒 → 3秒 にした（2026-08-14・4回目のご指摘）。
  //     2回続けて身に覚えが無かったものだけ閉じる作りなので、
  //     10秒だと**閉じるまで最大20秒**かかる。その20秒のあいだ、
  //     お客様の画面には閉じ方の分からない窓が出たままになる。
  //     相談員が繋いだ直後がまさにその20秒なので、毎回見えることになる。
  //     3秒なら最大6秒。
  //     ⚠ 短くしすぎない。窓は「作られてから登録されるまで」に間があり
  //       （createWindow → setFrame → registerActiveWindow）、
  //       そこを巻き込むと**正規の遠隔画面が開いた瞬間に閉じる**。
  //       その間は1秒未満なので、6秒あれば十分な余裕がある。
  if (isDesktop) {
    // ⚠ 画面が一度も handler を設定しない作り（お客様の一回版）でも、
    //   「描き始めた」の合図を受けられるように、ここで必ず据え付ける。
    //   ⚠ これが無いと合図が届かず、12秒後に**正規の窓まで閉じる**。
    rustDeskWinManager.setMethodHandler(null);
    Timer.periodic(const Duration(seconds: 3), (_) async {
      await rustDeskWinManager.closeStrayWindows();
    });
  }

  bool? alwaysOnTop;
  if (isDesktop) {
    alwaysOnTop =
        bind.mainGetBuildinOption(key: "main-window-always-on-top") == 'Y';
  }

  // Set window option.
  WindowOptions windowOptions = getHiddenTitleBarWindowOptions(
      isMainWindow: true, alwaysOnTop: alwaysOnTop);
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    // Restore the location of the main window before window hide or show.
    await restoreWindowPosition(WindowType.Main);
    // Check the startup argument, if we successfully handle the argument, we keep the main window hidden.
    final handledByUniLinks = await initUniLinks();
    debugPrint("handled by uni links: $handledByUniLinks");
    if (handledByUniLinks || handleUriLink(cmdArgs: kBootArgs)) {
      windowManager.hide();
      // v1.4.6-17: タスクバー完全非表示 (A-4 ちらちら問題の恒久対策)
      await windowManager.setSkipTaskbar(true);
    } else {
      // v1.4.6-12: REMOHELP PRO Phase 4 - メイン画面常時非表示
      // 起動方法問わず (アイコンクリック・スタートアップ・URL handler とも) ウィンドウを隠す
      // タスクトレイアイコンから「ウィンドウを開く」で必要時のみ表示可能
      // 2026-06-23: ワンタイム・サポート用ポータブル版では窓(ID+一時PW)を表示する。
      //   --dart-define=RL_SUPPORT_SHOW_WINDOW=true でビルドした版のみ表示。
      //   フリート版(未指定=false)は従来どおり常時隠す。
      const rlSupportShowWindow = kRlSupportShowWindow;
      if (!rlSupportShowWindow) {
        windowManager.hide();
        // v1.4.6-17: タスクバー完全非表示 (A-4 ちらちら問題の恒久対策)
        await windowManager.setSkipTaskbar(true);
      } else {
        // 2026-06-23: サポート版はウィンドウを明示的に表示する。
        //   waitUntilReadyToShow は既定で非表示のため、hide をスキップするだけでは出ない。
        await windowManager.setSkipTaskbar(false);
        await windowManager.show();
        await windowManager.focus();
      }
      // 登録は visible に関係なく必要 (URL handler や他 client からの接続受付のため)
      rustDeskWinManager.registerActiveWindow(kWindowMainId);
    }
    windowManager.setOpacity(1);
    windowManager.setTitle(getWindowName());
    // Do not use `windowManager.setResizable()` here.
    setResizable(!bind.isIncomingOnly());
    // 🔴🔴 Mac では音声を送らない（2026-08-16 実機で判明）。
    //
    //   Windows は「パソコンから出ている音」を拾えるが、
    //   ⚠ **macOS にはその仕組みが無く、代わりに「マイク」を拾ってしまう**
    //     （src/server/audio_service.rs の default_input_device()）。
    //   ＝ 相談員の「音を聞く」が、Mac では「**部屋の音を聞く**」になる。
    //   お客様に断りなくマイクが流れるのは、privacy として通らない。
    //   実際、相談員側と音が回ってハウリングした。
    //
    //   ★Mac のお客様版では、最初から音声を送らない。
    //   ⚠ Windows は従来どおり（エラー音を聞けることに意味がある）。
    //   ⚠ 相談員が別途始める「Web通話」は音声の扱いが別なので、これに影響されない。
    if (kRlSupportShowWindow && isMacOS) {
      try {
        await bind.mainSetOption(key: 'enable-audio', value: 'N');
      } catch (e) {
        debugPrint('RL: Mac の音声を止められませんでした: $e');
      }
    }
    // 2026-06-23: サポート版(ワンタイム)は分岐に関係なく最後に必ず表示する(取りこぼし防止)
    if (kRlSupportShowWindow) {
      await windowManager.setSkipTaskbar(false);
      // 2026-07-23: 顧客が認証コード画面に気づけるよう確実に最前面へ。
      //   Windows は focus() 単体だとタスクバー点滅で終わり前面化しないことがあるため、
      //   一時的に always-on-top で最前面に出してから解除する。
      await windowManager.setAlwaysOnTop(true);
      await windowManager.show();
      await windowManager.focus();
      await windowManager.setAlwaysOnTop(false);
    }
  });
}

void runMobileApp() async {
  await initEnv(kAppTypeMain);
  checkUpdate();
  if (isAndroid) androidChannelInit();
  if (isAndroid) platformFFI.syncAndroidServiceAppDirConfigPath();
  if (isAndroid) await rlSetAndroidTransferDir();
  draggablePositions.load();
  await Future.wait([gFFI.abModel.loadCache(), gFFI.groupModel.loadCache()]);
  gFFI.userModel.refreshCurrentUser();
  runApp(App());
  await initUniLinks();
}

void runMultiWindow(
  Map<String, dynamic> argument,
  String appType,
) async {
  await initEnv(appType);
  final title = getWindowName();
  // set prevent close to true, we handle close event manually
  WindowController.fromWindowId(kWindowId!).setPreventClose(true);
  if (isMacOS) {
    disableWindowMovable(kWindowId);
  }
  late Widget widget;
  switch (appType) {
    case kAppTypeDesktopRemote:
      draggablePositions.load();
      widget = DesktopRemoteScreen(
        params: argument,
      );
      break;
    case kAppTypeDesktopFileTransfer:
      widget = DesktopFileTransferScreen(
        params: argument,
      );
      break;
    case kAppTypeDesktopViewCamera:
      draggablePositions.load();
      widget = DesktopViewCameraScreen(
        params: argument,
      );
      break;
    case kAppTypeDesktopPortForward:
      widget = DesktopPortForwardScreen(
        params: argument,
      );
      break;
    case kAppTypeDesktopTerminal:
      widget = DesktopTerminalScreen(
        params: argument,
      );
      break;
    default:
      // no such appType
      exit(0);
  }
  _runApp(
    title,
    widget,
    MyTheme.currentThemeMode(),
  );
  // 🔴🔴 「描き始めた」と親に知らせる（2026-08-20・5回目のご指摘）。
  //
  //   ここまで来られなかった窓は「Loading...」の板のまま残る。
  //   ⚠ これまでの歯止めは**身に覚えの無い窓**しか閉じられず、
  //     こちらが作って登録まで済ませた窓には届かなかった。
  //   ★知らせが来ない窓は、親が閉じる（multi_window_manager.dart）。
  //   ⚠ 失敗しても先へ進む。知らせが送れないこと自体で、
  //     お客様の画面を止めてはいけない。
  try {
    await rustDeskWinManager
        .call(WindowType.Main, kWindowEventAlive, {"id": kWindowId!});
  } catch (e) {
    debugPrint('RL: 親へ「描き始めた」を知らせられませんでした: $e');
  }
  // we do not hide titlebar on win7 because of the frame overflow.
  if (kUseCompatibleUiMode) {
    WindowController.fromWindowId(kWindowId!).showTitleBar(true);
  }
  switch (appType) {
    case kAppTypeDesktopRemote:
      // If screen rect is set, the window will be moved to the target screen and then set fullscreen.
      if (argument['screen_rect'] == null) {
        // display can be used to control the offset of the window.
        await restoreWindowPosition(
          WindowType.RemoteDesktop,
          windowId: kWindowId!,
          peerId: argument['id'] as String?,
          display: argument['display'] as int?,
        );
      }
      break;
    case kAppTypeDesktopFileTransfer:
      await restoreWindowPosition(WindowType.FileTransfer,
          windowId: kWindowId!);
      break;
    case kAppTypeDesktopViewCamera:
      // If screen rect is set, the window will be moved to the target screen and then set fullscreen.
      if (argument['screen_rect'] == null) {
        // display can be used to control the offset of the window.
        await restoreWindowPosition(
          WindowType.ViewCamera,
          windowId: kWindowId!,
          peerId: argument['id'] as String?,
          // FIXME: fix display index.
          display: argument['display'] as int?,
        );
      }
      break;
    case kAppTypeDesktopPortForward:
      await restoreWindowPosition(WindowType.PortForward, windowId: kWindowId!);
      break;
    case kAppTypeDesktopTerminal:
      await restoreWindowPosition(WindowType.Terminal, windowId: kWindowId!);
      break;
    default:
      // no such appType
      exit(0);
  }
  // show window from hidden status
  WindowController.fromWindowId(kWindowId!).show();
}

void runConnectionManagerScreen() async {
  // ⚠ 1本のアプリはプロセスを2つ以上持つ。どちらが書いた行かを分ける。
  rlTraceSetRole('cm');
  rlTrace('cm_start');
  await initEnv(kAppTypeConnectionManager);
  _runApp(
    '',
    const DesktopServerPage(),
    MyTheme.currentThemeMode(),
  );
  // 🔴 お客様の画面にメニューを2つ出さない（2026-08-04 ご指摘）。
  //
  //   顧客用のワンタイム版では、当社の画面（接続コード・接続時間・終了する）が
  //   必ず出ている。そこへ RustDesk 由来の接続管理の窓が並ぶと、
  //   **お客様には「終了」の場所が2つ**あるように見える。
  //
  //   隠してよいと言える理由は1つだけ：**止める手段が減らないこと**。
  //     接続管理の「切断」  … 接続を切る
  //     当社の「終了する」  … 接続を切る＋被操作を止める＋合言葉を無効化
  //                           ＋再起動時の自動起動を消す＋サーバーへ終了を伝える
  //   当社の画面のほうが確実に止まる。だから消してよい。
  //
  //   ⚠ ここを**ワンタイム版だけ**に限ること。相談員のPCには当社の画面が無いので、
  //     隠すと「顧客に操作されても止められない」という最悪の事故に戻る
  //     （2026-07-26 に実際に起こしている。password_security.rs の hide_cm も参照）。
  final hide = kRlSupportShowWindow ||
      await bind.cmGetConfig(name: "hide_cm") == 'true';
  gFFI.serverModel.hideCm = hide;
  if (hide) {
    await hideCmWindow(isStartup: true);
  } else {
    await showCmWindow(isStartup: true);
  }
  setResizable(false);
  // Start the uni links handler and redirect links to Native, not for Flutter.
  listenUniLinks(handleByFlutter: false);
}

bool _isCmReadyToShow = false;

showCmWindow({bool isStartup = false}) async {
  if (isStartup) {
    WindowOptions windowOptions = getHiddenTitleBarWindowOptions(
        size: kConnectionManagerWindowSizeClosedChat, alwaysOnTop: true);
    await windowManager.waitUntilReadyToShow(windowOptions, null);
    bind.mainHideDock();
    await Future.wait([
      windowManager.show(),
      windowManager.focus(),
      windowManager.setOpacity(1)
    ]);
    // ensure initial window size to be changed
    await windowManager.setSizeAlignment(
        kConnectionManagerWindowSizeClosedChat, Alignment.topRight);
    _isCmReadyToShow = true;
  } else if (_isCmReadyToShow) {
    if (await windowManager.getOpacity() != 1) {
      await windowManager.setOpacity(1);
      await windowManager.focus();
      await windowManager.minimize(); //needed
      await windowManager.setSizeAlignment(
          kConnectionManagerWindowSizeClosedChat, Alignment.topRight);
      windowOnTop(null);
    }
  }
}

/// 🔴 隠してある「接続の窓」を、**確実に**出す（2026-08-26）。
///
///   ⚠ upstream の showCmWindow() では出し切れない。穴が2つある:
///     ① `_isCmReadyToShow` が立つ前に呼ぶと**何もしない**。
///        接続が来た瞬間に呼ぶと、起動処理が終わっておらず取りこぼす。
///     ② hideCmWindow() は `windowManager.hide()` まで呼んでいるのに、
///        showCmWindow() は `show()` を呼ばない。透明を戻すだけなので
///        **タスクバーには居るのに出てこない**（実機で発生）。
///
///   ★用意ができるまで待ってから、show + 不透明 + 最小化解除 + 前面 まで
///     全部やる。ここを通らないと、隠す設定の版では**知らせが全部消える**。
///
/// ⚠ 使うのは「隠す設定でも必ず出さねばならない」場面だけ:
///   ・チャットが届いた ・音声通話の着信 ・自分の画面を見せている（戻す釦）
///   普段の表示は showCmWindow() のままでよい。
Future<void> forceShowCmWindow() async {
  // 用意ができるまで最大4秒待つ。⚠ 待たずに諦めると起動直後を取りこぼす。
  for (var i = 0; i < 20; i++) {
    if (_isCmReadyToShow) break;
    await Future.delayed(const Duration(milliseconds: 200));
  }
  try {
    await windowManager.setOpacity(1);
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.show();
    await windowManager.focus();
    await windowManager.setSizeAlignment(
        kConnectionManagerWindowSizeClosedChat, Alignment.topRight);
    windowOnTop(null);
  } catch (e) {
    debugPrint('接続の窓を出せませんでした: $e');
  }
}

hideCmWindow({bool isStartup = false}) async {
  if (isStartup) {
    WindowOptions windowOptions = getHiddenTitleBarWindowOptions(
        size: kConnectionManagerWindowSizeClosedChat);
    windowManager.setOpacity(0);
    await windowManager.waitUntilReadyToShow(windowOptions, null);
    bind.mainHideDock();
    await windowManager.minimize();
    await windowManager.hide();
    _isCmReadyToShow = true;
  } else if (_isCmReadyToShow) {
    if (await windowManager.getOpacity() != 0) {
      await windowManager.setOpacity(0);
      bind.mainHideDock();
      await windowManager.minimize();
      await windowManager.hide();
    }
  }
}

void _runApp(
  String title,
  Widget home,
  ThemeMode themeMode,
) {
  final botToastBuilder = BotToastInit();
  runApp(RefreshWrapper(
    builder: (context) => GetMaterialApp(
      navigatorKey: globalKey,
      debugShowCheckedModeBanner: false,
      title: title,
      theme: MyTheme.lightTheme,
      darkTheme: MyTheme.darkTheme,
      themeMode: themeMode,
      home: home,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: supportedLocales,
      navigatorObservers: [
        // FirebaseAnalyticsObserver(analytics: analytics),
        BotToastNavigatorObserver(),
      ],
      builder: (context, child) {
        child = _keepScaleBuilder(context, child);
        child = botToastBuilder(context, child);
        return child;
      },
    ),
  ));
}

void runInstallPage() async {
  await windowManager.ensureInitialized();
  await initEnv(kAppTypeMain);
  _runApp('', const InstallPage(), MyTheme.currentThemeMode());
  WindowOptions windowOptions =
      getHiddenTitleBarWindowOptions(size: Size(800, 600), center: true);
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    windowManager.show();
    windowManager.focus();
    windowManager.setOpacity(1);
    windowManager.setAlignment(Alignment.center); // ensure
  });
}

WindowOptions getHiddenTitleBarWindowOptions(
    {bool isMainWindow = false,
    Size? size,
    bool center = false,
    bool? alwaysOnTop}) {
  var defaultTitleBarStyle = TitleBarStyle.hidden;
  // we do not hide titlebar on win7 because of the frame overflow.
  if (kUseCompatibleUiMode) {
    defaultTitleBarStyle = TitleBarStyle.normal;
  }
  return WindowOptions(
    size: size,
    center: center,
    backgroundColor: (isMacOS && isMainWindow) ? null : Colors.transparent,
    skipTaskbar: false,
    titleBarStyle: defaultTitleBarStyle,
    alwaysOnTop: alwaysOnTop,
  );
}

class App extends StatefulWidget {
  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.window.onPlatformBrightnessChanged = () {
      final userPreference = MyTheme.getThemeModePreference();
      if (userPreference != ThemeMode.system) return;
      WidgetsBinding.instance.handlePlatformBrightnessChanged();
      final systemIsDark =
          WidgetsBinding.instance.platformDispatcher.platformBrightness ==
              Brightness.dark;
      final ThemeMode to;
      if (systemIsDark) {
        to = ThemeMode.dark;
      } else {
        to = ThemeMode.light;
      }
      Get.changeThemeMode(to);
      // Synchronize the window theme of the system.
      updateSystemWindowTheme();
      if (desktopType == DesktopType.main) {
        bind.mainChangeTheme(dark: to.toShortString());
      }
    };
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateOrientation());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    _updateOrientation();
  }

  void _updateOrientation() {
    if (isDesktop) return;

    // Don't use `MediaQuery.of(context).orientation` in `didChangeMetrics()`,
    // my test (Flutter 3.19.6, Android 14) is always the reverse value.
    // https://github.com/flutter/flutter/issues/60899
    // stateGlobal.isPortrait.value =
    //     MediaQuery.of(context).orientation == Orientation.portrait;

    final orientation = View.of(context).physicalSize.aspectRatio > 1
        ? Orientation.landscape
        : Orientation.portrait;
    stateGlobal.isPortrait.value = orientation == Orientation.portrait;
  }

  @override
  Widget build(BuildContext context) {
    // final analytics = FirebaseAnalytics.instance;
    final botToastBuilder = BotToastInit();
    return RefreshWrapper(builder: (context) {
      return MultiProvider(
        providers: [
          // global configuration
          // use session related FFI when in remote control or file transfer page
          ChangeNotifierProvider.value(value: gFFI.ffiModel),
          ChangeNotifierProvider.value(value: gFFI.imageModel),
          ChangeNotifierProvider.value(value: gFFI.cursorModel),
          ChangeNotifierProvider.value(value: gFFI.canvasModel),
          ChangeNotifierProvider.value(value: gFFI.peerTabModel),
        ],
        child: GetMaterialApp(
          navigatorKey: globalKey,
          debugShowCheckedModeBanner: false,
          title: isWeb
              ? '${bind.mainGetAppNameSync()} Web Client V2 (Preview)'
              : bind.mainGetAppNameSync(),
          theme: MyTheme.lightTheme,
          darkTheme: MyTheme.darkTheme,
          themeMode: MyTheme.currentThemeMode(),
          home: isDesktop
              ? const DesktopTabPage()
              : isWeb
                  ? WebHomePage()
                  : HomePage(),
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: supportedLocales,
          navigatorObservers: [
            // FirebaseAnalyticsObserver(analytics: analytics),
            BotToastNavigatorObserver(),
          ],
          builder: isAndroid
              ? (context, child) => AccessibilityListener(
                    child: MediaQuery(
                      data: MediaQuery.of(context).copyWith(
                        textScaler: TextScaler.linear(1.0),
                      ),
                      child: child ?? Container(),
                    ),
                  )
              : (context, child) {
                  child = _keepScaleBuilder(context, child);
                  child = botToastBuilder(context, child);
                  if ((isDesktop && desktopType == DesktopType.main) ||
                      isWebDesktop) {
                    child = keyListenerBuilder(context, child);
                  }
                  if (isLinux) {
                    return buildVirtualWindowFrame(context, child);
                  } else {
                    return workaroundWindowBorder(context, child);
                  }
                },
        ),
      );
    });
  }
}

Widget _keepScaleBuilder(BuildContext context, Widget? child) {
  return MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(1.0),
    ),
    child: child ?? Container(),
  );
}

_registerEventHandler() {
  if (isDesktop && desktopType != DesktopType.main) {
    platformFFI.registerEventHandler('theme', 'theme', (evt) async {
      String? dark = evt['dark'];
      if (dark != null) {
        await MyTheme.changeDarkMode(MyTheme.themeModeFromString(dark));
      }
    });
    platformFFI.registerEventHandler('language', 'language', (_) async {
      reloadAllWindows();
    });
  }
  // Register native handlers.
  if (isDesktop) {
    platformFFI.registerEventHandler('native_ui', 'native_ui', (evt) async {
      NativeUiHandler.instance.onEvent(evt);
    });
  }
}

Widget keyListenerBuilder(BuildContext context, Widget? child) {
  return RawKeyboardListener(
    focusNode: FocusNode(),
    child: child ?? Container(),
    onKey: (RawKeyEvent event) {
      if (event.logicalKey == LogicalKeyboardKey.shiftLeft) {
        if (event is RawKeyDownEvent) {
          gFFI.peerTabModel.setShiftDown(true);
        } else if (event is RawKeyUpEvent) {
          gFFI.peerTabModel.setShiftDown(false);
        }
      }
    },
  );
}
