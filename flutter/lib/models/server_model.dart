import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/main.dart';
import 'package:flutter_hbb/mobile/pages/settings_page.dart';
import 'package:flutter_hbb/models/chat_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/rl_support.dart';
import 'package:get/get.dart';
import 'package:window_manager/window_manager.dart';

import '../common.dart';
import '../common/formatter/id_formatter.dart';
import '../desktop/pages/server_page.dart' as desktop;
import '../desktop/widgets/tabbar_widget.dart';
import '../mobile/pages/server_page.dart';
// 終了をサーバーへ伝える受け口（顧客アプリの接続画面が預ける）。
import '../remohelppro_pairing.dart' show rlNotifySupportEnded;
import '../remohelppro_trace.dart' show rlTrace, rlTraceFlushNow;
import 'model.dart';

const kLoginDialogTag = "LOGIN";

const kUseTemporaryPassword = "use-temporary-password";
const kUsePermanentPassword = "use-permanent-password";
const kUseBothPasswords = "use-both-passwords";

class ServerModel with ChangeNotifier {
  bool _isStart = false; // Android MainService status
  bool _mediaOk = false;
  bool _inputOk = false;
  bool _audioOk = false;
  bool _fileOk = false;
  bool _clipboardOk = false;
  bool _showElevation = false;
  bool hideCm = false;
  int _connectStatus = 0; // Rendezvous Server status
  String _verificationMethod = "";
  String _temporaryPasswordLength = "";
  bool _allowNumericOneTimePassword = false;
  String _approveMode = "";
  int _zeroClientLengthCounter = 0;
  bool _hasEverConnected = false; // RL build-16 (B): 1回以上の接続実績(接続後のみ自動終了を許可)
  int _remohelpproZeroClients = 0; // REMOHELP PRO: 相談員切断後の空clients連続カウント(自動停止用)

  late String _emptyIdShow;
  late final IDTextEditingController _serverId;
  final _serverPasswd =
      TextEditingController(text: translate("Generating ..."));

  final tabController = DesktopTabController(tabType: DesktopTabType.cm);

  final List<Client> _clients = [];

  Timer? cmHiddenTimer;

  final _wakelockKey = UniqueKey();

  bool get isStart => _isStart;

  bool get mediaOk => _mediaOk;

  bool get inputOk => _inputOk;

  bool get audioOk => _audioOk;

  bool get fileOk => _fileOk;

  bool get clipboardOk => _clipboardOk;

  bool get showElevation => _showElevation;

  int get connectStatus => _connectStatus;

  String get verificationMethod {
    final index = [
      kUseTemporaryPassword,
      kUsePermanentPassword,
      kUseBothPasswords
    ].indexOf(_verificationMethod);
    if (index < 0) {
      return kUseBothPasswords;
    }
    return _verificationMethod;
  }

  String get approveMode => _approveMode;

  setVerificationMethod(String method) async {
    await bind.mainSetOption(key: kOptionVerificationMethod, value: method);
    /*
    if (method != kUsePermanentPassword) {
      await bind.mainSetOption(
          key: 'allow-hide-cm', value: bool2option('allow-hide-cm', false));
    }
    */
  }

  String get temporaryPasswordLength {
    final lengthIndex = ["6", "8", "10"].indexOf(_temporaryPasswordLength);
    if (lengthIndex < 0) {
      return "6";
    }
    return _temporaryPasswordLength;
  }

  setTemporaryPasswordLength(String length) async {
    await bind.mainSetOption(key: "temporary-password-length", value: length);
  }

  setApproveMode(String mode) async {
    await bind.mainSetOption(key: kOptionApproveMode, value: mode);
    /*
    if (mode != 'password') {
      await bind.mainSetOption(
          key: 'allow-hide-cm', value: bool2option('allow-hide-cm', false));
    }
    */
  }

  bool get allowNumericOneTimePassword => _allowNumericOneTimePassword;
  switchAllowNumericOneTimePassword() async {
    await mainSetBoolOption(
        kOptionAllowNumericOneTimePassword, !_allowNumericOneTimePassword);
  }

  TextEditingController get serverId => _serverId;

  TextEditingController get serverPasswd => _serverPasswd;

  List<Client> get clients => _clients;

  final controller = ScrollController();

  WeakReference<FFI> parent;

  ServerModel(this.parent) {
    _emptyIdShow = translate("Generating ...");
    _serverId = IDTextEditingController(text: _emptyIdShow);

    /*
    // initital _hideCm at startup
    final verificationMethod =
        bind.mainGetOptionSync(key: kOptionVerificationMethod);
    final approveMode = bind.mainGetOptionSync(key: kOptionApproveMode);
    _hideCm = option2bool(
        'allow-hide-cm', bind.mainGetOptionSync(key: 'allow-hide-cm'));
    if (!(approveMode == 'password' &&
        verificationMethod == kUsePermanentPassword)) {
      _hideCm = false;
    }
    */

    timerCallback() async {
      final connectionStatus =
          jsonDecode(await bind.mainGetConnectStatus()) as Map<String, dynamic>;
      final statusNum = connectionStatus['status_num'] as int;
      if (statusNum != _connectStatus) {
        _connectStatus = statusNum;
        notifyListeners();
      }

      if (desktopType == DesktopType.cm) {
        final res = await bind.cmCheckClientsLength(length: _clients.length);
        if (res != null) {
          debugPrint("clients not match!");
          updateClientState(res);
        } else {
          if (_clients.isEmpty) {
            hideCmWindow();
            // RL onetime fix (build-14): ワンタイム版(kRlSupportShowWindow)は Main 終了後すみやかに
            // CM プロセスも閉じる(約2秒)。通常(フリート)は従来どおり約6秒。フリートは const=false で不変。
            final _cmCloseThreshold = kRlSupportShowWindow ? 4 : 12; // 2s or 6s
            if (_zeroClientLengthCounter == 0) {
              // 🔴 数え始めた瞬間を残す（2026-08-27）。
              //   ⚠ 「消えた」ではなく「**いつ空になったか**」が知りたい。
              rlTrace('cm_zero_clients_begin',
                  {'threshold': _cmCloseThreshold, 'ever': _hasEverConnected});
            }
            if (_zeroClientLengthCounter++ >= _cmCloseThreshold) {
              // RL build-16 (B): ワンタイム版(接続実績あり)は CM窓だけでなく CMプロセスを終了。
              if (kRlSupportShowWindow && _hasEverConnected) {
                // 🔴 消える理由を残してから消える（2026-08-27）。
                rlTrace('cm_exit_zero_clients',
                    {'ticks': _zeroClientLengthCounter});
                await rlTraceFlushNow(timeout: const Duration(seconds: 2));
                exit(0); // CMプロセス全終了
              } else {
                windowManager.close(); // フリート版: 従来どおりCM窓のみ閉じる
              }
            }
          } else {
            _zeroClientLengthCounter = 0;
            if (!hideCm) showCmWindow();
          }
        }
      }

      // RL build-16 (B/D): メインプロセス(接続を保持)用の自動終了。CMは別OSプロセスのため独立チェック。
      // 相談員が切断 → _clients が空 → ワンタイム版は close_reason(安全網)送信後にプロセス終了。
      // メインプロセス終了でランナーの child.wait() が返り、展開dir+元EXEが自己削除される(C)。
      if (desktopType == DesktopType.main &&
          kRlSupportShowWindow &&
          _hasEverConnected) {
        if (_clients.isEmpty) {
          if (_zeroClientLengthCounter == 0) {
            // 🔴🔴 ここが「顧客アプリが消える」の**最有力**（2026-08-27）。
            //
            //   接続が空になってから30秒で、下の `exit(0)` がアプリを丸ごと
            //   終わらせる。⚠ 相談員がまだ繋がっているつもりでも、
            //   こちら側の数え方で空になれば、お客様のアプリは消える。
            //   ⚠ 「自分の画面を見せる」で役を入れ替えている間も、
            //     お客様側の接続は一度空になる。
            //
            //   ★まず**いつ空になったか**を残す。理由の特定はそれから。
            rlTrace('main_zero_clients_begin', {'ever': _hasEverConnected});
          }
          // 🔴 待つ時間を 2秒 → 30秒 に延ばした（2026-07-30 実機指摘）。
          //
          //   0.5秒ごとに見ているので 4 = 2秒だった。相談員がビュアーの窓を
          //   閉じただけで、2秒後にお客様のアプリが完全に終了していた。
          //   ・回線が一瞬途切れただけでも終わる
          //   ・窓を閉じ違えただけでも終わる
          //   ・**再起動をまたぐ再接続と正面からぶつかる**
          //     （再起動で接続が切れた瞬間に終了すると、戻る相手が居なくなる）
          //
          //   30秒あれば繋ぎ直せる。認証コードは変わらないので、
          //   その間に戻れるのは**同じ相談員だけ**。緩めても危険は増えない。
          if (_zeroClientLengthCounter++ >= 60) {
            // 🔴 終わったことをサーバーへ伝えてから落ちる。
            //   伝えないと、当社の画面はいつまでも「接続中」と出る。
            //   お客様のアプリは既に消えているのに相談員には繋がって見える
            //   ＝画面が嘘をつく。実際にこの食い違いが起きていた。
            rlTrace('main_exit_zero_clients', {
              'ticks': _zeroClientLengthCounter,
              'notify': rlNotifySupportEnded != null,
            });
            final notify = rlNotifySupportEnded;
            if (notify != null) {
              try {
                await notify();
              } catch (e) {
                // ⚠ 握りつぶさない（2026-08-27）。ここが失敗すると、
                //   お客様のアプリは消えたのに当社の画面は「接続中」のまま。
                //   ＝ 相談員は繋がると思って繋がらない。実際に起きていた。
                rlTrace('notify_end_failed', {'e': e.toString()});
              }
            } else {
              // ⚠ 受け口が刺さっていない＝サーバーへ誰も終了を伝えない。
              rlTrace('notify_end_missing');
            }
            try {
              await bind.mainCloseAllConnections();
            } catch (e) {
              rlTrace('close_all_failed', {'e': e.toString()});
            }
            await Future.delayed(const Duration(milliseconds: 200));
            await rlTraceFlushNow();
            exit(0); // メインプロセス全終了 → ランナーが後始末(C)
          }
        } else {
          _zeroClientLengthCounter = 0;
        }
      }

      // REMOHELP PRO: 顧客(被操作)アプリは、相談員が切断（接続実績あり かつ clients空）したら
      //   画面共有サービスを自動停止する。＝遠隔操作の後に繋がったまま放置される
      //   プライバシー/セキュリティのリスクを解消（手動「サービス停止」不要）。
      //   ※ 操作員ビルド(REMOHELPPRO_OPERATOR)には適用しない。
      if (isAndroid &&
          !const bool.fromEnvironment('REMOHELPPRO_OPERATOR') &&
          _isStart &&
          _hasEverConnected) {
        if (_clients.isEmpty) {
          // 500ms×4 ≒ 2秒 連続で誰も繋がっていなければ停止（瞬断での誤発火を防ぐ）
          if (++_remohelpproZeroClients >= 4) {
            _remohelpproZeroClients = 0;
            _hasEverConnected = false; // 二重発火防止
            await stopService();
          }
        } else {
          _remohelpproZeroClients = 0;
        }
      }

      updatePasswordModel();
    }

    if (!isTest) {
      Future.delayed(Duration.zero, () async {
        if (await bind.optionSynced()) {
          await timerCallback();
        }
      });
      Timer.periodic(Duration(milliseconds: 500), (timer) async {
        await timerCallback();
      });
    }

    // Initial keyboard status is off on mobile
    if (isMobile) {
      bind.mainSetOption(key: kOptionEnableKeyboard, value: 'N');
    }
  }

  /// 1. check android permission
  /// 2. check config
  /// audio true by default (if permission on) (false default < Android 10)
  /// file true by default (if permission on)
  checkAndroidPermission() async {
    // audio
    if (androidVersion < 30 ||
        !await AndroidPermissionManager.check(kRecordAudio)) {
      _audioOk = false;
      bind.mainSetOption(key: kOptionEnableAudio, value: "N");
    } else {
      final audioOption = await bind.mainGetOption(key: kOptionEnableAudio);
      _audioOk = audioOption != 'N';
    }

    // file
    // 🔴 権限で可否を決めるのをやめた（2026-08-10）。
    //   受け渡しはアプリ専用フォルダの中だけで完結するので、権限は関係ない。
    //   以前は権限が無い＝常に「ファイル送受信は使えない」になっていた。
    {
      final fileOption =
          await bind.mainGetOption(key: kOptionEnableFileTransfer);
      _fileOk = fileOption != 'N';
    }

    // clipboard
    final clipOption = await bind.mainGetOption(key: kOptionEnableClipboard);
    _clipboardOk = clipOption != 'N';

    notifyListeners();
  }

  updatePasswordModel() async {
    var update = false;
    final temporaryPassword = await bind.mainGetTemporaryPassword();
    final verificationMethod =
        await bind.mainGetOption(key: kOptionVerificationMethod);
    final temporaryPasswordLength =
        await bind.mainGetOption(key: "temporary-password-length");
    final approveMode = await bind.mainGetOption(key: kOptionApproveMode);
    final numericOneTimePassword =
        await mainGetBoolOption(kOptionAllowNumericOneTimePassword);
    /*
    var hideCm = option2bool(
        'allow-hide-cm', await bind.mainGetOption(key: 'allow-hide-cm'));
    if (!(approveMode == 'password' &&
        verificationMethod == kUsePermanentPassword)) {
      hideCm = false;
    }
    */
    if (_approveMode != approveMode) {
      _approveMode = approveMode;
      update = true;
    }
    var stopped = await mainGetBoolOption(kOptionStopService);
    final oldPwdText = _serverPasswd.text;
    if (stopped ||
        verificationMethod == kUsePermanentPassword ||
        _approveMode == 'click') {
      _serverPasswd.text = '-';
    } else {
      if (_serverPasswd.text != temporaryPassword &&
          temporaryPassword.isNotEmpty) {
        _serverPasswd.text = temporaryPassword;
      }
    }
    if (oldPwdText != _serverPasswd.text) {
      update = true;
    }
    if (_verificationMethod != verificationMethod) {
      _verificationMethod = verificationMethod;
      update = true;
    }
    if (_temporaryPasswordLength != temporaryPasswordLength) {
      if (_temporaryPasswordLength.isNotEmpty) {
        bind.mainUpdateTemporaryPassword();
      }
      _temporaryPasswordLength = temporaryPasswordLength;
      update = true;
    }
    if (_allowNumericOneTimePassword != numericOneTimePassword) {
      _allowNumericOneTimePassword = numericOneTimePassword;
      update = true;
    }
    /*
    if (_hideCm != hideCm) {
      _hideCm = hideCm;
      if (desktopType == DesktopType.cm) {
        if (hideCm) {
          await hideCmWindow();
        } else {
          await showCmWindow();
        }
      }
      update = true;
    }
    */
    if (update) {
      notifyListeners();
    }
  }

  toggleAudio() async {
    if (clients.any((c) => !c.disconnected)) {
      await showClientsMayNotBeChangedAlert(parent.target);
    }
    if (!_audioOk && !await AndroidPermissionManager.check(kRecordAudio)) {
      final res = await AndroidPermissionManager.request(kRecordAudio);
      if (!res) {
        showToast(translate('Failed'));
        return;
      }
    }

    _audioOk = !_audioOk;
    bind.mainSetOption(
        key: kOptionEnableAudio, value: _audioOk ? defaultOptionYes : 'N');
    notifyListeners();
  }

  toggleFile() async {
    if (clients.any((c) => !c.disconnected)) {
      await showClientsMayNotBeChangedAlert(parent.target);
    }
    // 🔴 権限の要求をやめた（2026-08-10）。受け渡しはアプリ専用フォルダで完結する。
    {
    }

    _fileOk = !_fileOk;
    bind.mainSetOption(
        key: kOptionEnableFileTransfer,
        value: _fileOk ? defaultOptionYes : 'N');
    notifyListeners();
  }

  toggleClipboard() async {
    _clipboardOk = !clipboardOk;
    bind.mainSetOption(
        key: kOptionEnableClipboard,
        value: clipboardOk ? defaultOptionYes : 'N');
    notifyListeners();
  }

  toggleInput() async {
    if (clients.any((c) => !c.disconnected)) {
      await showClientsMayNotBeChangedAlert(parent.target);
    }
    if (_inputOk) {
      parent.target?.invokeMethod("stop_input");
      bind.mainSetOption(key: kOptionEnableKeyboard, value: 'N');
    } else {
      if (parent.target != null) {
        /// the result of toggle-on depends on user actions in the settings page.
        /// handle result, see [ServerModel.changeStatue]
        showInputWarnAlert(parent.target!);
      }
    }
  }

  Future<bool> checkRequestNotificationPermission() async {
    debugPrint("androidVersion $androidVersion");
    if (androidVersion < 33) {
      return true;
    }
    if (await AndroidPermissionManager.check(kAndroid13Notification)) {
      debugPrint("notification permission already granted");
      return true;
    }
    var res = await AndroidPermissionManager.request(kAndroid13Notification);
    debugPrint("notification permission request result: $res");
    return res;
  }

  Future<bool> checkFloatingWindowPermission() async {
    debugPrint("androidVersion $androidVersion");
    if (androidVersion < 23) {
      return false;
    }
    if (await AndroidPermissionManager.check(kSystemAlertWindow)) {
      debugPrint("alert window permission already granted");
      return true;
    }
    var res = await AndroidPermissionManager.request(kSystemAlertWindow);
    debugPrint("alert window permission request result: $res");
    return res;
  }

  /// Toggle the screen sharing service.
  toggleService() async {
    if (_isStart) {
      final res = await parent.target?.dialogManager
          .show<bool>((setState, close, context) {
        submit() => close(true);
        return CustomAlertDialog(
          title: Row(children: [
            const Icon(Icons.warning_amber_sharp,
                color: Colors.redAccent, size: 28),
            const SizedBox(width: 10),
            Text(translate("Warning")),
          ]),
          content: Text(translate("android_stop_service_tip")),
          actions: [
            TextButton(onPressed: close, child: Text(translate("Cancel"))),
            TextButton(onPressed: submit, child: Text(translate("OK"))),
          ],
          onSubmit: submit,
          onCancel: close,
        );
      });
      if (res == true) {
        stopService();
      }
    } else {
      await checkRequestNotificationPermission();
      if (bind.mainGetLocalOption(key: kOptionDisableFloatingWindow) != 'Y') {
        await checkFloatingWindowPermission();
      }
      // 🔴 全ファイルへのアクセス権の要求をやめた（2026-08-10）。
      //   ここは開始前の確認画面。権限の設定画面へ飛ばされると、
      //   お客様は戻ってこられずサポートが始まらない。
      final res = await parent.target?.dialogManager
          .show<bool>((setState, close, context) {
        submit() => close(true);
        return CustomAlertDialog(
          title: Row(children: [
            const Icon(Icons.warning_amber_sharp,
                color: Colors.redAccent, size: 28),
            const SizedBox(width: 10),
            Text(translate("Warning")),
          ]),
          content: Text(translate("android_service_will_start_tip")),
          actions: [
            dialogButton("Cancel", onPressed: close, isOutline: true),
            dialogButton("OK", onPressed: submit),
          ],
          onSubmit: submit,
          onCancel: close,
        );
      });
      if (res == true) {
        startService();
      }
    }
  }

  /// Start the screen sharing service.
  Future<void> startService() async {
    _isStart = true;
    notifyListeners();
    parent.target?.ffiModel.updateEventListener(parent.target!.sessionId, "");
    await parent.target?.invokeMethod("init_service");
    // ugly is here, because for desktop, below is useless
    await bind.mainStartService();
    updateClientState();
    if (isAndroid) {
      androidUpdatekeepScreenOn();
    }
  }

  /// Stop the screen sharing service.
  Future<void> stopService() async {
    _isStart = false;
    closeAll();
    await parent.target?.invokeMethod("stop_service");
    await bind.mainStopService();
    notifyListeners();
    // for androidUpdatekeepScreenOn only
    WakelockManager.disable(_wakelockKey);
  }

  fetchID() async {
    final id = await bind.mainGetMyId();
    if (id != _serverId.id) {
      _serverId.id = id;
      notifyListeners();
    }
  }

  changeStatue(String name, bool value) {
    debugPrint("changeStatue value $value");
    switch (name) {
      case "media":
        _mediaOk = value;
        if (value && !_isStart) {
          startService();
        }
        break;
      case "input":
        if (_inputOk != value) {
          bind.mainSetOption(
              key: kOptionEnableKeyboard,
              value: value ? defaultOptionYes : 'N');
        }
        _inputOk = value;
        break;
      default:
        return;
    }
    notifyListeners();
  }

  // force
  updateClientState([String? json]) async {
    if (isTest) return;
    var res = await bind.cmGetClientsState();
    List<dynamic> clientsJson;
    try {
      clientsJson = jsonDecode(res);
    } catch (e) {
      debugPrint("Failed to decode clientsJson: '$res', error $e");
      return;
    }

    final oldClientLenght = _clients.length;
    _clients.clear();
    tabController.state.value.tabs.clear();

    for (var clientJson in clientsJson) {
      try {
        final client = Client.fromJson(clientJson);
        _clients.add(client);
        _addTab(client);
      } catch (e) {
        debugPrint("Failed to decode clientJson '$clientJson', error $e");
      }
    }
    if (desktopType == DesktopType.cm) {
      if (_clients.isEmpty) {
        hideCmWindow();
      } else if (!hideCm) {
        showCmWindow();
      }
    }
    if (_clients.length != oldClientLenght) {
      notifyListeners();
      if (isAndroid) androidUpdatekeepScreenOn();
    }
  }

  void addConnection(Map<String, dynamic> evt) {
    try {
      final client = Client.fromJson(jsonDecode(evt["client"]));
      if (client.authorized) {
        parent.target?.dialogManager.dismissByTag(getLoginDialogTag(client.id));
        // 初回接続確立を記録。RLワンタイム版の自動終了(kRlSupportShowWindow分岐)に加え、
        // REMOHELP PRO 顧客アプリの「相談員切断で自動停止」(timerCallback)にも使う。
        if (!_hasEverConnected) {
          _hasEverConnected = true;
        }
        final index = _clients.indexWhere((c) => c.id == client.id);
        if (index < 0) {
          _clients.add(client);
        } else {
          if (_clients[index].authorized) {
            _clients[index].privacyMode = client.privacyMode;
            notifyListeners();
            return;
          }
          _clients[index].authorized = true;
          _clients[index].privacyMode = client.privacyMode;
        }
      } else {
        final index = _clients.indexWhere((c) => c.id == client.id);
        if (index >= 0) {
          _clients[index].privacyMode = client.privacyMode;
          notifyListeners();
          return;
        }
        _clients.add(client);
      }
      _addTab(client);
      // remove disconnected
      final index_disconnected = _clients
          .indexWhere((c) => c.disconnected && c.peerId == client.peerId);
      if (index_disconnected >= 0) {
        _clients.removeAt(index_disconnected);
        tabController.remove(index_disconnected);
      }
      // 🔴 「自分の画面を見せる」で繋がったときは、隠す設定でも**必ず出す**
      //   （2026-08-26 ご指摘）。
      //
      //   ⚠ **見せるのをやめる道は、この窓の中にしかない**（紫の釦）。
      //     出さないと、お客様に自分のPCを操作させたまま**止められなくなる**。
      //     実機で発生。相談員版は本体の窓も開けないので、他に道が無い。
      //   ★止められない機能は、始められる機能より危ない。ここは例外にする。
      if (desktopType == DesktopType.cm) {
        if (client.fromSwitch) {
          // ⚠ showCmWindow() では出し切れない（起動直後の取りこぼしと、
          //   hide() したのに show() を呼ばない問題）。必ず forceShowCmWindow。
          forceShowCmWindow();
        } else if (!hideCm) {
          showCmWindow();
        }
      }
      scrollToBottom();
      notifyListeners();
      if (isAndroid && !client.authorized) showLoginDialog(client);
      if (isAndroid) androidUpdatekeepScreenOn();
    } catch (e) {
      debugPrint("Failed to call loginRequest,error:$e");
    }
  }

  void _addTab(Client client) {
    tabController.add(TabInfo(
        key: client.id.toString(),
        label: client.name,
        closable: false,
        onTap: () {},
        page: desktop.buildConnectionCard(client)));
    Future.delayed(Duration.zero, () async {
      // ⚠ 「自分の画面を見せる」で繋がったときは、隠す設定でも前に出す。
      //   戻す釦がこの窓の中にしかないため（上の説明）。
      if (!hideCm || client.fromSwitch) windowOnTop(null);
    });
    // Only do the hidden task when on Desktop.
    if (client.authorized && isDesktop) {
      cmHiddenTimer = Timer(const Duration(seconds: 3), () {
        // 🔴🔴 「自分の画面を見せる」で繋がったときは**引っ込めない**
        //   （2026-08-27 判明。8/26 のご指摘「タスクバーから押しても
        //   一瞬だけ見えて出ない」の正体）。
        //
        //   ⚠ すぐ上の行は `client.fromSwitch` を見て前面に出しているのに、
        //     この3秒後の最小化は見ていなかった。
        //     ＝ **窓を出した3秒後に、自分で引っ込めていた。**
        //   ⚠ 戻す釦はこの窓の中にしかないので、引っ込めると
        //     **お客様に自分のPCを操作させたまま止められなくなる**。
        //   ★止められない機能は、始められる機能より危ない。ここは例外にする。
        if (!hideCm && !client.fromSwitch) windowManager.minimize();
        cmHiddenTimer = null;
      });
    }
    parent.target?.chatModel
        .updateConnIdOfKey(MessageKey(client.peerId, client.id));
  }

  void showLoginDialog(Client client) {
    showClientDialog(
      client,
      client.isFileTransfer
          ? "Transfer file"
          : client.isViewCamera
              ? "View camera"
              : client.isTerminal
                  ? "Terminal"
                  : "Share screen",
      'Do you accept?',
      'android_new_connection_tip',
      () => sendLoginResponse(client, false),
      () => sendLoginResponse(client, true),
    );
  }

  handleVoiceCall(Client client, bool accept) {
    parent.target?.invokeMethod("cancel_notification", client.id);
    bind.cmHandleIncomingVoiceCall(id: client.id, accept: accept);
  }

  showVoiceCallDialog(Client client) {
    showClientDialog(
      client,
      'Voice call',
      'Do you accept?',
      'android_new_voice_call_tip',
      () => handleVoiceCall(client, false),
      () => handleVoiceCall(client, true),
    );
  }

  showClientDialog(Client client, String title, String contentTitle,
      String content, VoidCallback onCancel, VoidCallback onSubmit) {
    parent.target?.dialogManager.show((setState, close, context) {
      cancel() {
        onCancel();
        close();
      }

      submit() {
        onSubmit();
        close();
      }

      return CustomAlertDialog(
        title:
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(translate(title)),
          IconButton(onPressed: close, icon: const Icon(Icons.close))
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(translate(contentTitle)),
            ClientInfo(client),
            Text(
              translate(content),
              style: Theme.of(globalKey.currentContext!).textTheme.bodyMedium,
            ),
          ],
        ),
        actions: [
          dialogButton("Dismiss", onPressed: cancel, isOutline: true),
          if (approveMode != 'password')
            dialogButton("Accept", onPressed: submit),
        ],
        onSubmit: submit,
        onCancel: cancel,
      );
    }, tag: getLoginDialogTag(client.id));
  }

  scrollToBottom() {
    if (isDesktop) return;
    Future.delayed(Duration(milliseconds: 200), () {
      controller.animateTo(controller.position.maxScrollExtent,
          duration: Duration(milliseconds: 200),
          curve: Curves.fastLinearToSlowEaseIn);
    });
  }

  void sendLoginResponse(Client client, bool res) async {
    if (res) {
      bind.cmLoginRes(connId: client.id, res: res);
      if (!client.isFileTransfer && !client.isTerminal) {
        parent.target?.invokeMethod("start_capture");
      }
      parent.target?.invokeMethod("cancel_notification", client.id);
      client.authorized = true;
      notifyListeners();
    } else {
      bind.cmLoginRes(connId: client.id, res: res);
      parent.target?.invokeMethod("cancel_notification", client.id);
      final index = _clients.indexOf(client);
      tabController.remove(index);
      _clients.remove(client);
      if (isAndroid) androidUpdatekeepScreenOn();
    }
  }

  void onClientRemove(Map<String, dynamic> evt) {
    try {
      final id = int.parse(evt['id'] as String);
      final close = (evt['close'] as String) == 'true';
      if (_clients.any((c) => c.id == id)) {
        final index = _clients.indexWhere((client) => client.id == id);
        if (index >= 0) {
          if (close) {
            _clients.removeAt(index);
            tabController.remove(index);
          } else {
            _clients[index].disconnected = true;
          }
        }
        parent.target?.dialogManager.dismissByTag(getLoginDialogTag(id));
        parent.target?.invokeMethod("cancel_notification", id);
      }
      if (desktopType == DesktopType.cm && _clients.isEmpty) {
        hideCmWindow();
      }
      if (isAndroid) androidUpdatekeepScreenOn();
      notifyListeners();
    } catch (e) {
      debugPrint("onClientRemove failed,error:$e");
    }
  }

  Future<void> closeAll() async {
    await Future.wait(
        _clients.map((client) => bind.cmCloseConnection(connId: client.id)));
    _clients.clear();
    tabController.state.value.tabs.clear();
    if (isAndroid) androidUpdatekeepScreenOn();
  }

  void jumpTo(int id) {
    final index = _clients.indexWhere((client) => client.id == id);
    tabController.jumpTo(index);
  }

  void setShowElevation(bool show) {
    if (_showElevation != show) {
      _showElevation = show;
      notifyListeners();
    }
  }

  void updateVoiceCallState(Map<String, dynamic> evt) {
    try {
      final client = Client.fromJson(jsonDecode(evt["client"]));
      final index = _clients.indexWhere((element) => element.id == client.id);
      if (index != -1) {
        _clients[index].inVoiceCall = client.inVoiceCall;
        _clients[index].incomingVoiceCall = client.incomingVoiceCall;
        if (client.incomingVoiceCall) {
          if (isAndroid) {
            showVoiceCallDialog(client);
          } else {
            // 🔴 音声通話の着信は、**隠す設定でも必ず出す**（2026-08-26 修正）。
            //
            //   ⚠ 8/4 に「窓が2つになる」という見た目の理由で `!hideCm` を
            //     足した。**受けるボタンはこの窓の中にしか無い**ので、
            //     ワンタイム版のお客様は着信に応答できなくなっていた
            //     （＝音声通話がまったく使えない状態）。
            //   ★呼び出しの知らせを、見た目の都合で握りつぶさない。
            //
            //   ⚠ windowOnTop だけでは足りない。ワンタイム版の窓は
            //     setOpacity(0) で透明にしてあり、前に出しても見えない。
            //     不透明に戻す showCmWindow() を通すこと。
            Future.delayed(Duration.zero, () {
              // ⚠ 受ける釦はこの窓の中にしかない。確実に出す方を使う。
              forceShowCmWindow();
            });
          }
        }
        notifyListeners();
      }
    } catch (e) {
      debugPrint("updateVoiceCallState failed: $e");
    }
  }

  void androidUpdatekeepScreenOn() async {
    if (!isAndroid) return;
    var floatingWindowDisabled =
        bind.mainGetLocalOption(key: kOptionDisableFloatingWindow) == "Y" ||
            !await AndroidPermissionManager.check(kSystemAlertWindow);
    final keepScreenOn = floatingWindowDisabled
        ? KeepScreenOn.never
        : optionToKeepScreenOn(
            bind.mainGetLocalOption(key: kOptionKeepScreenOn));
    final on = ((keepScreenOn == KeepScreenOn.serviceOn) && _isStart) ||
        (keepScreenOn == KeepScreenOn.duringControlled &&
            _clients.map((e) => !e.disconnected).isNotEmpty);
    if (on) {
      WakelockManager.enable(_wakelockKey, isServer: true);
    } else {
      WakelockManager.disable(_wakelockKey);
    }
  }
}

enum ClientType {
  remote,
  file,
  camera,
  portForward,
  terminal,
}

class Client {
  int id = 0; // client connections inner count id
  bool authorized = false;
  bool isFileTransfer = false;
  bool isViewCamera = false;
  bool isTerminal = false;
  String portForward = "";
  String name = "";
  String avatar = "";
  String peerId = ""; // peer user's id,show at app
  bool keyboard = false;
  bool clipboard = false;
  bool audio = false;
  bool file = false;
  bool restart = false;
  bool recording = false;
  bool blockInput = false;
  bool privacyMode = false;
  bool disconnected = false;
  bool fromSwitch = false;
  bool inVoiceCall = false;
  bool incomingVoiceCall = false;
  /// 相談員が画面に印をつけている最中か（画面注釈＝お絵かき）。
  /// これが true の間だけ、顧客側に告知帯と「自分も描く」を出す。
  bool remoteDrawing = false;

  RxInt unreadChatMessageCount = 0.obs;

  Client(this.id, this.authorized, this.isFileTransfer, this.isViewCamera,
      this.name, this.peerId, this.keyboard, this.clipboard, this.audio);

  Client.fromJson(Map<String, dynamic> json) {
    id = json['id'];
    authorized = json['authorized'];
    isFileTransfer = json['is_file_transfer'];
    // TODO: no entry then default.
    isViewCamera = json['is_view_camera'];
    isTerminal = json['is_terminal'] ?? false;
    portForward = json['port_forward'];
    name = json['name'];
    avatar = json['avatar'] ?? '';
    peerId = json['peer_id'];
    keyboard = json['keyboard'];
    clipboard = json['clipboard'];
    audio = json['audio'];
    file = json['file'];
    restart = json['restart'];
    recording = json['recording'];
    blockInput = json['block_input'];
    privacyMode = json['privacy_mode'] ?? privacyMode;
    disconnected = json['disconnected'];
    fromSwitch = json['from_switch'];
    inVoiceCall = json['in_voice_call'];
    incomingVoiceCall = json['incoming_voice_call'];
    // 旧バージョンの相手には無い項目なので、欠けていても落ちないようにする。
    remoteDrawing = json['remote_drawing'] ?? false;
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['id'] = id;
    data['authorized'] = authorized;
    data['is_file_transfer'] = isFileTransfer;
    data['is_view_camera'] = isViewCamera;
    data['is_terminal'] = isTerminal;
    data['port_forward'] = portForward;
    data['name'] = name;
    data['avatar'] = avatar;
    data['peer_id'] = peerId;
    data['keyboard'] = keyboard;
    data['clipboard'] = clipboard;
    data['audio'] = audio;
    data['file'] = file;
    data['restart'] = restart;
    data['recording'] = recording;
    data['block_input'] = blockInput;
    data['privacy_mode'] = privacyMode;
    data['disconnected'] = disconnected;
    data['from_switch'] = fromSwitch;
    data['in_voice_call'] = inVoiceCall;
    data['incoming_voice_call'] = incomingVoiceCall;
    return data;
  }

  // v1.4.6-13: Phase 4 - N3 顧客情報表示 (担当者名 | 部署/役職 | 組織名 | 顔写真 URL)
  // データ転送実装 (Step 2.5) まで `name` フィールドに `|` 区切りで詰める暫定実装
  // 例: "鈴木 一郎|IT 部 / システム管理者|REMOHELP PRO Demo Org|https://.../avatar.png"
  // 区切り無し時は従来表示 (display_name のみ) にフォールバック
  List<String> get _nameParts => name.split('|');
  String get displayName =>
      _nameParts.isNotEmpty ? _nameParts[0] : name;
  String get departmentRole =>
      _nameParts.length > 1 ? _nameParts[1] : '';
  String get organizationName =>
      _nameParts.length > 2 ? _nameParts[2] : '';
  String get richAvatarUrl =>
      _nameParts.length > 3 ? _nameParts[3] : '';

  ClientType type_() {
    if (isFileTransfer) {
      return ClientType.file;
    } else if (isViewCamera) {
      return ClientType.camera;
    } else if (isTerminal) {
      return ClientType.terminal;
    } else if (portForward.isNotEmpty) {
      return ClientType.portForward;
    } else {
      return ClientType.remote;
    }
  }
}

String getLoginDialogTag(int id) {
  return kLoginDialogTag + id.toString();
}

showInputWarnAlert(FFI ffi) {
  ffi.dialogManager.show((setState, close, context) {
    submit() {
      AndroidPermissionManager.startAction(kActionAccessibilitySettings);
      close();
    }

    return CustomAlertDialog(
      title: Text(translate("How to get Android input permission?")),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(translate("android_input_permission_tip1")),
          const SizedBox(height: 10),
          Text(translate("android_input_permission_tip2")),
        ],
      ),
      actions: [
        dialogButton("Cancel", onPressed: close, isOutline: true),
        dialogButton("Open System Setting", onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

Future<void> showClientsMayNotBeChangedAlert(FFI? ffi) async {
  await ffi?.dialogManager.show((setState, close, context) {
    return CustomAlertDialog(
      title: Text(translate("Permissions")),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(translate("android_permission_may_not_change_tip")),
        ],
      ),
      actions: [
        dialogButton("OK", onPressed: close),
      ],
      onSubmit: close,
      onCancel: close,
    );
  });
}
