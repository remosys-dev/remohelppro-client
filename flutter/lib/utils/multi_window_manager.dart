import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/main.dart';
import 'package:flutter_hbb/models/input_model.dart';

/// must keep the order
// ignore: constant_identifier_names
enum WindowType {
  Main,
  RemoteDesktop,
  FileTransfer,
  ViewCamera,
  PortForward,
  Terminal,
  Unknown
}

extension Index on int {
  WindowType get windowType {
    switch (this) {
      case 0:
        return WindowType.Main;
      case 1:
        return WindowType.RemoteDesktop;
      case 2:
        return WindowType.FileTransfer;
      case 3:
        return WindowType.ViewCamera;
      case 4:
        return WindowType.PortForward;
      case 5:
        return WindowType.Terminal;
      default:
        return WindowType.Unknown;
    }
  }
}

class MultiWindowCallResult {
  int windowId;
  dynamic result;

  MultiWindowCallResult(this.windowId, this.result);
}

/// Window Manager
/// mainly use it in `Main Window`
/// use it in sub window is not recommended
class RustDeskMultiWindowManager {
  RustDeskMultiWindowManager._();

  static final instance = RustDeskMultiWindowManager._();

  final Set<int> _inactiveWindows = {};
  final Set<int> _activeWindows = {};
  final List<AsyncCallback> _windowActiveCallbacks = List.empty(growable: true);
  final List<int> _remoteDesktopWindows = List.empty(growable: true);
  final List<int> _fileTransferWindows = List.empty(growable: true);
  final List<int> _viewCameraWindows = List.empty(growable: true);
  final List<int> _portForwardWindows = List.empty(growable: true);
  final List<int> _terminalWindows = List.empty(growable: true);

  moveTabToNewWindow(int windowId, String peerId, String sessionId,
      WindowType windowType) async {
    var params = {
      'type': windowType.index,
      'id': peerId,
      'tab_window_id': windowId,
      'session_id': sessionId,
    };
    if (windowType == WindowType.RemoteDesktop) {
      await _newSession(
        false,
        WindowType.RemoteDesktop,
        kWindowEventNewRemoteDesktop,
        peerId,
        _remoteDesktopWindows,
        jsonEncode(params),
      );
    } else if (windowType == WindowType.ViewCamera) {
      await _newSession(
        false,
        WindowType.ViewCamera,
        kWindowEventNewViewCamera,
        peerId,
        _viewCameraWindows,
        jsonEncode(params),
      );
    }
  }

  // This function must be called in the main window thread.
  // Because the _remoteDesktopWindows is managed in that thread.
  openMonitorSession(int windowId, String peerId, int display, int displayCount,
      Rect? screenRect, int windowType) async {
    final isCamera = windowType == WindowType.ViewCamera.index;
    final windowIDs = isCamera ? _viewCameraWindows : _remoteDesktopWindows;
    if (windowIDs.length > 1) {
      for (final windowId in windowIDs) {
        if (await DesktopMultiWindow.invokeMethod(
            windowId,
            kWindowEventActiveDisplaySession,
            jsonEncode({
              'id': peerId,
              'display': display,
            }))) {
          return;
        }
      }
    }

    final displays = display == kAllDisplayValue
        ? List.generate(displayCount, (index) => index)
        : [display];
    var params = {
      'type': windowType,
      'id': peerId,
      'tab_window_id': windowId,
      'display': display,
      'displays': displays,
    };
    if (screenRect != null) {
      params['screen_rect'] = {
        'l': screenRect.left,
        't': screenRect.top,
        'r': screenRect.right,
        'b': screenRect.bottom,
      };
    }
    await _newSession(
      false,
      windowType.windowType,
      isCamera ? kWindowEventNewViewCamera : kWindowEventNewRemoteDesktop,
      peerId,
      windowIDs,
      jsonEncode(params),
      screenRect: screenRect,
    );
  }

  Future<int> newSessionWindow(
    WindowType type,
    String remoteId,
    String msg,
    List<int> windows,
    bool withScreenRect,
  ) async {
    final windowController = await DesktopMultiWindow.createWindow(msg);
    if (isWindows) {
      windowController.setInitBackgroundColor(Colors.black);
    }
    final windowId = windowController.windowId;
    if (!withScreenRect) {
      windowController
        ..setFrame(const Offset(0, 0) &
            Size(1280 + windowId * 20, 720 + windowId * 20))
        ..center()
        ..setTitle(getWindowNameWithId(
          remoteId,
          overrideType: type,
        ));
    } else {
      windowController.setTitle(getWindowNameWithId(
        remoteId,
        overrideType: type,
      ));
    }
    // 🔴🔴 窓を**必ず前に出す**（2026-08-30 ご指摘）。
    //
    //   ⚠ 元は `if (isMacOS)` だけだった。＝ Windows では窓を作るだけで、
    //     見せる処理をしていなかった。
    //   ⚠ Windows は、前面に居ないプログラムが窓を出そうとすると
    //     **前面化を拒否してタスクバーを点滅させるだけ**にする。
    //     相談員はブラウザ（コンソール）を見ているので必ずこれに当たる。
    //   ＝ ご報告「もう一度開く で戻っても全画面にならずタスクバーに隠れる。
    //     アイコンを押さないと見えない」の正体。
    //   ★作ったら見せる。見せたら前に出す。Mac だけの話ではない。
    Future.microtask(() async {
      try {
        await windowController.show();
        await windowController.focus();
        // 🔴🔴 `show()` と `focus()` だけでは**足りない**（2026-09-03 実機で確定）。
        //
        //   ⚠ ご報告:「自分の画面を見せる」の1回目、相談員の戻る画面も
        //     お客様側のビュアーも⚠ **タスクバーに隠れて気づけなかった**。
        //   ⚠ Windows は、前面に居ないプログラムからの前面化を**拒否**し、
        //     タスクバーを光らせるだけにする。＝ 出したつもりで出ていない。
        //   ★接続の窓（cm）で実績のある手を、こちらにも当てる:
        //     **一度だけ最前面に固定して、すぐ外す。**
        //   ⚠ 固定したままにしない。他の窓の上に居座る。
        await windowController.setAlwaysOnTop(true);
        await Future.delayed(const Duration(milliseconds: 400));
        await windowController.setAlwaysOnTop(false);
      } catch (e) {
        debugPrint('接続の窓を前に出せませんでした: $e');
      }
    });
    registerActiveWindow(windowId);
    windows.add(windowId);
    return windowId;
  }

  Future<MultiWindowCallResult> _newSession(
    bool openInTabs,
    WindowType type,
    String methodName,
    String remoteId,
    List<int> windows,
    String msg, {
    Rect? screenRect,
  }) async {
    if (openInTabs) {
      if (windows.isEmpty) {
        final windowId = await newSessionWindow(
            type, remoteId, msg, windows, screenRect != null);
        return MultiWindowCallResult(windowId, null);
      } else {
        final res = await call(type, methodName, msg);
        // 🔴 既にある窓に足したときも**前に出す**（2026-08-30）。
        //   ⚠ 新しく作るときだけ前に出しても、2回目以降は
        //     タスクバーで点滅するだけになる。同じ症状が残る。
        for (final windowId in windows) {
          try {
            final c = WindowController.fromWindowId(windowId);
            await c.show();
            await c.focus();
          } catch (e) {
            debugPrint('接続の窓を前に出せませんでした($windowId): $e');
          }
        }
        return res;
      }
    } else {
      if (_inactiveWindows.isNotEmpty) {
        for (final windowId in windows) {
          if (_inactiveWindows.contains(windowId)) {
            if (screenRect == null) {
              await restoreWindowPosition(type,
                  windowId: windowId, peerId: remoteId);
            }
            await DesktopMultiWindow.invokeMethod(windowId, methodName, msg);
            // 🔴🔴 **使い回すときも必ず前に出す**（2026-09-03 実機で確定）。
            //
            //   ⚠ ここは元は「遠隔操作のときだけ show() しない」だった。
            //     ＝ 2回目以降、⚠ **窓はあるのにタスクバーに隠れたまま**。
            //   ⚠ 2026-08-30 に「必ず前に出す」直しを入れたが、入れたのは
            //     ⚠ **タブにまとめる側だけ**だった。この製品は別ウィンドウ方式
            //     なので、⚠ **実際に使われている方の道には入っていなかった。**
            //   ★同じ壁は入口ごとに塞ぐ。
            try {
              final c = WindowController.fromWindowId(windowId);
              await c.show();
              await c.focus();
              await c.setAlwaysOnTop(true);
              await Future.delayed(const Duration(milliseconds: 400));
              await c.setAlwaysOnTop(false);
            } catch (e) {
              debugPrint('接続の窓を前に出せませんでした($windowId): $e');
            }
            registerActiveWindow(windowId);
            return MultiWindowCallResult(windowId, null);
          }
        }
      }
      final windowId = await newSessionWindow(
          type, remoteId, msg, windows, screenRect != null);
      return MultiWindowCallResult(windowId, null);
    }
  }

  Future<MultiWindowCallResult> newSession(
    WindowType type,
    String methodName,
    String remoteId,
    List<int> windows, {
    String? password,
    bool? forceRelay,
    String? switchUuid,
    bool? isRDP,
    bool? isSharedPassword,
    String? connToken,
  }) async {
    var params = {
      "type": type.index,
      "id": remoteId,
      "password": password,
      "forceRelay": forceRelay
    };
    if (switchUuid != null) {
      params['switch_uuid'] = switchUuid;
    }
    if (isRDP != null) {
      params['isRDP'] = isRDP;
    }
    if (isSharedPassword != null) {
      params['isSharedPassword'] = isSharedPassword;
    }
    if (connToken != null) {
      params['connToken'] = connToken;
    }
    final msg = jsonEncode(params);

    // separate window for file transfer is not supported
    bool openInTabs = type != WindowType.RemoteDesktop ||
        mainGetLocalBoolOptionSync(kOptionOpenNewConnInTabs);

    if (windows.length > 1 || !openInTabs) {
      for (final windowId in windows) {
        if (await DesktopMultiWindow.invokeMethod(
            windowId, kWindowEventActiveSession, remoteId)) {
          return MultiWindowCallResult(windowId, null);
        }
      }
    }

    return _newSession(openInTabs, type, methodName, remoteId, windows, msg);
  }

  Future<MultiWindowCallResult> newRemoteDesktop(
    String remoteId, {
    String? password,
    bool? isSharedPassword,
    String? switchUuid,
    bool? forceRelay,
  }) async {
    return await newSession(
      WindowType.RemoteDesktop,
      kWindowEventNewRemoteDesktop,
      remoteId,
      _remoteDesktopWindows,
      password: password,
      forceRelay: forceRelay,
      switchUuid: switchUuid,
      isSharedPassword: isSharedPassword,
    );
  }

  Future<MultiWindowCallResult> newFileTransfer(
    String remoteId, {
    String? password,
    bool? isSharedPassword,
    bool? forceRelay,
    String? connToken,
  }) async {
    return await newSession(
      WindowType.FileTransfer,
      kWindowEventNewFileTransfer,
      remoteId,
      _fileTransferWindows,
      password: password,
      forceRelay: forceRelay,
      isSharedPassword: isSharedPassword,
      connToken: connToken,
    );
  }

  Future<MultiWindowCallResult> newViewCamera(
    String remoteId, {
    String? password,
    bool? isSharedPassword,
    String? switchUuid,
    bool? forceRelay,
    String? connToken,
  }) async {
    return await newSession(
      WindowType.ViewCamera,
      kWindowEventNewViewCamera,
      remoteId,
      _viewCameraWindows,
      password: password,
      forceRelay: forceRelay,
      switchUuid: switchUuid,
      isSharedPassword: isSharedPassword,
      connToken: connToken,
    );
  }

  Future<MultiWindowCallResult> newPortForward(
    String remoteId,
    bool isRDP, {
    String? password,
    bool? isSharedPassword,
    bool? forceRelay,
    String? connToken,
  }) async {
    return await newSession(
      WindowType.PortForward,
      kWindowEventNewPortForward,
      remoteId,
      _portForwardWindows,
      password: password,
      forceRelay: forceRelay,
      isRDP: isRDP,
      isSharedPassword: isSharedPassword,
      connToken: connToken,
    );
  }

  Future<MultiWindowCallResult> newTerminal(
    String remoteId, {
    String? password,
    bool? isSharedPassword,
    bool? forceRelay,
    String? connToken,
  }) async {
    // Iterate through terminal windows in reverse order to prioritize
    // the most recently added or used windows, as they are more likely
    // to have an active session.
    for (final windowId in _terminalWindows.reversed) {
      if (await DesktopMultiWindow.invokeMethod(
          windowId, kWindowEventActiveSession, remoteId)) {
        return MultiWindowCallResult(windowId, null);
      }
    }

    // Terminal windows should always create new windows, not reuse
    // This avoids the MissingPluginException when trying to invoke
    // new_terminal on an inactive window
    var params = {
      "type": WindowType.Terminal.index,
      "id": remoteId,
      "password": password,
      "forceRelay": forceRelay,
      "isSharedPassword": isSharedPassword,
      "connToken": connToken,
    };
    final msg = jsonEncode(params);

    // Always create a new window for terminal
    final windowId = await newSessionWindow(
        WindowType.Terminal, remoteId, msg, _terminalWindows, false);
    return MultiWindowCallResult(windowId, null);
  }

  Future<MultiWindowCallResult> call(
      WindowType type, String methodName, dynamic args) async {
    final wnds = _findWindowsByType(type);
    if (wnds.isEmpty) {
      return MultiWindowCallResult(kInvalidWindowId, null);
    }
    for (final windowId in wnds) {
      if (_activeWindows.contains(windowId)) {
        final res =
            await DesktopMultiWindow.invokeMethod(windowId, methodName, args);
        return MultiWindowCallResult(windowId, res);
      }
    }
    final res =
        await DesktopMultiWindow.invokeMethod(wnds[0], methodName, args);
    return MultiWindowCallResult(wnds[0], res);
  }

  List<int> _findWindowsByType(WindowType type) {
    switch (type) {
      case WindowType.Main:
        return [kMainWindowId];
      case WindowType.RemoteDesktop:
        return _remoteDesktopWindows;
      case WindowType.FileTransfer:
        return _fileTransferWindows;
      case WindowType.ViewCamera:
        return _viewCameraWindows;
      case WindowType.PortForward:
        return _portForwardWindows;
      case WindowType.Terminal:
        return _terminalWindows;
      case WindowType.Unknown:
        break;
    }
    return [];
  }

  void clearWindowType(WindowType type) {
    switch (type) {
      case WindowType.Main:
        return;
      case WindowType.RemoteDesktop:
        _remoteDesktopWindows.clear();
        break;
      case WindowType.FileTransfer:
        _fileTransferWindows.clear();
        break;
      case WindowType.ViewCamera:
        _viewCameraWindows.clear();
        break;
      case WindowType.PortForward:
        _portForwardWindows.clear();
        break;
      case WindowType.Terminal:
        _terminalWindows.clear();
      case WindowType.Unknown:
        break;
    }
  }

  /// 🔴🔴 「描き始めた」の合図は、**必ずここで受ける**（2026-08-20）。
  ///
  ///   受け口を画面（desktop_home_page 等）に置くと、
  ///   ⚠ **その画面を通らない作り（お客様の一回版）で受け取れない**。
  ///   合図が来ない＝どの窓にも印が付かない＝
  ///   ⚠ **12秒後に正規の遠隔画面まで閉じる**。作った当日に気づいた。
  ///
  ///   ★どの画面が handler を差し替えても、合図だけは必ずここを通る。
  ///   ⚠ 画面が handler を一度も設定しない場合に備え、
  ///     main.dart で起動時に一度 `setMethodHandler(null)` を呼び、
  ///     この包みを必ず据え付ける。
  void setMethodHandler(
      Future<dynamic> Function(MethodCall call, int fromWindowId)? handler) {
    DesktopMultiWindow.setMethodHandler((call, fromWindowId) async {
      if (call.method == kWindowEventAlive) {
        final id = call.arguments is Map ? call.arguments['id'] : null;
        if (id is int) markWindowAlive(id);
        return null;
      }
      if (handler == null) return null;
      return await handler(call, fromWindowId);
    });
  }

  Future<void> closeAllSubWindows() async {
    await Future.wait(WindowType.values.map((e) => _closeWindows(e)));
  }

  Future<void> _closeWindows(WindowType type) async {
    if (type == WindowType.Main) {
      // skip main window, use window manager instead
      return;
    }

    List<int> windows = [];
    try {
      windows = _findWindowsByType(type);
    } catch (e) {
      debugPrint('Failed to getAllSubWindowIds of $type, $e');
      return;
    }

    if (windows.isEmpty) {
      return;
    }
    for (int i = 0; i < windows.length; i++) {
      final wId = windows[i];
      final shouldSavePos = type != WindowType.Terminal || i == windows.length - 1;
      if (shouldSavePos) {
        debugPrint("closing multi window, type: ${type.toString()} id: $wId");
        try {
          await saveWindowPosition(type, windowId: wId);
        } catch (e) {
          debugPrint('Failed to save window position of $wId, $e');
        }
      }
      try {
        await WindowController.fromWindowId(wId).setPreventClose(false);
        await WindowController.fromWindowId(wId).close();
        _activeWindows.remove(wId);
      } catch (e) {
        debugPrint("$e");
        return;
      }
    }
    clearWindowType(type);
  }

  Future<List<int>> getAllSubWindowIds() async {
    try {
      final windows = await DesktopMultiWindow.getAllSubWindowIds();
      return windows;
    } catch (err) {
      if (err is AssertionError) {
        return [];
      } else {
        rethrow;
      }
    }
  }

  Set<int> getActiveWindows() {
    return _activeWindows;
  }

  /// 誰のものでもない子ウィンドウを見つけて閉じる。
  ///
  /// 🔴🔴 「Loading...」の窓が消えない件（2026-08-04 発覚・08-08 に作り直し）。
  ///
  ///   子ウィンドウの中身は、その窓自身の Dart（main.dart の multi_window 分岐）が
  ///   描く。ところが**その Dart にたどり着けない**ことがあり、そのときは
  ///   何も描かれないまま「Loading...」の板だけが残る。
  ///   閉じ方も分からないので、お客様の画面に居座り続ける。
  ///
  ///   ⚠ 2026-08-04 に main.dart の default: へ「自分で閉じる」歯止めを入れたが、
  ///     **効かなかった**。当然で、あれは**その窓の Dart が動いた場合**の話。
  ///     動かないから残っているのに、動いた前提の手当てをしていた。
  ///     3回ご指摘をいただいて、ようやくそこに気づいた。
  ///
  ///   ★閉じられるのは、外から見ている**メインウィンドウだけ**。
  ///     OS が持っている子ウィンドウの一覧と、こちらが把握している一覧を
  ///     突き合わせ、身に覚えの無いものを閉じる。
  ///
  /// ⚠ 作りかけの窓を巻き込まない。窓は「作られてから登録されるまで」に
  ///   わずかな間がある。**2回続けて身に覚えが無かったものだけ**閉じる。
  ///   点検の間隔は main.dart で3秒（＝閉じるまで最大6秒）。
  ///
  /// ⚠⚠ **この歯止めが届かない場合がある**（2026-08-14 時点で未解決）。
  ///   ここが閉じるのは「身に覚えの無い」窓だけ。こちらが createWindow で
  ///   作って registerActiveWindow まで済ませた窓は**知っている窓**なので、
  ///   その中身（子側の Dart）が動かなくても閉じない。
  ///   ＝ 子の `runMultiWindow` が `initEnv` などで止まると、
  ///     「Loading...」のまま**永久に残る**。
  ///   ★本筋の直しは「子が描き始めたことを親に知らせ、知らせが来ない窓は閉じる」。
  ///     まだ入れていない。実機で「6秒で消えるか」を確かめてから判断する。
  /// ⚠ メインウィンドウ自身は決して触らない。
  /// ⚠ メインウィンドウからのみ呼ぶこと（_activeWindows を知っているのはここだけ）。
  final Set<int> _strayCandidates = {};

  /// 「描き始めた」と知らせてきた子ウィンドウ。
  ///
  /// 🔴🔴 本筋の直し（2026-08-20・5回目のご指摘）。
  ///   これが**来ない窓は、中身が動いていない**＝「Loading...」の板だけ。
  ///   ⚠ 知っている窓（こちらが作った窓）でも、動いていなければ閉じる。
  final Set<int> _aliveWindows = {};

  /// 子から知らせが来た時刻を待つ猶予。
  ///
  /// ⚠ 短くしすぎない。窓は「作られてから中身が描き始めるまで」に間がある
  ///   （createWindow → 子プロセスの Dart 起動 → initEnv → runApp）。
  ///   実測で1秒未満だが、遅い機械や初回起動では伸びる。
  /// ⚠ 長くしすぎない。その間ずっと、お客様の画面に
  ///   閉じ方の分からない板が出たままになる。
  static const _aliveGraceSecs = 12;
  final Map<int, DateTime> _firstSeenWithoutAlive = {};

  /// 子ウィンドウが「描き始めた」と知らせてきた。
  void markWindowAlive(int windowId) {
    _aliveWindows.add(windowId);
    _firstSeenWithoutAlive.remove(windowId);
  }

  void forgetWindow(int windowId) {
    _aliveWindows.remove(windowId);
    _firstSeenWithoutAlive.remove(windowId);
    _strayCandidates.remove(windowId);
  }

  Future<void> closeStrayWindows() async {
    try {
      final all = await getAllSubWindowIds();
      final known = <int>{..._activeWindows, ..._inactiveWindows, kMainWindowId};
      final unknown = all.where((id) => !known.contains(id)).toSet();
      // 🔴🔴 知っている窓でも、**中身が動いていなければ閉じる**（2026-08-20）。
      //   これまではここが抜けており、5回ご指摘をいただいても直らなかった。
      //
      // ⚠⚠ 安全弁: **合図を一度も受け取っていないうちは、何も閉じない**。
      //   合図の道が塞がっている環境（受け口が据わっていない・古い版の子など）では、
      //   すべての窓が「動いていない」と見えてしまい、
      //   ⚠ **正規の遠隔画面まで閉じる**。それは今の不具合よりずっと悪い。
      //   ★1つでも合図が届いていれば、道は通っていると分かる。
      final signalWorks = _aliveWindows.isNotEmpty;
      final now = DateTime.now();
      for (final id in all) {
        if (!signalWorks) break;
        if (id == kMainWindowId) continue;
        if (_aliveWindows.contains(id)) continue;
        final since = _firstSeenWithoutAlive[id];
        if (since == null) {
          _firstSeenWithoutAlive[id] = now;
          continue;
        }
        if (now.difference(since).inSeconds < _aliveGraceSecs) continue;
        try {
          debugPrint('RL: 中身が動いていない子ウィンドウを閉じます id=$id');
          await WindowController.fromWindowId(id).close();
          forgetWindow(id);
          _activeWindows.remove(id);
          _inactiveWindows.remove(id);
        } catch (e) {
          debugPrint('RL: 子ウィンドウを閉じられませんでした id=$id, $e');
        }
      }
      // 既に消えた窓を覚えっぱなしにしない。
      _aliveWindows.removeWhere((id) => !all.contains(id));
      _firstSeenWithoutAlive.removeWhere((id, _) => !all.contains(id));
      // 前回も身に覚えが無かったものだけ閉じる（作りかけを巻き込まないため）。
      final toClose = unknown.intersection(_strayCandidates);
      _strayCandidates
        ..clear()
        ..addAll(unknown);
      for (final id in toClose) {
        try {
          debugPrint('RL: 身に覚えの無い子ウィンドウを閉じます id=$id');
          await WindowController.fromWindowId(id).close();
          _strayCandidates.remove(id);
        } catch (e) {
          debugPrint('RL: 子ウィンドウを閉じられませんでした id=$id, $e');
        }
      }
    } catch (e) {
      // 一覧が取れないことはある（起動直後など）。次の回に任せる。
      debugPrint('RL: 子ウィンドウの点検に失敗: $e');
    }
  }

  Future<void> _notifyActiveWindow() async {
    for (final callback in _windowActiveCallbacks) {
      await callback.call();
    }
  }

  Future<void> registerActiveWindow(int windowId) async {
    _activeWindows.add(windowId);
    _inactiveWindows.remove(windowId);
    await _notifyActiveWindow();
  }

  /// Remove active window which has [`windowId`]
  ///
  /// [Availability]
  /// This function should only be called from main window.
  /// For other windows, please post a unregister(hide) event to main window handler:
  /// `rustDeskWinManager.call(WindowType.Main, kWindowEventHide, {"id": windowId!});`
  Future<void> unregisterActiveWindow(int windowId) async {
    _activeWindows.remove(windowId);
    if (windowId != kMainWindowId) {
      _inactiveWindows.add(windowId);
    }
    await _notifyActiveWindow();
  }

  void registerActiveWindowListener(AsyncCallback callback) {
    _windowActiveCallbacks.add(callback);
  }

  void unregisterActiveWindowListener(AsyncCallback callback) {
    _windowActiveCallbacks.remove(callback);
  }

  // This function is called from the main window.
  // It will query the active remote windows to get their coords.
  Future<List<String>> getOtherRemoteWindowCoords(int wId) async {
    List<String> coords = [];
    for (final windowId in _remoteDesktopWindows) {
      if (windowId != wId) {
        if (_activeWindows.contains(windowId)) {
          final res = await DesktopMultiWindow.invokeMethod(
              windowId, kWindowEventRemoteWindowCoords, '');
          if (res != null) {
            coords.add(res);
          }
        }
      }
    }
    return coords;
  }

  // This function is called from one remote window.
  // Only the main window knows `_remoteDesktopWindows` and `_activeWindows`.
  // So we need to call the main window to get the other remote windows' coords.
  Future<List<RemoteWindowCoords>> getOtherRemoteWindowCoordsFromMain() async {
    List<RemoteWindowCoords> coords = [];
    // Call the main window to get the coords of other remote windows.
    String res = await DesktopMultiWindow.invokeMethod(
        kMainWindowId, kWindowEventRemoteWindowCoords, kWindowId.toString());
    List<dynamic> list = jsonDecode(res);
    for (var item in list) {
      coords.add(RemoteWindowCoords.fromJson(jsonDecode(item)));
    }
    return coords;
  }
}

final rustDeskWinManager = RustDeskMultiWindowManager.instance;
