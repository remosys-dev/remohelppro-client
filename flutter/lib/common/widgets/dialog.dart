import 'dart:async';
import 'package:flutter_hbb/remohelppro_endpoints.dart';
import 'dart:convert';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/common/widgets/setting_widgets.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/models/peer_tab_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter_hbb/utils/http_service.dart' as http;

import '../../common.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import 'address_book.dart';

void clientClose(SessionID sessionId, FFI ffi) async {
  if (allowAskForNoteAtEndOfConnection(ffi, true)) {
    if (await showConnEndAuditDialogCloseCanceled(ffi: ffi)) {
      return;
    }
    closeConnection();
  } else {
    msgBox(sessionId, 'info', 'Close', 'Are you sure to close the connection?',
        '', ffi.dialogManager);
  }
}

abstract class ValidationRule {
  String get name;
  bool validate(String value);
}

class LengthRangeValidationRule extends ValidationRule {
  final int _min;
  final int _max;

  LengthRangeValidationRule(this._min, this._max);

  @override
  String get name => translate('length %min% to %max%')
      .replaceAll('%min%', _min.toString())
      .replaceAll('%max%', _max.toString());

  @override
  bool validate(String value) {
    return value.length >= _min && value.length <= _max;
  }
}

class RegexValidationRule extends ValidationRule {
  final String _name;
  final RegExp _regex;

  RegexValidationRule(this._name, this._regex);

  @override
  String get name => translate(_name);

  @override
  bool validate(String value) {
    return value.isNotEmpty ? value.contains(_regex) : false;
  }
}

void changeIdDialog() {
  var newId = "";
  var msg = "";
  var isInProgress = false;
  TextEditingController controller = TextEditingController();
  final RxString rxId = controller.text.trim().obs;

  final rules = [
    RegexValidationRule('starts with a letter', RegExp(r'^[a-zA-Z]')),
    LengthRangeValidationRule(6, 16),
    RegexValidationRule('allowed characters', RegExp(r'^[\w-]*$'))
  ];

  gFFI.dialogManager.show((setState, close, context) {
    submit() async {
      debugPrint("onSubmit");
      newId = controller.text.trim();

      final Iterable violations = rules.where((r) => !r.validate(newId));
      if (violations.isNotEmpty) {
        setState(() {
          msg = (isDesktop || isWebDesktop)
              ? '${translate('Prompt')}:  ${violations.map((r) => r.name).join(', ')}'
              : violations.map((r) => r.name).join(', ');
        });
        return;
      }

      setState(() {
        msg = "";
        isInProgress = true;
        bind.mainChangeId(newId: newId);
      });

      var status = await bind.mainGetAsyncStatus();
      while (status == " ") {
        await Future.delayed(const Duration(milliseconds: 100));
        status = await bind.mainGetAsyncStatus();
      }
      if (status.isEmpty) {
        // ok
        close();
        return;
      }
      setState(() {
        isInProgress = false;
        msg = (isDesktop || isWebDesktop)
            ? '${translate('Prompt')}: ${translate(status)}'
            : translate(status);
      });
    }

    return CustomAlertDialog(
      title: Text(translate("Change ID")),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(translate("id_change_tip")),
          const SizedBox(
            height: 12.0,
          ),
          TextField(
            decoration: InputDecoration(
                labelText: translate('Your new ID'),
                errorText: msg.isEmpty ? null : translate(msg),
                suffixText: '${rxId.value.length}/16',
                suffixStyle: const TextStyle(fontSize: 12, color: Colors.grey)),
            inputFormatters: [
              LengthLimitingTextInputFormatter(16),
              // FilteringTextInputFormatter(RegExp(r"[a-zA-z][a-zA-z0-9\_]*"), allow: true)
            ],
            controller: controller,
            autofocus: true,
            onChanged: (value) {
              setState(() {
                rxId.value = value.trim();
                msg = '';
              });
            },
          ).workaroundFreezeLinuxMint(),
          const SizedBox(
            height: 8.0,
          ),
          (isDesktop || isWebDesktop)
              ? Obx(() => Wrap(
                    runSpacing: 8,
                    spacing: 4,
                    children: rules.map((e) {
                      var checked = e.validate(rxId.value);
                      return Chip(
                          label: Text(
                            e.name,
                            style: TextStyle(
                                color: checked
                                    ? const Color(0xFF0A9471)
                                    : Color.fromARGB(255, 198, 86, 157)),
                          ),
                          backgroundColor: checked
                              ? const Color(0xFFD0F7ED)
                              : Color.fromARGB(255, 247, 205, 232));
                    }).toList(),
                  )).marginOnly(bottom: 8)
              : SizedBox.shrink(),
          // NOT use Offstage to wrap LinearProgressIndicator
          if (isInProgress) const LinearProgressIndicator(),
        ],
      ),
      actions: [
        dialogButton("Cancel", onPressed: close, isOutline: true),
        dialogButton("OK", onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

void changeWhiteList({Function()? callback}) async {
  final curWhiteList = await bind.mainGetOption(key: kOptionWhitelist);
  var newWhiteListField = curWhiteList == defaultOptionWhitelist
      ? ''
      : curWhiteList.split(',').join('\n');
  var controller = TextEditingController(text: newWhiteListField);
  var msg = "";
  var isInProgress = false;
  final isOptFixed = isOptionFixed(kOptionWhitelist);
  gFFI.dialogManager.show((setState, close, context) {
    return CustomAlertDialog(
      title: Text(translate("IP Whitelisting")),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(translate("whitelist_sep")),
          const SizedBox(
            height: 8.0,
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                        maxLines: null,
                        decoration: InputDecoration(
                          errorText: msg.isEmpty ? null : translate(msg),
                        ),
                        controller: controller,
                        enabled: !isOptFixed,
                        autofocus: true)
                    .workaroundFreezeLinuxMint(),
              ),
            ],
          ),
          const SizedBox(
            height: 4.0,
          ),
          // NOT use Offstage to wrap LinearProgressIndicator
          if (isInProgress) const LinearProgressIndicator(),
        ],
      ),
      actions: [
        dialogButton("Cancel", onPressed: close, isOutline: true),
        if (!isOptFixed)
          dialogButton("Clear", onPressed: () async {
            await bind.mainSetOption(
                key: kOptionWhitelist, value: defaultOptionWhitelist);
            callback?.call();
            close();
          }, isOutline: true),
        if (!isOptFixed)
          dialogButton(
            "OK",
            onPressed: () async {
              setState(() {
                msg = "";
                isInProgress = true;
              });
              newWhiteListField = controller.text.trim();
              var newWhiteList = "";
              if (newWhiteListField.isEmpty) {
                // pass
              } else {
                final ips =
                    newWhiteListField.trim().split(RegExp(r"[\s,;\n]+"));
                // test ip
                final ipMatch = RegExp(
                    r"^(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)(\/([1-9]|[1-2][0-9]|3[0-2])){0,1}$");
                final ipv6Match = RegExp(
                    r"^(((?:[0-9A-Fa-f]{1,4}))*((?::[0-9A-Fa-f]{1,4}))*::((?:[0-9A-Fa-f]{1,4}))*((?::[0-9A-Fa-f]{1,4}))*|((?:[0-9A-Fa-f]{1,4}))((?::[0-9A-Fa-f]{1,4})){7})(\/([1-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8])){0,1}$");
                for (final ip in ips) {
                  if (!ipMatch.hasMatch(ip) && !ipv6Match.hasMatch(ip)) {
                    msg = "${translate("Invalid IP")} $ip";
                    setState(() {
                      isInProgress = false;
                    });
                    return;
                  }
                }
                newWhiteList = ips.join(',');
              }
              if (newWhiteList.trim().isEmpty) {
                newWhiteList = defaultOptionWhitelist;
              }
              await bind.mainSetOption(
                  key: kOptionWhitelist, value: newWhiteList);
              callback?.call();
              close();
            },
          ),
      ],
      onCancel: close,
    );
  });
}

Future<String> changeDirectAccessPort(
    String currentIP, String currentPort) async {
  final controller = TextEditingController(text: currentPort);
  await gFFI.dialogManager.show((setState, close, context) {
    return CustomAlertDialog(
      title: Text(translate("Change Local Port")),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8.0),
          Row(
            children: [
              Expanded(
                child: TextField(
                        maxLines: null,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                            hintText: '21118',
                            isCollapsed: true,
                            prefix: Text('$currentIP : '),
                            suffix: IconButton(
                                padding: EdgeInsets.zero,
                                icon: const Icon(Icons.clear, size: 16),
                                onPressed: () => controller.clear())),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(
                              r'^([0-9]|[1-9]\d|[1-9]\d{2}|[1-9]\d{3}|[1-5]\d{4}|6[0-4]\d{3}|65[0-4]\d{2}|655[0-2]\d|6553[0-5])$')),
                        ],
                        controller: controller,
                        autofocus: true)
                    .workaroundFreezeLinuxMint(),
              ),
            ],
          ),
        ],
      ),
      actions: [
        dialogButton("Cancel", onPressed: close, isOutline: true),
        dialogButton("OK", onPressed: () async {
          await bind.mainSetOption(
              key: kOptionDirectAccessPort, value: controller.text);
          close();
        }),
      ],
      onCancel: close,
    );
  });
  return controller.text;
}

Future<String> changeAutoDisconnectTimeout(String old) async {
  final controller = TextEditingController(text: old);
  await gFFI.dialogManager.show((setState, close, context) {
    return CustomAlertDialog(
      title: Text(translate("Timeout in minutes")),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8.0),
          Row(
            children: [
              Expanded(
                child: TextField(
                        maxLines: null,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                            hintText: '10',
                            isCollapsed: true,
                            suffix: IconButton(
                                padding: EdgeInsets.zero,
                                icon: const Icon(Icons.clear, size: 16),
                                onPressed: () => controller.clear())),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(
                              r'^([0-9]|[1-9]\d|[1-9]\d{2}|[1-9]\d{3}|[1-5]\d{4}|6[0-4]\d{3}|65[0-4]\d{2}|655[0-2]\d|6553[0-5])$')),
                        ],
                        controller: controller,
                        autofocus: true)
                    .workaroundFreezeLinuxMint(),
              ),
            ],
          ),
        ],
      ),
      actions: [
        dialogButton("Cancel", onPressed: close, isOutline: true),
        dialogButton("OK", onPressed: () async {
          await bind.mainSetOption(
              key: kOptionAutoDisconnectTimeout, value: controller.text);
          close();
        }),
      ],
      onCancel: close,
    );
  });
  return controller.text;
}

class DialogTextField extends StatelessWidget {
  final String title;
  final String? hintText;
  final bool obscureText;
  final String? errorText;
  final String? helperText;
  final Widget? prefixIcon;
  final Widget? suffixIcon;
  final TextEditingController controller;
  final FocusNode? focusNode;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final int? maxLength;

  static const kUsernameTitle = 'Username';
  static const kUsernameIcon = Icon(Icons.account_circle_outlined);
  static const kPasswordTitle = 'Password';
  static const kPasswordIcon = Icon(Icons.lock_outline);

  DialogTextField(
      {Key? key,
      this.focusNode,
      this.obscureText = false,
      this.errorText,
      this.helperText,
      this.prefixIcon,
      this.suffixIcon,
      this.hintText,
      this.keyboardType,
      this.inputFormatters,
      this.maxLength,
      required this.title,
      required this.controller})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            children: [
              TextField(
                decoration: InputDecoration(
                  labelText: title,
                  hintText: hintText,
                  prefixIcon: prefixIcon,
                  suffixIcon: suffixIcon,
                  helperText: helperText,
                  helperMaxLines: 8,
                ),
                controller: controller,
                focusNode: focusNode,
                autofocus: true,
                obscureText: obscureText,
                keyboardType: keyboardType,
                inputFormatters: inputFormatters,
                maxLength: maxLength,
              ),
              if (errorText != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(
                    errorText!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12,
                    ),
                    textAlign: TextAlign.left,
                  ).paddingOnly(top: 8, left: 12),
                ),
            ],
          ).workaroundFreezeLinuxMint(),
        ),
      ],
    ).paddingSymmetric(vertical: 4.0);
  }
}

abstract class ValidationField extends StatelessWidget {
  ValidationField({Key? key}) : super(key: key);

  String? validate();
  bool get isReady;
}

class Dialog2FaField extends ValidationField {
  Dialog2FaField({
    Key? key,
    required this.controller,
    this.autoFocus = true,
    this.reRequestFocus = false,
    this.title,
    this.hintText,
    this.errorText,
    this.readyCallback,
    this.onChanged,
  }) : super(key: key);

  final TextEditingController controller;
  final bool autoFocus;
  final bool reRequestFocus;
  final String? title;
  final String? hintText;
  final String? errorText;
  final VoidCallback? readyCallback;
  final VoidCallback? onChanged;
  final errMsg = translate('2FA code must be 6 digits.');

  @override
  Widget build(BuildContext context) {
    return DialogVerificationCodeField(
      title: title ?? translate('2FA code'),
      controller: controller,
      errorText: errorText,
      autoFocus: autoFocus,
      reRequestFocus: reRequestFocus,
      hintText: hintText,
      readyCallback: readyCallback,
      onChanged: _onChanged,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9]')),
      ],
    );
  }

  String get text => controller.text;
  bool get isAllDigits => text.codeUnits.every((e) => e >= 48 && e <= 57);

  @override
  bool get isReady => text.length == 6 && isAllDigits;

  @override
  String? validate() => isReady ? null : errMsg;

  _onChanged(StateSetter setState, SimpleWrapper<String?> errText) {
    onChanged?.call();

    if (text.length > 6) {
      setState(() => errText.value = errMsg);
      return;
    }

    if (!isAllDigits) {
      setState(() => errText.value = errMsg);
      return;
    }

    if (isReady) {
      readyCallback?.call();
      return;
    }

    if (errText.value != null) {
      setState(() => errText.value = null);
    }
  }
}

class DialogEmailCodeField extends ValidationField {
  DialogEmailCodeField({
    Key? key,
    required this.controller,
    this.autoFocus = true,
    this.reRequestFocus = false,
    this.hintText,
    this.errorText,
    this.readyCallback,
    this.onChanged,
  }) : super(key: key);

  final TextEditingController controller;
  final bool autoFocus;
  final bool reRequestFocus;
  final String? hintText;
  final String? errorText;
  final VoidCallback? readyCallback;
  final VoidCallback? onChanged;
  final errMsg = translate('Email verification code must be 6 characters.');

  @override
  Widget build(BuildContext context) {
    return DialogVerificationCodeField(
      title: translate('Verification code'),
      controller: controller,
      errorText: errorText,
      autoFocus: autoFocus,
      reRequestFocus: reRequestFocus,
      hintText: hintText,
      readyCallback: readyCallback,
      helperText: translate('verification_tip'),
      onChanged: _onChanged,
      keyboardType: TextInputType.visiblePassword,
    );
  }

  String get text => controller.text;

  @override
  bool get isReady => text.length == 6;

  @override
  String? validate() => isReady ? null : errMsg;

  _onChanged(StateSetter setState, SimpleWrapper<String?> errText) {
    onChanged?.call();

    if (text.length > 6) {
      setState(() => errText.value = errMsg);
      return;
    }

    if (isReady) {
      readyCallback?.call();
      return;
    }

    if (errText.value != null) {
      setState(() => errText.value = null);
    }
  }
}

class DialogVerificationCodeField extends StatefulWidget {
  DialogVerificationCodeField({
    Key? key,
    required this.controller,
    required this.title,
    this.autoFocus = true,
    this.reRequestFocus = false,
    this.helperText,
    this.hintText,
    this.errorText,
    this.textLength,
    this.readyCallback,
    this.onChanged,
    this.keyboardType,
    this.inputFormatters,
  }) : super(key: key);

  final TextEditingController controller;
  final bool autoFocus;
  final bool reRequestFocus;
  final String title;
  final String? helperText;
  final String? hintText;
  final String? errorText;
  final int? textLength;
  final VoidCallback? readyCallback;
  final Function(StateSetter setState, SimpleWrapper<String?> errText)?
      onChanged;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;

  @override
  State<DialogVerificationCodeField> createState() =>
      _DialogVerificationCodeField();
}

class _DialogVerificationCodeField extends State<DialogVerificationCodeField> {
  final _focusNode = FocusNode();
  Timer? _timer;
  Timer? _timerReRequestFocus;
  SimpleWrapper<String?> errorText = SimpleWrapper(null);
  String _preText = '';

  @override
  void initState() {
    super.initState();
    if (widget.autoFocus) {
      _timer =
          Timer(Duration(milliseconds: 50), () => _focusNode.requestFocus());

      if (widget.onChanged != null) {
        widget.controller.addListener(() {
          final text = widget.controller.text.trim();
          if (text == _preText) return;
          widget.onChanged!(setState, errorText);
          _preText = text;
        });
      }
    }

    // software secure keyboard will take the focus since flutter 3.13
    // request focus again when android account password obtain focus
    if (isAndroid && widget.reRequestFocus) {
      _focusNode.addListener(() {
        if (_focusNode.hasFocus) {
          _timerReRequestFocus?.cancel();
          _timerReRequestFocus = Timer(
              Duration(milliseconds: 100), () => _focusNode.requestFocus());
        }
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timerReRequestFocus?.cancel();
    _focusNode.unfocus();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DialogTextField(
      title: widget.title,
      controller: widget.controller,
      errorText: widget.errorText ?? errorText.value,
      focusNode: _focusNode,
      helperText: widget.helperText,
      keyboardType: widget.keyboardType,
      inputFormatters: widget.inputFormatters,
    );
  }
}

class PasswordWidget extends StatefulWidget {
  PasswordWidget({
    Key? key,
    required this.controller,
    this.autoFocus = true,
    this.reRequestFocus = false,
    this.hintText,
    this.errorText,
    this.title,
    this.maxLength,
  }) : super(key: key);

  final TextEditingController controller;
  final bool autoFocus;
  final bool reRequestFocus;
  final String? hintText;
  final String? errorText;
  final String? title;
  final int? maxLength;

  @override
  State<PasswordWidget> createState() => _PasswordWidgetState();
}

class _PasswordWidgetState extends State<PasswordWidget> {
  bool _passwordVisible = false;
  final _focusNode = FocusNode();
  Timer? _timer;
  Timer? _timerReRequestFocus;

  @override
  void initState() {
    super.initState();
    if (widget.autoFocus) {
      _timer =
          Timer(Duration(milliseconds: 50), () => _focusNode.requestFocus());
    }
    // software secure keyboard will take the focus since flutter 3.13
    // request focus again when android account password obtain focus
    if (isAndroid && widget.reRequestFocus) {
      _focusNode.addListener(() {
        if (_focusNode.hasFocus) {
          _timerReRequestFocus?.cancel();
          _timerReRequestFocus = Timer(
              Duration(milliseconds: 100), () => _focusNode.requestFocus());
        }
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timerReRequestFocus?.cancel();
    _focusNode.unfocus();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DialogTextField(
      title: translate(widget.title ?? DialogTextField.kPasswordTitle),
      hintText: translate(widget.hintText ?? 'Enter your password'),
      controller: widget.controller,
      prefixIcon: DialogTextField.kPasswordIcon,
      suffixIcon: IconButton(
        icon: Icon(
            // Based on passwordVisible state choose the icon
            _passwordVisible ? Icons.visibility : Icons.visibility_off,
            color: MyTheme.lightTheme.primaryColor),
        onPressed: () {
          // Update the state i.e. toggle the state of passwordVisible variable
          setState(() {
            _passwordVisible = !_passwordVisible;
          });
        },
      ),
      obscureText: !_passwordVisible,
      errorText: widget.errorText,
      focusNode: _focusNode,
      maxLength: widget.maxLength,
    );
  }
}

void wrongPasswordDialog(SessionID sessionId,
    OverlayDialogManager dialogManager, type, title, text) {
  dialogManager.dismissAll();
  dialogManager.show((setState, close, context) {
    cancel() {
      close();
      closeConnection();
    }

    submit() {
      enterPasswordDialog(sessionId, dialogManager);
    }

    return CustomAlertDialog(
        title: null,
        content: msgboxContent(type, title, text),
        onSubmit: submit,
        onCancel: cancel,
        actions: [
          dialogButton(
            'Cancel',
            onPressed: cancel,
            isOutline: true,
          ),
          dialogButton(
            'Retry',
            onPressed: submit,
          ),
        ]);
  });
}

void enterPasswordDialog(
    SessionID sessionId, OverlayDialogManager dialogManager) async {
  await _connectDialog(
    sessionId,
    dialogManager,
    passwordController: TextEditingController(),
  );
}

void enterUserLoginDialog(
    SessionID sessionId,
    OverlayDialogManager dialogManager,
    String osAccountDescTip,
    bool canRememberAccount) async {
  await _connectDialog(
    sessionId,
    dialogManager,
    osUsernameController: TextEditingController(),
    osPasswordController: TextEditingController(),
    osAccountDescTip: osAccountDescTip,
    canRememberAccount: canRememberAccount,
  );
}

void enterUserLoginAndPasswordDialog(
    SessionID sessionId,
    OverlayDialogManager dialogManager,
    String osAccountDescTip,
    bool canRememberAccount) async {
  await _connectDialog(
    sessionId,
    dialogManager,
    osUsernameController: TextEditingController(),
    osPasswordController: TextEditingController(),
    passwordController: TextEditingController(),
    osAccountDescTip: osAccountDescTip,
    canRememberAccount: canRememberAccount,
  );
}

_connectDialog(
  SessionID sessionId,
  OverlayDialogManager dialogManager, {
  TextEditingController? osUsernameController,
  TextEditingController? osPasswordController,
  TextEditingController? passwordController,
  String? osAccountDescTip,
  bool canRememberAccount = true,
}) async {
  final errUsername = ''.obs;
  var rememberPassword = false;
  if (passwordController != null) {
    rememberPassword =
        await bind.sessionGetRemember(sessionId: sessionId) ?? false;
  }
  var rememberAccount = false;
  if (canRememberAccount && osUsernameController != null) {
    rememberAccount =
        await bind.sessionGetRemember(sessionId: sessionId) ?? false;
  }
  if (osUsernameController != null) {
    osUsernameController.addListener(() {
      if (errUsername.value.isNotEmpty) {
        errUsername.value = '';
      }
    });
  }

  dialogManager.dismissAll();
  dialogManager.show((setState, close, context) {
    cancel() {
      close();
      closeConnection();
    }

    submit() {
      if (osUsernameController != null) {
        if (osUsernameController.text.trim().isEmpty) {
          errUsername.value = translate('Empty Username');
          setState(() {});
          return;
        }
      }
      final osUsername = osUsernameController?.text.trim() ?? '';
      final osPassword = osPasswordController?.text.trim() ?? '';
      final password = passwordController?.text.trim() ?? '';
      if (passwordController != null && password.isEmpty) return;
      if (rememberAccount) {
        bind.sessionPeerOption(
            sessionId: sessionId, name: 'os-username', value: osUsername);
        bind.sessionPeerOption(
            sessionId: sessionId, name: 'os-password', value: osPassword);
      }
      gFFI.login(
        osUsername,
        osPassword,
        sessionId,
        password,
        rememberPassword,
      );
      close();
      dialogManager.showLoading(translate('Logging in...'),
          onCancel: closeConnection);
    }

    descWidget(String text) {
      return Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              text,
              maxLines: 3,
              softWrap: true,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 16),
            ),
          ),
          Container(
            height: 8,
          ),
        ],
      );
    }

    rememberWidget(
      String desc,
      bool remember,
      ValueChanged<bool?>? onChanged,
    ) {
      return CheckboxListTile(
        contentPadding: const EdgeInsets.all(0),
        dense: true,
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(desc),
        value: remember,
        onChanged: onChanged,
      );
    }

    osAccountWidget() {
      if (osUsernameController == null || osPasswordController == null) {
        return Offstage();
      }
      return Column(
        children: [
          if (osAccountDescTip != null) descWidget(translate(osAccountDescTip)),
          DialogTextField(
            title: translate(DialogTextField.kUsernameTitle),
            controller: osUsernameController,
            prefixIcon: DialogTextField.kUsernameIcon,
            errorText: null,
          ),
          if (errUsername.value.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(
                errUsername.value,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
                textAlign: TextAlign.left,
              ).paddingOnly(left: 12, bottom: 2),
            ),
          PasswordWidget(
            controller: osPasswordController,
            autoFocus: false,
          ),
          if (canRememberAccount)
            rememberWidget(
              translate('remember_account_tip'),
              rememberAccount,
              (v) {
                if (v != null) {
                  setState(() => rememberAccount = v);
                }
              },
            ),
        ],
      );
    }

    passwdWidget() {
      if (passwordController == null) {
        return Offstage();
      }
      return Column(
        children: [
          descWidget(translate('verify_rustdesk_password_tip')),
          PasswordWidget(
            controller: passwordController,
            autoFocus: osUsernameController == null,
          ),
          rememberWidget(
            translate('Remember password'),
            rememberPassword,
            (v) {
              if (v != null) {
                setState(() => rememberPassword = v);
              }
            },
          ),
        ],
      );
    }

    return CustomAlertDialog(
      title: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.password_rounded, color: MyTheme.accent),
          Text(translate('Password Required')).paddingOnly(left: 10),
        ],
      ),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        osAccountWidget(),
        osUsernameController == null || passwordController == null
            ? Offstage()
            : Container(height: 12),
        passwdWidget(),
      ]),
      actions: [
        dialogButton(
          'Cancel',
          icon: Icon(Icons.close_rounded),
          onPressed: cancel,
          isOutline: true,
        ),
        dialogButton(
          'OK',
          icon: Icon(Icons.done_rounded),
          onPressed: submit,
        ),
      ],
      onSubmit: submit,
      onCancel: cancel,
    );
  });
}

void showWaitUacDialog(
    SessionID sessionId, OverlayDialogManager dialogManager, String type) {
  dialogManager.dismissAll();
  dialogManager.show(
      tag: '$sessionId-wait-uac',
      (setState, close, context) => CustomAlertDialog(
            title: null,
            content: msgboxContent(type, 'Wait', 'wait_accept_uac_tip'),
            actions: [
              dialogButton(
                'OK',
                icon: Icon(Icons.done_rounded),
                onPressed: close,
              ),
            ],
          ));
}

// Another username && password dialog?
void showRequestElevationDialog(
    SessionID sessionId, OverlayDialogManager dialogManager) {
  RxString groupValue = ''.obs;
  RxString errUser = ''.obs;
  RxString errPwd = ''.obs;
  TextEditingController userController = TextEditingController();
  TextEditingController pwdController = TextEditingController();

  void onRadioChanged(String? value) {
    if (value != null) {
      groupValue.value = value;
    }
  }

  // TODO get from theme
  final double fontSizeNote = 13.00;

  Widget OptionRequestPermissions = Obx(
    () => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Radio(
          visualDensity: VisualDensity(horizontal: -4, vertical: -4),
          value: '',
          groupValue: groupValue.value,
          onChanged: onRadioChanged,
        ).marginOnly(right: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                hoverColor: Colors.transparent,
                onTap: () => groupValue.value = '',
                child: Text(
                  translate('Ask the remote user for authentication'),
                ),
              ).marginOnly(bottom: 10),
              Text(
                translate('Choose this if the remote account is administrator'),
                style: TextStyle(fontSize: fontSizeNote),
              ),
            ],
          ).marginOnly(top: 3),
        ),
      ],
    ),
  );

  Widget OptionCredentials = Obx(
    () => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Radio(
          visualDensity: VisualDensity(horizontal: -4, vertical: -4),
          value: 'logon',
          groupValue: groupValue.value,
          onChanged: onRadioChanged,
        ).marginOnly(right: 10),
        Expanded(
          child: InkWell(
            hoverColor: Colors.transparent,
            onTap: () => onRadioChanged('logon'),
            child: Text(
              translate('Transmit the username and password of administrator'),
            ),
          ).marginOnly(top: 4),
        ),
      ],
    ),
  );

  Widget UacNote = Container(
    padding: EdgeInsets.fromLTRB(10, 8, 8, 8),
    decoration: BoxDecoration(
      color: MyTheme.currentThemeMode() == ThemeMode.dark
          ? Color.fromARGB(135, 87, 87, 90)
          : Colors.grey[100],
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: Colors.grey),
    ),
    child: Row(
      children: [
        Icon(Icons.info_outline_rounded, size: 20).marginOnly(right: 10),
        Expanded(
          child: Text(
            translate('still_click_uac_tip'),
            style: TextStyle(
                fontSize: fontSizeNote, fontWeight: FontWeight.normal),
          ),
        )
      ],
    ),
  );

  var content = Obx(
    () => Column(
      children: [
        OptionRequestPermissions.marginOnly(bottom: 15),
        OptionCredentials,
        Offstage(
          offstage: 'logon' != groupValue.value,
          child: Column(
            children: [
              UacNote.marginOnly(bottom: 10),
              DialogTextField(
                controller: userController,
                title: translate('Username'),
                hintText: translate('elevation_username_tip'),
                prefixIcon: DialogTextField.kUsernameIcon,
                errorText: errUser.isEmpty ? null : errUser.value,
              ),
              PasswordWidget(
                controller: pwdController,
                autoFocus: false,
                errorText: errPwd.isEmpty ? null : errPwd.value,
              ),
            ],
          ).marginOnly(left: stateGlobal.isPortrait.isFalse ? 35 : 0),
        ).marginOnly(top: 10),
      ],
    ),
  );

  dialogManager.dismissAll();
  dialogManager.show(tag: '$sessionId-request-elevation',
      (setState, close, context) {
    void submit() {
      if (groupValue.value == 'logon') {
        if (userController.text.isEmpty) {
          errUser.value = translate('Empty Username');
          return;
        }
        if (pwdController.text.isEmpty) {
          errPwd.value = translate('Empty Password');
          return;
        }
        bind.sessionElevateWithLogon(
            sessionId: sessionId,
            username: userController.text,
            password: pwdController.text);
      } else {
        bind.sessionElevateDirect(sessionId: sessionId);
      }
      close();
      showWaitUacDialog(sessionId, dialogManager, "wait-uac");
    }

    return CustomAlertDialog(
      title: Text(translate('Request Elevation')),
      content: content,
      actions: [
        dialogButton(
          'Cancel',
          icon: Icon(Icons.close_rounded),
          onPressed: close,
          isOutline: true,
        ),
        dialogButton(
          'OK',
          icon: Icon(Icons.done_rounded),
          onPressed: submit,
        )
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

void showOnBlockDialog(
  SessionID sessionId,
  String type,
  String title,
  String text,
  OverlayDialogManager dialogManager,
) {
  if (dialogManager.existing('$sessionId-wait-uac') ||
      dialogManager.existing('$sessionId-request-elevation')) {
    return;
  }
  dialogManager.show(tag: '$sessionId-$type', (setState, close, context) {
    void submit() {
      close();
      showRequestElevationDialog(sessionId, dialogManager);
    }

    return CustomAlertDialog(
      title: null,
      content: msgboxContent(type, title,
          "${translate(text)}${type.contains('uac') ? '\n' : '\n\n'}${translate('request_elevation_tip')}"),
      actions: [
        dialogButton('Wait', onPressed: close, isOutline: true),
        dialogButton('Request Elevation', onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

void showElevationError(SessionID sessionId, String type, String title,
    String text, OverlayDialogManager dialogManager) {
  dialogManager.show(tag: '$sessionId-$type', (setState, close, context) {
    void submit() {
      close();
      showRequestElevationDialog(sessionId, dialogManager);
    }

    return CustomAlertDialog(
      title: null,
      content: msgboxContent(type, title, text),
      actions: [
        dialogButton('Cancel', onPressed: () {
          close();
        }, isOutline: true),
        if (text != 'No permission') dialogButton('Retry', onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

void showWaitAcceptDialog(SessionID sessionId, String type, String title,
    String text, OverlayDialogManager dialogManager) {
  dialogManager.dismissAll();
  dialogManager.show((setState, close, context) {
    onCancel() {
      closeConnection();
    }

    return CustomAlertDialog(
      title: null,
      content: msgboxContent(type, title, text),
      actions: [
        dialogButton('Cancel', onPressed: onCancel, isOutline: true),
      ],
      onCancel: onCancel,
    );
  });
}

/// お客様のPCを再起動して、そのまま繋ぎ直す。
///
/// 🔴 ここだけで完結させる（2026-08-04 ユーザーご指摘）。
///   「再起動再接続はビュアーのメニューで実行するだけではだめですか？」
///   ごもっともで、それまでは**ログオン前から繋ぐ準備だけコンソール側**にあり、
///   相談員は画面を行き来していた。作業しているのはビュアーなので、ここに寄せる。
///
/// ■ 2通りある
///   ログオン後の復帰 … 何も要らない。控えは接続した時点で自動的にできている
///   ログオン前の接続 … お客様のPCに一時的なサービスを入れる。
///                      **管理者の確認（UAC）がお客様の画面に出る**
///                      （Windows の仕組みなので消せない）
///
/// ⚠ 準備の成否は必ず相談員に見せる。黙って失敗すると、相談員は
///   用意できたと信じて再起動し、**戻ってこないPCを待ち続ける**。
void showRestartRemoteDevice(PeerInfo pi, String id, SessionID sessionId,
    OverlayDialogManager dialogManager,
    {FFI? ffi}) async {
  // 🔴🔴 2026-08-30 ご指示「**ログイン前に繋ぐのが基本**」。
  //   釦を分けるのをやめた。⚠ **選ばせない。必ず用意する。**
  //
  //   ⚠ 分けていた頃の実害: 相談員が「再起動する」を押すと、
  //     ログイン前の準備は**されない**。お客様が席を外していると
  //     誰もログインできず、⚠ **戻ってこないPCを待つことになる。**
  //     ＝ 押し分けを誤ると気づけない形だった。
  //   ★常に用意する。⚠ **用意できなくても再起動そのものは止めない**
  //     （ログイン後の復帰はそれでも成立する。決めるのは相談員）。
  //
  //   ⚠ 常駐は元からサービスとして動いており、ログイン前から繋がる。
  //     一時サービスは要らない（入れると管理者の確認が無駄に出る）。
  final resident = isResidentPeer(ffi);

  // 1) 再起動してよいかだけを確かめる。
  final choice = await dialogManager
      .show<String>((setState, close, context) => CustomAlertDialog(
            title: Row(children: [
              Icon(Icons.restart_alt_rounded, color: Colors.blueAccent, size: 28),
              Flexible(
                  child: Text('再起動して、そのまま続ける')
                      .paddingOnly(left: 10)),
            ]),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${pi.username}@${pi.hostname}（$id）を再起動します。'),
                const SizedBox(height: 10),
                Text('ログイン前からつなぎ直します。',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 14),
                Text(
                  resident
                      ? 'お客様が席を外していても、そのまま繋がります。'
                      : 'お客様が席を外していても繋がるよう、いまから準備します。\n'
                          'お客様の画面に管理者の確認が一度だけ出ます。\n'
                          'それを押していただいてから再起動します。',
                ),
              ],
            ),
            actions: [
              dialogButton('やめる',
                  onPressed: () => close('cancel'), isOutline: true),
              dialogButton('再起動する', onPressed: () => close('plain')),
            ],
            onCancel: () => close('cancel'),
            onSubmit: () => close('plain'),
          ));

  if (choice == null || choice == 'cancel') return;

  // 2) ⚠ 常に用意する（常駐は要らない）。
  if (!resident) {
    final ok = await _rlPreparePrelogon(ffi, dialogManager);
    if (!ok) return; // 理由は _rlPreparePrelogon が画面に出している
  }

  bind.sessionRestartRemoteDevice(sessionId: sessionId);
}

/// ログオン前の接続の準備を、お客様のPCに頼んで、結果が返るまで待つ。
///
/// 戻り値: true=再起動してよい / false=やめる（理由は画面に出す）
///
/// ⚠ お客様が管理者の確認を押すまでの時間があるので、気長に（最大2分）待つ。
///   返ってこなければ「分からない」と正直に出す。
Future<bool> _rlPreparePrelogon(
    FFI? ffi, OverlayDialogManager dialogManager) async {
  final rid = ffi?.id ?? '';
  final token = ffi?.presetPassword ?? '';
  if (rid.isEmpty || token.isEmpty) {
    // ⚠ 2026-08-30: ここで止めない。準備を頼めないことと、
    //   再起動できないことは別。ログイン後の復帰はそれでも成立する。
    return _rlAskRestartAnyway(
        dialogManager, 'この接続からは準備を頼めませんでした。');
  }

  const url = '$kRlApiBase/api/customer/prelogon-by-viewer';
  Future<Map?> post(Map<String, dynamic> body) async {
    try {
      final r = await http
          .post(Uri.parse(url),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return null;
      return jsonDecode(r.body) as Map;
    } catch (e) {
      debugPrint('RL prelogon-by-viewer: $e');
      return null;
    }
  }

  final first = await post({'rustdeskId': rid, 'token': token});
  if (first == null || first['ok'] != true) {
    return _rlAskRestartAnyway(
        dialogManager, 'お客様のPCへ準備を頼めませんでした。');
  }

  // お待ちいただく表示。押した本人が何を待っているのか分かるようにする。
  final tag = dialogManager.showLoading(
      'お客様の画面に出ている確認を、押していただいてください');

  String? result;
  for (var i = 0; i < 40; i++) {
    await Future.delayed(const Duration(seconds: 3));
    final r = await post({'rustdeskId': rid, 'token': token, 'poll': true});
    final v = r?['result'];
    if (v is String && v.isNotEmpty) {
      result = v;
      break;
    }
  }
  dialogManager.dismissByTag(tag);

  if (result == 'ok') return true;

  // ⚠ 失敗しても再起動そのものは止めない。決めるのは相談員。
  //   ただし「ログイン前からは繋がらない」ことは必ず伝える。
  final reason = result == 'noAdmin'
      ? '管理者権限が無いため、実行できませんでした。'
      : result == 'failed'
          ? 'お客様のPCで準備できませんでした。'
          : 'お客様のPCから返事がありませんでした。';
  return _rlAskRestartAnyway(dialogManager, reason);
}

/// ログイン前の準備ができなかったときに、それでも再起動するかを訊く。
///
/// 🔴 入口を1つにまとめる（2026-08-30）。⚠ **同じ判断を3か所に書いていた。**
///   片方だけ直すと、押す場所によって起きることが変わる（過去に実際に起きた）。
/// ⚠ 既定は「やめる」。⚠ **Enter で黙って再起動させない。**
///   ログイン前に繋げないまま再起動すると、お客様が席を外していれば
///   誰もログインできず、戻ってこないPCを待つことになる。
Future<bool> _rlAskRestartAnyway(
    OverlayDialogManager dialogManager, String reason) async {
  final go = await dialogManager.show<bool>(
      (setState, close, context) => CustomAlertDialog(
            title: Text('ログイン前からは繋げません'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(reason),
                const SizedBox(height: 10),
                Text('このまま再起動すると、'
                    'お客様がログインしてからつながります。'),
                const SizedBox(height: 10),
                Text('お客様が席を外している場合は、'
                    'ログインできる方がいらっしゃるかご確認ください。'),
              ],
            ),
            actions: [
              dialogButton('やめる',
                  onPressed: () => close(false), isOutline: true),
              dialogButton('このまま再起動する', onPressed: () => close(true)),
            ],
            onCancel: () => close(false),
            onSubmit: () => close(false), // 既定は「やめる」
          ));
  return go == true;
}

// ⚠ `_rlPrelogonMsg`（「閉じる」だけの通知）は 2026-08-30 に削除した。
//   準備できなかったときに「閉じる」しか無いと、⚠ **再起動そのものが止まる**。
//   ログイン後の復帰はそれでも成立するので、必ず
//   `_rlAskRestartAnyway`（やめる／このまま再起動する）に寄せる。

showSetOSPassword(
  SessionID sessionId,
  bool login,
  OverlayDialogManager dialogManager,
  String? osPassword,
  Function()? closeCallback,
) async {
  final controller = TextEditingController();
  osPassword ??=
      await bind.sessionGetOption(sessionId: sessionId, arg: 'os-password') ??
          '';
  var autoLogin =
      await bind.sessionGetOption(sessionId: sessionId, arg: 'auto-login') !=
          '';
  controller.text = osPassword;
  dialogManager.show((setState, close, context) {
    closeWithCallback([dynamic]) {
      close();
      if (closeCallback != null) closeCallback();
    }

    submit() {
      var text = controller.text.trim();
      bind.sessionPeerOption(
          sessionId: sessionId, name: 'os-password', value: text);
      bind.sessionPeerOption(
          sessionId: sessionId,
          name: 'auto-login',
          value: autoLogin ? 'Y' : '');
      if (text != '' && login) {
        bind.sessionInputOsPassword(sessionId: sessionId, value: text);
      }
      closeWithCallback();
    }

    return CustomAlertDialog(
      title: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.password_rounded, color: MyTheme.accent),
          Text(translate('OS Password')).paddingOnly(left: 10),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PasswordWidget(controller: controller),
          CheckboxListTile(
            contentPadding: const EdgeInsets.all(0),
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(
              translate('Auto Login'),
            ),
            value: autoLogin,
            onChanged: (v) {
              if (v == null) return;
              setState(() => autoLogin = v);
            },
          ),
        ],
      ),
      actions: [
        dialogButton(
          "Cancel",
          icon: Icon(Icons.close_rounded),
          onPressed: closeWithCallback,
          isOutline: true,
        ),
        dialogButton(
          "OK",
          icon: Icon(Icons.done_rounded),
          onPressed: submit,
        ),
      ],
      onSubmit: submit,
      onCancel: closeWithCallback,
    );
  });
}

showSetOSAccount(
  SessionID sessionId,
  OverlayDialogManager dialogManager,
) async {
  final usernameController = TextEditingController();
  final passwdController = TextEditingController();
  var username =
      await bind.sessionGetOption(sessionId: sessionId, arg: 'os-username') ??
          '';
  var password =
      await bind.sessionGetOption(sessionId: sessionId, arg: 'os-password') ??
          '';
  usernameController.text = username;
  passwdController.text = password;
  dialogManager.show((setState, close, context) {
    submit() {
      final username = usernameController.text.trim();
      final password = usernameController.text.trim();
      bind.sessionPeerOption(
          sessionId: sessionId, name: 'os-username', value: username);
      bind.sessionPeerOption(
          sessionId: sessionId, name: 'os-password', value: password);
      close();
    }

    descWidget(String text) {
      return Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              text,
              maxLines: 3,
              softWrap: true,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 16),
            ),
          ),
          Container(
            height: 8,
          ),
        ],
      );
    }

    return CustomAlertDialog(
      title: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.password_rounded, color: MyTheme.accent),
          Text(translate('OS Account')).paddingOnly(left: 10),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          descWidget(translate("os_account_desk_tip")),
          DialogTextField(
            title: translate(DialogTextField.kUsernameTitle),
            controller: usernameController,
            prefixIcon: DialogTextField.kUsernameIcon,
            errorText: null,
          ),
          PasswordWidget(controller: passwdController),
        ],
      ),
      actions: [
        dialogButton(
          "Cancel",
          icon: Icon(Icons.close_rounded),
          onPressed: close,
          isOutline: true,
        ),
        dialogButton(
          "OK",
          icon: Icon(Icons.done_rounded),
          onPressed: submit,
        ),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

Widget buildNoteTextField({
  required TextEditingController controller,
  required VoidCallback onEscape,
}) {
  final focusNode = FocusNode(
    onKey: (FocusNode node, RawKeyEvent evt) {
      if (evt.logicalKey.keyLabel == 'Enter') {
        if (evt is RawKeyDownEvent) {
          int pos = controller.selection.base.offset;
          controller.text =
              '${controller.text.substring(0, pos)}\n${controller.text.substring(pos)}';
          controller.selection =
              TextSelection.fromPosition(TextPosition(offset: pos + 1));
        }
        return KeyEventResult.handled;
      }
      if (evt.logicalKey.keyLabel == 'Esc') {
        if (evt is RawKeyDownEvent) {
          onEscape();
        }
        return KeyEventResult.handled;
      } else {
        return KeyEventResult.ignored;
      }
    },
  );

  return TextField(
    autofocus: true,
    keyboardType: TextInputType.multiline,
    textInputAction: TextInputAction.newline,
    decoration: InputDecoration(
      hintText: translate('input note here'),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
      ),
      contentPadding: EdgeInsets.all(12),
    ),
    minLines: 5,
    maxLines: null,
    maxLength: 256,
    controller: controller,
    focusNode: focusNode,
  ).workaroundFreezeLinuxMint();
}

showAuditDialog(FFI ffi) async {
  final controller = TextEditingController(
      text: bind.sessionGetLastAuditNote(sessionId: ffi.sessionId));
  ffi.dialogManager.show((setState, close, context) {
    submit() {
      var text = controller.text;
      bind.sessionSendNote(sessionId: ffi.sessionId, note: text);
      close();
    }

    return CustomAlertDialog(
      title: Text(translate('Note')),
      content: SizedBox(
          width: 250,
          height: 120,
          child: buildNoteTextField(
            controller: controller,
            onEscape: close,
          )),
      actions: [
        dialogButton('Cancel', onPressed: close, isOutline: true),
        dialogButton('OK', onPressed: submit)
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

bool allowAskForNoteAtEndOfConnection(FFI? ffi, bool closedByControlling) {
  // REMOHELP PRO customization: suppress the end-of-connection audit-note prompt.
  // The dialog used to linger after a normal disconnect ("切断しました" が残る).
  // Server-side audit logging is unaffected; only the operator note prompt is
  // skipped so the viewer closes together with the disconnect.
  return false;
  // ignore: dead_code
  if (ffi == null) {
    return false;
  }
  return mainGetLocalBoolOptionSync(kOptionAllowAskForNoteAtEndOfConnection) &&
      bind
          .sessionGetAuditServerSync(sessionId: ffi.sessionId, typ: "conn")
          .isNotEmpty &&
      bind.sessionGetAuditGuid(sessionId: ffi.sessionId).isNotEmpty &&
      bind.sessionGetLastAuditNote(sessionId: ffi.sessionId).isEmpty &&
      (!closedByControlling ||
          bind.willSessionCloseCloseSession(sessionId: ffi.sessionId));
}

// return value: close canceled
//  true: return
//  false: go on
Future<bool> desktopTryShowTabAuditDialogCloseCancelled(
    {required String id, required DesktopTabController tabController}) async {
  try {
    final page =
        tabController.state.value.tabs.firstWhere((tab) => tab.key == id).page;
    final ffi = (page as dynamic).ffi;
    final res = await showConnEndAuditDialogCloseCanceled(ffi: ffi);
    return res;
  } catch (e) {
    debugPrint('Failed to show audit dialog: $e');
    return false;
  }
}

// return value:
//  true: return
//  false: go on
Future<bool> showConnEndAuditDialogCloseCanceled(
    {required FFI ffi, String? type, String? title, String? text}) async {
  final res = await _showConnEndAuditDialogCloseCanceled(
      ffi: ffi, type: type, title: title, text: text);
  if (res == true) {
    return true;
  }
  return false;
}

// return value:
//  true: return
//  false / null: go on
Future<bool?> _showConnEndAuditDialogCloseCanceled({
  required FFI ffi,
  String? type,
  String? title,
  String? text,
}) async {
  final closedByControlling = type == null;
  final showDialog = allowAskForNoteAtEndOfConnection(ffi, closedByControlling);
  if (!showDialog) {
    return false;
  }
  ffi.dialogManager.dismissAll();

  Future<void> updateAuditNoteByGuid(String auditGuid, String note) async {
    debugPrint('Updating audit note for GUID: $auditGuid, note: $note');
    try {
      final apiServer = await bind.mainGetApiServer();
      if (apiServer.isEmpty) {
        debugPrint('API server is empty, cannot update audit note');
        return;
      }
      final url = '$apiServer/api/audit';
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      final body = jsonEncode({
        'guid': auditGuid,
        'note': note,
      });

      final response = await http.put(
        Uri.parse(url),
        headers: headers,
        body: body,
      );

      if (response.statusCode == 200) {
        debugPrint('Successfully updated audit note for GUID: $auditGuid');
      } else {
        debugPrint(
            'Failed to update audit note. Status: ${response.statusCode}, Body: ${response.body}');
      }
    } catch (e) {
      debugPrint('Error updating audit note: $e');
    }
  }

  final controller = TextEditingController();
  bool askForNote =
      mainGetLocalBoolOptionSync(kOptionAllowAskForNoteAtEndOfConnection);
  final isOptFixed = isOptionFixed(kOptionAllowAskForNoteAtEndOfConnection);
  bool isInProgress = false;

  return await ffi.dialogManager.show<bool>((setState, close, context) {
    cancel() {
      close(true);
    }

    set() async {
      if (isInProgress) return;
      setState(() {
        isInProgress = true;
      });
      var text = controller.text;
      if (text.isNotEmpty) {
        await updateAuditNoteByGuid(
                bind.sessionGetAuditGuid(sessionId: ffi.sessionId), text)
            .timeout(const Duration(seconds: 6), onTimeout: () {
          debugPrint('updateAuditNoteByGuid timeout after 6s');
        });
      }
      // Save the "ask for note" preference
      if (!isOptFixed) {
        await mainSetLocalBoolOption(
            kOptionAllowAskForNoteAtEndOfConnection, askForNote);
      }
    }

    submit() async {
      await set();
      close(false);
    }

    final buttons = [
      dialogButton('OK', onPressed: isInProgress ? null : submit)
    ];
    if (type == 'relay-hint' || type == 'relay-hint2') {
      buttons.add(dialogButton('Retry', onPressed: () async {
        await set();
        close(true);
        ffi.ffiModel.reconnect(ffi.dialogManager, ffi.sessionId, false);
      }));
      if (type == 'relay-hint2') {
        buttons.add(dialogButton('Connect via relay', onPressed: () async {
          await set();
          close(true);
          ffi.ffiModel.reconnect(ffi.dialogManager, ffi.sessionId, true);
        }));
      }
    }
    if (closedByControlling) {
      buttons.add(dialogButton('Cancel',
          onPressed: isInProgress ? null : cancel, isOutline: true));
    }

    Widget content;
    if (closedByControlling) {
      content = SelectionArea(
          child: msgboxContent(
              'info', 'Close', 'Are you sure to close the connection?'));
    } else {
      content =
          SelectionArea(child: msgboxContent(type, title ?? '', text ?? ''));
    }

    return CustomAlertDialog(
      title: null,
      content: SizedBox(
          width: 350,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              content,
              const SizedBox(height: 16),
              SizedBox(
                height: 120,
                child: buildNoteTextField(
                  controller: controller,
                  onEscape: cancel,
                ),
              ),
              if (!isOptFixed) ...[
                const SizedBox(height: 8),
                InkWell(
                  onTap: () {
                    setState(() {
                      askForNote = !askForNote;
                    });
                  },
                  child: Row(
                    children: [
                      Checkbox(
                        value: askForNote,
                        onChanged: (value) {
                          setState(() {
                            askForNote = value ?? false;
                          });
                        },
                      ),
                      Expanded(
                        child: Text(
                          translate('note-at-conn-end-tip'),
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (isInProgress)
                const LinearProgressIndicator().marginOnly(top: 4),
            ],
          )),
      actions: buttons,
      onSubmit: submit,
      onCancel: cancel,
    );
  });
}

void showConfirmSwitchSidesDialog(
    SessionID sessionId, String id, OverlayDialogManager dialogManager) async {
  dialogManager.show((setState, close, context) {
    submit() async {
      await bind.sessionSwitchSides(sessionId: sessionId);
      closeConnection(id: id);
    }

    // 🔴 何が起きるかを具体的に書く（2026-07-26）。
    //   これを押すと **相談員のPCがお客様から操作される側になる**。
    //   元の文言は "Please confirm if you want to share your desktop?" だけで、
    //   「自分のPCが操作される」ことも「どう止めるか」も伝わらなかった。
    //   実機で「顧客に勝手に操作されても止める手段が分からない」という事故が起きている。
    return CustomAlertDialog(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'あなたの画面をお客様に見せます。',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            'この間、お客様はあなたのパソコンを操作できます。\n'
            'ソフトを入れていただかずに、その場で触っていただくときにお使いください。\n'
            '\n'
            'やめるときは、ご自分の画面に出る「接続」の窓の\n'
            '紫色の「画面を見せるのをやめる」を押してください。',
          ),
        ],
      ),
      actions: [
        dialogButton('Cancel', onPressed: close, isOutline: true),
        dialogButton('OK', onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

/// 繋いでいる相手が常駐版か。
///
/// 🔴 見分け方（2026-08-14・実際の生成コードで確かめた）。
///   デスクトップの接続番号は `id &= 0x1FFFFFFF` で29ビットに丸められる
///   （libs/hbb_common/src/config.rs の get_auto_id）。常駐だけが起動時に
///   `0x20000000` を立てて自分を分ける（src/server.rs の RESIDENT_ID_BIT）。
///   ＝ **デスクトップでこの印があるのは常駐だけ**。
///
/// ⚠ Android の番号は 10億〜20億で作られるため、**偶然この印を持つ**。
///   印だけで判定すると、Android のお客様を常駐と誤って扱う。
///   常駐は Windows にしか無いので、相手の種別も併せて見る。
///
/// ⚠ 相手の種別がまだ分からないうちは false。
///   迷ったら「常駐ではない」に倒す。ワンタイム向けの文言は、
///   常駐に出しても**お客様に余計なお願いをするだけ**で済むが、
///   逆（常駐向けの文言をワンタイムに出す）は
///   「次も繋げます」という**嘘**になる。
bool isResidentPeer(FFI? ffi) {
  if (ffi == null) return false;
  try {
    if (ffi.ffiModel.pi.platform != kPeerPlatformWindows) return false;
    final n = int.tryParse(ffi.id.trim());
    if (n == null) return false;
    // 🔴🔴 「そのビットが立っているか」ではなく「**製品の印が一致するか**」で見る
    //   （2026-08-27 実機で不具合を出して修正）。
    //
    //   ⚠ ワンタイム版に 0x6000_0000 を付けた 1.4.70 で、ここが true になり
    //     **ワンタイム版が「常駐」と誤判定**された。
    //     結果「自分の画面を見せる」がメニューから消えた。
    //   ★印は上位3ビット。常駐は 0x2000_0000「だけ」が立っている状態。
    //     相談員 0x4000_0000 ／ ワンタイム 0x8000_0000（src/server.rs）。
    //   ⚠ 印を増やすときは、必ず**単独のビット**にすること。
    return (n & 0xE0000000) == 0x20000000;
  } catch (_) {
    return false;
  }
}

/// 遠隔操作を終わるときの確認。
///
/// 🔴 ×は誤って押しやすい位置にある（2026-07-27 実機テストの指摘）。
///   これまでは押した瞬間に切れていた。サポートの最中に切れると、お客様に
///   もう一度アプリを起動して認証コードを入れ直してもらうことになり、
///   電話口で「すみません、もう一度…」から始めることになる。
///
///   ⚠ 上流には対応記録の入力ダイアログ（showConnEndAuditDialogCloseCanceled）が
///   あるが、あれは RustDesk の監査サーバーを立てているときにしか出ない。
///   当社は立てていないので**一度も出たことがない**。だからここで別に確認する。
///
/// 戻り値: true=終了してよい / false=やめる
/// 🔴 終わらせ方を1つに揃える（2026-07-31 ユーザー指示）。
///
///   終了の入口が3つあり、押す場所によって**起きることが違っていた**。
///     ・相談員コンソールの「サポートを終了」→ 本当に終わる
///     ・ビュアーの窓の ×                    → 窓が閉じるだけ
///     ・ツールバーの ×                      → 接続が切れるだけ
///   お客様側は終わっておらず、相談員は「終わった」と思っている。
///   どこを押しても**同じ確認・同じ結果**にする。
///
/// 戻り値: true=終了してよい / false=やめる
Future<bool> confirmCloseRemoteSession(OverlayDialogManager dialogManager,
    {FFI? ffi}) async {
  // 🔴🔴 再起動を待っている間は、**閉じてもサポートを終了しない**
  //   （2026-08-01 本番の記録で実害を確認）。
  //
  //   実際に起きたこと（セッション HF3V16）:
  //     21:11:17  接続・復帰の控えを作成（期限は 21:41:18）
  //     21:24:04  ビュアーがサポートを終了させた
  //     21:26:54  お客様のPCが戻ってきた → 403 で拒否
  //   **期限まで14分24秒残っていたのに、2分50秒前にこちらが終わらせていた。**
  //   お客様のPCはちゃんと戻ってきていたのに、迎える側が先に帰っていた。
  //
  //   ★「×を押したら終了」と「再起動中は待つ」が正面からぶつかっている。
  //     待っている最中は、閉じる＝諦めるとは限らない。窓が邪魔なだけかもしれない。
  //     ここで黙って終了させると、**お客様は締め出される**。
  //
  //   ⚠ 終了そのものを禁じない。相談員が「それでも終了する」と決めたなら従う。
  //     禁じると、本当に戻ってこないPCを永久に待つことになる。
  //     決めるのは相談員で、こちらは**何が起きるかを伝える**のが仕事。
  if (ffi != null) {
    final (state, remainSec) = await rlWatchReconnect(ffi);
    if (state == 'waiting') {
      final m = (remainSec / 60).ceil();
      final endNote = isResidentPeer(ffi)
          ? 'ここで終了しても、常駐しているので\nあとから繋ぎ直せます。'
          : 'ここで終了すると、お客様が戻ってきても\n'
              'つなぎ直せなくなります\n'
              '（認証コードの入れ直しが必要になります）。';
      final res = await dialogManager.show<bool>((setState, close, context) {
        return CustomAlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'お客様のパソコンが再起動中です',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                // 🔴🔴 **どれくらい待てばよいのか**を書く（2026-08-28 実測）。
                //
                //   ⚠ 元は「あと N 分待てます」＝**待てる上限**しか出しておらず、
                //     「ふつうどれくらいで戻るのか」がどこにも無かった。
                //     ＝ 相談員は目安が無いまま待ち、4分で閉じた。
                //   ★実測（顧客PCの記録・2026-08-28）:
                //       00:00:48 控えを用意 → 00:04:58 命令書が動く
                //       → 00:05:20 起動 → 00:05:32 復帰の要求
                //     ＝ **4分44秒**。うち大半は Windows の再起動とログイン。
                //   ⚠ 4分で閉じると間に合わない。だから先に伝える。
                '戻ってくるまで、ふつう 4〜6分 かかります。\n'
                '（Windows の再起動とログイン、起動の待ち時間を含みます）\n\n'
                'あと およそ $m 分、戻りを待つことができます。\n'
                '戻り次第、自動でつなぎ直します。\n\n'
                // ⚠ 常駐は入ったままなので、終了しても繋ぎ直せる。
                //   ここで「つなぎ直せなくなります」と出すと、相談員は
                //   起きていない不利益を避けようとして待ち続けてしまう。
                '$endNote',
              ),
            ],
          ),
          actions: [
            // 🔴🔴 **押しやすい方を「待つ」にする**（2026-08-28 実機で発生）。
            //
            //   ⚠ 実際に起きたこと（サーバーの記録で確認）:
            //     00:05:02  この確認が出た（state=waiting）
            //     00:05:04  ⚠ **2秒後**にサポートが終了された
            //     00:05:32  お客様が戻ってきた → 403（セッションが終了済み）
            //   ＝ お客様は**28秒差で締め出された**。
            //
            //   ⚠ 原因は文言ではなく**ボタンの見た目**だった。
            //     「待つ」が細い線の釦、「それでも終了する」が塗りつぶしの釦で、
            //     ⚠ **危ない方が「おすすめ」に見えていた**。人は塗りつぶしを押す。
            //   ★取り返しがつかない方を、押しにくい見た目にする。
            //     Enter の既定は元から「待つ」だったが、目で押す人には効かない。
            dialogButton('終了する', onPressed: () => close(true), isOutline: true),
            dialogButton('待つ（おすすめ）', onPressed: () => close(false)),
          ],
          onSubmit: () => close(false), // 既定は「待つ」。誤操作で締め出さない
          onCancel: () => close(false),
        );
      });
      return res == true;
    }
  }
  // 🔴 説明は出さない（2026-08-26 ご判断）。
  //   「終了すると何が起きるか」は顧客も相談員も分かっていること。
  //   ここは電話をしながら押す場所なので、読ませずに形で選べるのがよい。
  //
  //   経緯: 8/14 に「常駐では認証コードの入れ直しは要らない」ので文言を
  //   分けた（常駐に繋いでいるのに入れ直しを求める案内が出ていた）。
  //   今回はその説明ごと出さないことにしたので、分ける必要も無くなった。
  final res = await dialogManager.show<bool>((setState, close, context) {
    return CustomAlertDialog(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '遠隔接続を終了しますか？',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          // 🔴 説明は**全部**削った（2026-08-26 ご指摘）。
          //
          //   ⚠ ここは電話をしながら押す場所。読ませずに形で選べるのがよい。
          //   常駐は終了しても何も起きない。ワンタイムはお客様に認証コードを
          //   入れ直していただくことになるが、それは相談員が承知している前提。
          //   ★毎回同じ文を読ませるより、押す・押さないだけにする。
          //
          //   説明を戻すなら、ここに isResidentPeer(ffi) で分けて1行足す。
          const SizedBox.shrink(),
        ],
      ),
      actions: [
        // ⚠ 短く言い切る（2026-08-04 ご指示）。ここは電話をしながら押す場所なので、
        //   読ませずに形で選べるほうがよい。
        dialogButton('続ける', onPressed: () => close(false), isOutline: true),
        dialogButton('終了', onPressed: () => close(true)),
      ],
      onSubmit: () => close(true),
      onCancel: () => close(false),
    );
  });
  return res == true;
}

/// 接続が切れたとき、「待つべきか・終わったのか」を当社サーバーに尋ねる。
///
/// 🔴 これが無いと、相談員には**再起動も故障も同じ「接続エラー」**に見える
///   （2026-08-01 ユーザー指示で追加）。待てばいいのか諦めるのかが分からず、
///   毎回コンソールに戻って確かめることになっていた。
///
/// 返す値: ('waiting' | 'expired' | 'ended', 残り秒)
///   waiting … 戻ってくる見込みがある（繋ぎ直しを続ける）
///   expired … 待つ時間が尽きた（相談員側から終わらせる）
///   ended   … 既に終わっている
///
/// ⚠ 通信できないときは **waiting** を返す。相談員側の回線が一瞬切れただけで
///   サポートを終わらせてしまわないため。迷ったら終わらせない。
Future<(String, int)> rlWatchReconnect(FFI ffi) async {
  try {
    final id = ffi.id;
    final token = ffi.presetPassword ?? '';
    if (id.isEmpty || token.isEmpty) return ('ended', 0);
    final res = await http
        .post(
          Uri.parse('$kRlApiBase/api/customer/reconnect-watch'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'rustdeskId': id, 'token': token}),
        )
        .timeout(const Duration(seconds: 5));
    if (res.statusCode != 200) return ('waiting', 60);
    final j = jsonDecode(res.body) as Map;
    final state = (j['state'] as String?) ?? 'ended';
    final remain = (j['remainingSec'] as num?)?.toInt() ?? 0;
    debugPrint('RL reconnect-watch: $state 残り$remain秒');
    return (state, remain);
  } catch (e) {
    debugPrint('RL reconnect-watch: 尋ねられなかった $e');
    return ('waiting', 60);
  }
}

/// サポートの終了を、当社サーバーへ伝える。
///
/// 🔴 これを呼ばないと、接続が切れるだけで**セッションは終わらない**。
///   相談員は終わったつもりでも、お客様のアプリは動いたまま・
///   コンソールには「対応中」が残る。実際にそうなっていた。
///
/// ⚠ ビュアーは当社サーバーに利用者としてログインしていないため、
///   相談員の資格では呼べない。接続に使った**その回限りの合言葉**で
///   本人性を示す。合言葉が違えばサーバーは何もしない。
/// ⚠ 失敗しても呼び出し側は止めない。伝えられなくても、お客様側は
///   接続が切れてから一定時間で終わる（二重の保険）。
Future<void> notifySupportEnded(FFI ffi) async {
  try {
    final id = ffi.id;
    final token = ffi.presetPassword ?? '';
    // ⚠ 実機で「窓を閉じたのにサポートが終わらない」が起きた（2026-08-01）。
    //   この関数は失敗を握りつぶすので、**何が起きたか誰も分からなかった**。
    //   合言葉そのものは書かない（長さだけ）。相談員のPCのログに残す。
    debugPrint('RL end-by-viewer: id=$id tokenLen=${token.length}');
    if (id.isEmpty || token.isEmpty) {
      debugPrint('RL end-by-viewer: 送らない（IDか合言葉が空）');
      return;
    }
    // ⚠ この構成には既に http（utils/http_service.dart を as http で読み込み）がある。
    //   独自に package:http を足すと put/post の名前が衝突する。既存を使う。
    final res = await http.post(
      Uri.parse('$kRlApiBase/api/customer/end-by-viewer'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'rustdeskId': id, 'token': token}),
    ).timeout(const Duration(seconds: 5));
    debugPrint('RL end-by-viewer: 応答 ${res.statusCode}');
  } catch (e) {
    debugPrint('RL end-by-viewer: 送れなかった $e');
  }
}

customImageQualityDialog(SessionID sessionId, String id, FFI ffi) async {
  double initQuality = kDefaultQuality;
  double initFps = kDefaultFps;
  bool qualitySet = false;
  bool fpsSet = false;

  bool? direct;
  try {
    direct =
        ConnectionTypeState.find(id).direct.value == ConnectionType.strDirect;
  } catch (_) {}
  bool hideFps = (await bind.mainIsUsingPublicServer() && direct != true) ||
      versionCmp(ffi.ffiModel.pi.version, '1.2.0') < 0;
  bool hideMoreQuality =
      (await bind.mainIsUsingPublicServer() && direct != true) ||
          versionCmp(ffi.ffiModel.pi.version, '1.2.2') < 0;

  setCustomValues({double? quality, double? fps}) async {
    debugPrint("setCustomValues quality:$quality, fps:$fps");
    if (quality != null) {
      qualitySet = true;
      await bind.sessionSetCustomImageQuality(
          sessionId: sessionId, value: quality.toInt());
    }
    if (fps != null) {
      fpsSet = true;
      await bind.sessionSetCustomFps(sessionId: sessionId, fps: fps.toInt());
    }
    if (!qualitySet) {
      qualitySet = true;
      await bind.sessionSetCustomImageQuality(
          sessionId: sessionId, value: initQuality.toInt());
    }
    if (!hideFps && !fpsSet) {
      fpsSet = true;
      await bind.sessionSetCustomFps(
          sessionId: sessionId, fps: initFps.toInt());
    }
  }

  final btnClose = dialogButton('Close', onPressed: () async {
    await setCustomValues();
    ffi.dialogManager.dismissAll();
  });

  // quality
  final quality = await bind.sessionGetCustomImageQuality(sessionId: sessionId);
  initQuality = quality != null && quality.isNotEmpty
      ? quality[0].toDouble()
      : kDefaultQuality;
  if (initQuality < kMinQuality ||
      initQuality > (!hideMoreQuality ? kMaxMoreQuality : kMaxQuality)) {
    initQuality = kDefaultQuality;
  }
  // fps
  final fpsOption =
      await bind.sessionGetOption(sessionId: sessionId, arg: 'custom-fps');
  initFps = fpsOption == null
      ? kDefaultFps
      : double.tryParse(fpsOption) ?? kDefaultFps;
  if (initFps < kMinFps || initFps > kMaxFps) {
    initFps = kDefaultFps;
  }

  final content = customImageQualityWidget(
      initQuality: initQuality,
      initFps: initFps,
      setQuality: (v) => setCustomValues(quality: v),
      setFps: (v) => setCustomValues(fps: v),
      showFps: !hideFps,
      showMoreQuality: !hideMoreQuality);
  msgBoxCommon(ffi.dialogManager, 'Custom Image Quality', content, [btnClose]);
}

trackpadSpeedDialog(SessionID sessionId, FFI ffi) async {
  int initSpeed = ffi.inputModel.trackpadSpeed;
  final curSpeed = SimpleWrapper(initSpeed);
  final btnClose = dialogButton('Close', onPressed: () async {
    if (curSpeed.value <= kMaxTrackpadSpeed &&
        curSpeed.value >= kMinTrackpadSpeed &&
        curSpeed.value != initSpeed) {
      await bind.sessionSetTrackpadSpeed(
          sessionId: sessionId, value: curSpeed.value);
      await ffi.inputModel.updateTrackpadSpeed();
    }
    ffi.dialogManager.dismissAll();
  });
  msgBoxCommon(
      ffi.dialogManager,
      'Trackpad speed',
      TrackpadSpeedWidget(
        value: curSpeed,
      ),
      [btnClose]);
}

void deleteConfirmDialog(Function onSubmit, String title) async {
  gFFI.dialogManager.show(
    (setState, close, context) {
      submit() async {
        await onSubmit();
        close();
      }

      return CustomAlertDialog(
        title: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.delete_rounded,
              color: Colors.red,
            ),
            Expanded(
              child: Text(title, overflow: TextOverflow.ellipsis).paddingOnly(
                left: 10,
              ),
            ),
          ],
        ),
        content: SizedBox.shrink(),
        actions: [
          dialogButton(
            "Cancel",
            icon: Icon(Icons.close_rounded),
            onPressed: close,
            isOutline: true,
          ),
          dialogButton(
            "OK",
            icon: Icon(Icons.done_rounded),
            onPressed: submit,
          ),
        ],
        onSubmit: submit,
        onCancel: close,
      );
    },
  );
}

void editAbTagDialog(
    List<dynamic> currentTags, Function(List<dynamic>) onSubmit) {
  var isInProgress = false;

  final tags = List.of(gFFI.abModel.currentAbTags);
  var selectedTag = currentTags.obs;

  gFFI.dialogManager.show((setState, close, context) {
    submit() async {
      setState(() {
        isInProgress = true;
      });
      await onSubmit(selectedTag);
      close();
    }

    return CustomAlertDialog(
      title: Text(translate("Edit Tag")),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: Wrap(
              children: tags
                  .map((e) => AddressBookTag(
                      name: e,
                      tags: selectedTag,
                      onTap: () {
                        if (selectedTag.contains(e)) {
                          selectedTag.remove(e);
                        } else {
                          selectedTag.add(e);
                        }
                      },
                      showActionMenu: false))
                  .toList(growable: false),
            ),
          ),
          // NOT use Offstage to wrap LinearProgressIndicator
          if (isInProgress) const LinearProgressIndicator(),
        ],
      ),
      actions: [
        dialogButton("Cancel", onPressed: close, isOutline: true),
        dialogButton("OK", onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

void editAbPeerNoteDialog(String id) {
  var isInProgress = false;
  final currentNote = gFFI.abModel.getPeerNote(id);
  var controller = TextEditingController(text: currentNote);

  gFFI.dialogManager.show((setState, close, context) {
    submit() async {
      setState(() {
        isInProgress = true;
      });
      await gFFI.abModel.changeNote(id: id, note: controller.text);
      close();
    }

    return CustomAlertDialog(
      title: Text(translate("Edit note")),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: controller,
            autofocus: true,
            maxLines: 3,
            minLines: 1,
            maxLength: 300,
            decoration: InputDecoration(
              labelText: translate('Note'),
            ),
          ).workaroundFreezeLinuxMint(),
          // NOT use Offstage to wrap LinearProgressIndicator
          if (isInProgress) const LinearProgressIndicator(),
        ],
      ),
      actions: [
        dialogButton("Cancel", onPressed: close, isOutline: true),
        dialogButton("OK", onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

void renameDialog(
    {required String oldName,
    FormFieldValidator<String>? validator,
    required ValueChanged<String> onSubmit,
    Function? onCancel}) async {
  RxBool isInProgress = false.obs;
  var controller = TextEditingController(text: oldName);
  final formKey = GlobalKey<FormState>();
  gFFI.dialogManager.show((setState, close, context) {
    submit() async {
      String text = controller.text.trim();
      if (validator != null && formKey.currentState?.validate() == false) {
        return;
      }
      isInProgress.value = true;
      onSubmit(text);
      close();
      isInProgress.value = false;
    }

    cancel() {
      onCancel?.call();
      close();
    }

    return CustomAlertDialog(
      title: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.edit_rounded, color: MyTheme.accent),
          Text(translate('Rename')).paddingOnly(left: 10),
        ],
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            child: Form(
              key: formKey,
              child: TextFormField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(labelText: translate('Name')),
                validator: validator,
              ).workaroundFreezeLinuxMint(),
            ),
          ),
          // NOT use Offstage to wrap LinearProgressIndicator
          Obx(() =>
              isInProgress.value ? const LinearProgressIndicator() : Offstage())
        ],
      ),
      actions: [
        dialogButton(
          "Cancel",
          icon: Icon(Icons.close_rounded),
          onPressed: cancel,
          isOutline: true,
        ),
        dialogButton(
          "OK",
          icon: Icon(Icons.done_rounded),
          onPressed: submit,
        ),
      ],
      onSubmit: submit,
      onCancel: cancel,
    );
  });
}

void changeBot({Function()? callback}) async {
  if (bind.mainHasValidBotSync()) {
    await bind.mainSetOption(key: "bot", value: "");
    callback?.call();
    return;
  }
  String errorText = '';
  bool loading = false;
  final controller = TextEditingController();
  gFFI.dialogManager.show((setState, close, context) {
    onVerify() async {
      final token = controller.text.trim();
      if (token == "") return;
      loading = true;
      errorText = '';
      setState(() {});
      final error = await bind.mainVerifyBot(token: token);
      if (error == "") {
        callback?.call();
        close();
      } else {
        errorText = translate(error);
        loading = false;
        setState(() {});
      }
    }

    final codeField = TextField(
      autofocus: true,
      controller: controller,
      decoration: InputDecoration(
        hintText: translate('Token'),
      ),
    ).workaroundFreezeLinuxMint();

    return CustomAlertDialog(
      title: Text(translate("Telegram bot")),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(translate("enable-bot-desc"),
                  style: TextStyle(fontSize: 12))
              .marginOnly(bottom: 12),
          Row(children: [Expanded(child: codeField)]),
          if (errorText != '')
            Text(errorText, style: TextStyle(color: Colors.red))
                .marginOnly(top: 12),
        ],
      ),
      actions: [
        dialogButton("Cancel", onPressed: close, isOutline: true),
        loading
            ? CircularProgressIndicator()
            : dialogButton("OK", onPressed: onVerify),
      ],
      onCancel: close,
    );
  });
}

void change2fa({Function()? callback}) async {
  if (bind.mainHasValid2FaSync()) {
    await bind.mainSetOption(key: "2fa", value: "");
    await bind.mainClearTrustedDevices();
    callback?.call();
    return;
  }
  var new2fa = (await bind.mainGenerate2Fa());
  final secretRegex = RegExp(r'secret=([^&]+)');
  final secret = secretRegex.firstMatch(new2fa)?.group(1);
  String? errorText;
  final controller = TextEditingController();
  gFFI.dialogManager.show((setState, close, context) {
    onVerify() async {
      if (await bind.mainVerify2Fa(code: controller.text.trim())) {
        callback?.call();
        close();
      } else {
        errorText = translate('wrong-2fa-code');
      }
    }

    final codeField = Dialog2FaField(
      controller: controller,
      errorText: errorText,
      onChanged: () => setState(() => errorText = null),
      title: translate('Verification code'),
      readyCallback: () {
        onVerify();
        setState(() {});
      },
    );

    getOnSubmit() => codeField.isReady ? onVerify : null;

    return CustomAlertDialog(
      title: Text(translate("enable-2fa-title")),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(translate("enable-2fa-desc"),
                  style: TextStyle(fontSize: 12))
              .marginOnly(bottom: 12),
          SizedBox(
              width: 160,
              height: 160,
              child: QrImageView(
                backgroundColor: Colors.white,
                data: new2fa,
                version: QrVersions.auto,
                size: 160,
                gapless: false,
              )).marginOnly(bottom: 6),
          SelectableText(secret ?? '', style: TextStyle(fontSize: 12))
              .marginOnly(bottom: 12),
          Row(children: [Expanded(child: codeField)]),
        ],
      ),
      actions: [
        dialogButton("Cancel", onPressed: close, isOutline: true),
        dialogButton("OK", onPressed: getOnSubmit()),
      ],
      onCancel: close,
    );
  });
}

void enter2FaDialog(
    SessionID sessionId, OverlayDialogManager dialogManager) async {
  final controller = TextEditingController();
  final RxBool submitReady = false.obs;
  final RxBool trustThisDevice = false.obs;

  dialogManager.dismissAll();
  dialogManager.show((setState, close, context) {
    cancel() {
      close();
      closeConnection();
    }

    submit() {
      gFFI.send2FA(sessionId, controller.text.trim(), trustThisDevice.value);
      close();
      dialogManager.showLoading(translate('Logging in...'),
          onCancel: closeConnection);
    }

    late Dialog2FaField codeField;

    codeField = Dialog2FaField(
      controller: controller,
      title: translate('Verification code'),
      onChanged: () => submitReady.value = codeField.isReady,
    );

    final trustField = Obx(() => CheckboxListTile(
          contentPadding: const EdgeInsets.all(0),
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(translate("Trust this device")),
          value: trustThisDevice.value,
          onChanged: (value) {
            if (value == null) return;
            trustThisDevice.value = value;
          },
        ));

    return CustomAlertDialog(
        title: Text(translate('enter-2fa-title')),
        content: Column(
          children: [
            codeField,
            if (bind.sessionGetEnableTrustedDevices(sessionId: sessionId))
              trustField,
          ],
        ),
        actions: [
          dialogButton('Cancel',
              onPressed: cancel,
              isOutline: true,
              style: TextStyle(
                  color: Theme.of(context).textTheme.bodyMedium?.color)),
          Obx(() => dialogButton(
                'OK',
                onPressed: submitReady.isTrue ? submit : null,
              )),
        ],
        onSubmit: submit,
        onCancel: cancel);
  });
}

// This dialog should not be dismissed, otherwise it will be black screen, have not reproduced this.
void showWindowsSessionsDialog(
    String type,
    String title,
    String text,
    OverlayDialogManager dialogManager,
    SessionID sessionId,
    String peerId,
    String sessions) {
  List<dynamic> sessionsList = [];
  try {
    sessionsList = json.decode(sessions);
  } catch (e) {
    print(e);
  }
  List<String> sids = [];
  List<String> names = [];
  for (var session in sessionsList) {
    sids.add(session['sid']);
    names.add(session['name']);
  }
  String selectedUserValue = sids.first;
  dialogManager.dismissAll();
  dialogManager.show((setState, close, context) {
    submit() {
      bind.sessionSendSelectedSessionId(
          sessionId: sessionId, sid: selectedUserValue);
      close();
    }

    return CustomAlertDialog(
      title: null,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          msgboxContent(type, title, text).marginOnly(bottom: 12),
          ComboBox(
              keys: sids,
              values: names,
              initialKey: selectedUserValue,
              onChanged: (value) {
                selectedUserValue = value;
              }),
        ],
      ),
      actions: [
        dialogButton('Connect', onPressed: submit, isOutline: false),
      ],
    );
  });
}

void addPeersToAbDialog(
  List<Peer> peers,
) async {
  Future<bool> addTo(String abname) async {
    final mapList = peers.map((e) {
      var json = e.toJson();
      // remove password when add to another address book to avoid re-share
      json.remove('password');
      json.remove('hash');
      return json;
    }).toList();
    final errMsg = await gFFI.abModel.addPeersTo(mapList, abname);
    if (errMsg == null) {
      showToast(translate('Successful'));
      return true;
    } else {
      BotToast.showText(text: errMsg, contentColor: Colors.red);
      return false;
    }
  }

  // if only one address book and it is personal, add to it directly
  if (gFFI.abModel.addressbooks.length == 1 &&
      gFFI.abModel.current.isPersonal()) {
    await addTo(gFFI.abModel.currentName.value);
    return;
  }

  RxBool isInProgress = false.obs;
  final names = gFFI.abModel.addressBooksCanWrite();
  RxString currentName = gFFI.abModel.currentName.value.obs;
  TextEditingController controller = TextEditingController();
  if (gFFI.peerTabModel.currentTab == PeerTabIndex.ab.index) {
    names.remove(currentName.value);
  }
  if (names.isEmpty) {
    debugPrint('no address book to add peers to, should not happen');
    return;
  }
  if (!names.contains(currentName.value)) {
    currentName.value = names[0];
  }
  gFFI.dialogManager.show((setState, close, context) {
    submit() async {
      if (controller.text != gFFI.abModel.translatedName(currentName.value)) {
        BotToast.showText(
            text: 'illegal address book name: ${controller.text}',
            contentColor: Colors.red);
        return;
      }
      isInProgress.value = true;
      if (await addTo(currentName.value)) {
        close();
      }
      isInProgress.value = false;
    }

    cancel() {
      close();
    }

    return CustomAlertDialog(
      title: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(IconFont.addressBook, color: MyTheme.accent),
          Text(translate('Add to address book')).paddingOnly(left: 10),
        ],
      ),
      content: Obx(() => Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // https://github.com/flutter/flutter/issues/145081
              DropdownMenu(
                initialSelection: currentName.value,
                onSelected: (value) {
                  if (value != null) {
                    currentName.value = value;
                  }
                },
                dropdownMenuEntries: names
                    .map((e) => DropdownMenuEntry(
                        value: e, label: gFFI.abModel.translatedName(e)))
                    .toList(),
                inputDecorationTheme: InputDecorationTheme(
                    isDense: true, border: UnderlineInputBorder()),
                enableFilter: true,
                controller: controller,
              ),
              // NOT use Offstage to wrap LinearProgressIndicator
              isInProgress.value ? const LinearProgressIndicator() : Offstage()
            ],
          )),
      actions: [
        dialogButton(
          "Cancel",
          icon: Icon(Icons.close_rounded),
          onPressed: cancel,
          isOutline: true,
        ),
        dialogButton(
          "OK",
          icon: Icon(Icons.done_rounded),
          onPressed: submit,
        ),
      ],
      onSubmit: submit,
      onCancel: cancel,
    );
  });
}

void setSharedAbPasswordDialog(String abName, Peer peer) {
  TextEditingController controller = TextEditingController(text: '');
  RxBool isInProgress = false.obs;
  RxBool isInputEmpty = true.obs;
  bool passwordVisible = false;
  controller.addListener(() {
    isInputEmpty.value = controller.text.isEmpty;
  });
  gFFI.dialogManager.show((setState, close, context) {
    change(String password) async {
      isInProgress.value = true;
      bool res =
          await gFFI.abModel.changeSharedPassword(abName, peer.id, password);
      isInProgress.value = false;
      if (res) {
        showToast(translate('Successful'));
      }
      close();
    }

    cancel() {
      close();
    }

    return CustomAlertDialog(
      title: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.key, color: MyTheme.accent),
          Text(translate(peer.password.isEmpty
                  ? 'Set shared password'
                  : 'Change Password'))
              .paddingOnly(left: 10),
        ],
      ),
      content: Obx(() => Column(children: [
            TextField(
              controller: controller,
              autofocus: true,
              obscureText: !passwordVisible,
              decoration: InputDecoration(
                suffixIcon: IconButton(
                  icon: Icon(
                      passwordVisible ? Icons.visibility : Icons.visibility_off,
                      color: MyTheme.lightTheme.primaryColor),
                  onPressed: () {
                    setState(() {
                      passwordVisible = !passwordVisible;
                    });
                  },
                ),
              ),
            ).workaroundFreezeLinuxMint(),
            if (!gFFI.abModel.current.isPersonal())
              Row(children: [
                Icon(Icons.info, color: Colors.amber).marginOnly(right: 4),
                Text(
                  translate('share_warning_tip'),
                  style: TextStyle(fontSize: 12),
                )
              ]).marginSymmetric(vertical: 10),
            // NOT use Offstage to wrap LinearProgressIndicator
            isInProgress.value ? const LinearProgressIndicator() : Offstage()
          ])),
      actions: [
        dialogButton(
          "Cancel",
          icon: Icon(Icons.close_rounded),
          onPressed: cancel,
          isOutline: true,
        ),
        if (peer.password.isNotEmpty)
          dialogButton(
            "Remove",
            icon: Icon(Icons.delete_outline_rounded),
            onPressed: () => change(''),
            buttonStyle: ButtonStyle(
                backgroundColor: MaterialStatePropertyAll(Colors.red)),
          ),
        Obx(() => dialogButton(
              "OK",
              icon: Icon(Icons.done_rounded),
              onPressed:
                  isInputEmpty.value ? null : () => change(controller.text),
            )),
      ],
      onSubmit: isInputEmpty.value ? null : () => change(controller.text),
      onCancel: cancel,
    );
  });
}

void CommonConfirmDialog(OverlayDialogManager dialogManager, String content,
    VoidCallback onConfirm) {
  dialogManager.show((setState, close, context) {
    submit() {
      close();
      onConfirm.call();
    }

    return CustomAlertDialog(
      content: Row(
        children: [
          Expanded(
            child: Text(content,
                style: const TextStyle(fontSize: 15),
                textAlign: TextAlign.start),
          ),
        ],
      ).marginOnly(bottom: 12),
      actions: [
        dialogButton(translate("Cancel"), onPressed: close, isOutline: true),
        dialogButton(translate("OK"), onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

void changeUnlockPinDialog(String oldPin, Function() callback) {
  final pinController = TextEditingController(text: oldPin);
  final confirmController = TextEditingController(text: oldPin);
  String? pinErrorText;
  String? confirmationErrorText;
  final maxLength = bind.mainMaxEncryptLen();
  gFFI.dialogManager.show((setState, close, context) {
    submit() async {
      pinErrorText = null;
      confirmationErrorText = null;
      final pin = pinController.text.trim();
      final confirm = confirmController.text.trim();
      if (pin != confirm) {
        setState(() {
          confirmationErrorText =
              translate('The confirmation is not identical.');
        });
        return;
      }
      final errorMsg = bind.mainSetUnlockPin(pin: pin);
      if (errorMsg != '') {
        setState(() {
          pinErrorText = translate(errorMsg);
        });
        return;
      }
      callback.call();
      close();
    }

    return CustomAlertDialog(
      title: Text(translate("Set PIN")),
      content: Column(
        children: [
          DialogTextField(
            title: 'PIN',
            controller: pinController,
            obscureText: true,
            errorText: pinErrorText,
            maxLength: maxLength,
          ),
          DialogTextField(
            title: translate('Confirmation'),
            controller: confirmController,
            obscureText: true,
            errorText: confirmationErrorText,
            maxLength: maxLength,
          )
        ],
      ).marginOnly(bottom: 12),
      actions: [
        dialogButton(translate("Cancel"), onPressed: close, isOutline: true),
        dialogButton(translate("OK"), onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

void checkUnlockPinDialog(String correctPin, Function() passCallback) {
  final controller = TextEditingController();
  String? errorText;
  gFFI.dialogManager.show((setState, close, context) {
    submit() async {
      final pin = controller.text.trim();
      if (correctPin != pin) {
        setState(() {
          errorText = translate('Wrong PIN');
        });
        return;
      }
      passCallback.call();
      close();
    }

    return CustomAlertDialog(
      content: Row(
        children: [
          Expanded(
              child: PasswordWidget(
            title: 'PIN',
            controller: controller,
            errorText: errorText,
            hintText: '',
          ))
        ],
      ).marginOnly(bottom: 12),
      actions: [
        dialogButton(translate("Cancel"), onPressed: close, isOutline: true),
        dialogButton(translate("OK"), onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

void confrimDeleteTrustedDevicesDialog(
    RxList<TrustedDevice> trustedDevices, RxList<Uint8List> selectedDevices) {
  CommonConfirmDialog(gFFI.dialogManager, '${translate('Confirm Delete')}?',
      () async {
    if (selectedDevices.isEmpty) return;
    if (selectedDevices.length == trustedDevices.length) {
      await bind.mainClearTrustedDevices();
      trustedDevices.clear();
      selectedDevices.clear();
    } else {
      final json = jsonEncode(selectedDevices.map((e) => e.toList()).toList());
      await bind.mainRemoveTrustedDevices(json: json);
      trustedDevices.removeWhere((element) {
        return selectedDevices.contains(element.hwid);
      });
      selectedDevices.clear();
    }
  });
}

void manageTrustedDeviceDialog() async {
  RxList<TrustedDevice> trustedDevices = (await TrustedDevice.get()).obs;
  RxList<Uint8List> selectedDevices = RxList.empty();
  gFFI.dialogManager.show((setState, close, context) {
    return CustomAlertDialog(
      title: Text(translate("Manage trusted devices")),
      content: trustedDevicesTable(trustedDevices, selectedDevices),
      actions: [
        Obx(() => dialogButton(translate("Delete"),
                onPressed: selectedDevices.isEmpty
                    ? null
                    : () {
                        confrimDeleteTrustedDevicesDialog(
                          trustedDevices,
                          selectedDevices,
                        );
                      },
                isOutline: false)
            .marginOnly(top: 12)),
        dialogButton(translate("Close"), onPressed: close, isOutline: true)
            .marginOnly(top: 12),
      ],
      onCancel: close,
    );
  });
}

class TrustedDevice {
  late final Uint8List hwid;
  late final int time;
  late final String id;
  late final String name;
  late final String platform;

  TrustedDevice.fromJson(Map<String, dynamic> json) {
    final hwidList = json['hwid'] as List<dynamic>;
    hwid = Uint8List.fromList(hwidList.cast<int>());
    time = json['time'];
    id = json['id'];
    name = json['name'];
    platform = json['platform'];
  }

  String daysRemaining() {
    final expiry = time + 90 * 24 * 60 * 60 * 1000;
    final remaining = expiry - DateTime.now().millisecondsSinceEpoch;
    if (remaining < 0) {
      return '0';
    }
    return (remaining / (24 * 60 * 60 * 1000)).toStringAsFixed(0);
  }

  static Future<List<TrustedDevice>> get() async {
    final List<TrustedDevice> devices = List.empty(growable: true);
    try {
      final devicesJson = await bind.mainGetTrustedDevices();
      if (devicesJson.isNotEmpty) {
        final devicesList = json.decode(devicesJson);
        if (devicesList is List) {
          for (var device in devicesList) {
            devices.add(TrustedDevice.fromJson(device));
          }
        }
      }
    } catch (e) {
      print(e.toString());
    }
    devices.sort((a, b) => b.time.compareTo(a.time));
    return devices;
  }
}

Widget trustedDevicesTable(
    RxList<TrustedDevice> devices, RxList<Uint8List> selectedDevices) {
  RxBool selectAll = false.obs;
  setSelectAll() {
    if (selectedDevices.isNotEmpty &&
        selectedDevices.length == devices.length) {
      selectAll.value = true;
    } else {
      selectAll.value = false;
    }
  }

  devices.listen((_) {
    setSelectAll();
  });
  selectedDevices.listen((_) {
    setSelectAll();
  });
  return FittedBox(
    child: Obx(() => DataTable(
          columns: [
            DataColumn(
                label: Checkbox(
              value: selectAll.value,
              onChanged: (value) {
                if (value == true) {
                  selectedDevices.clear();
                  selectedDevices.addAll(devices.map((e) => e.hwid));
                } else {
                  selectedDevices.clear();
                }
              },
            )),
            DataColumn(label: Text(translate('Platform'))),
            DataColumn(label: Text(translate('ID'))),
            DataColumn(label: Text(translate('Username'))),
            DataColumn(label: Text(translate('Days remaining'))),
          ],
          rows: devices.map((device) {
            return DataRow(cells: [
              DataCell(Checkbox(
                value: selectedDevices.contains(device.hwid),
                onChanged: (value) {
                  if (value == null) return;
                  if (value) {
                    selectedDevices.remove(device.hwid);
                    selectedDevices.add(device.hwid);
                  } else {
                    selectedDevices.remove(device.hwid);
                  }
                },
              )),
              DataCell(Text(device.platform)),
              DataCell(Text(device.id)),
              DataCell(Text(device.name)),
              DataCell(Text(device.daysRemaining())),
            ]);
          }).toList(),
        )),
  );
}

/// 🔴 お客様のパソコンの情報を見せる（2026-08-26 ご要望）。
///
///   ⚠ これまで相談員に分かるのは接続番号と名前だけだった。
///     「メモリはいくつですか」をお客様に聞いても、答えられない方が多い。
///   ★繋いだ時点で分かるものを、そのまま並べる。
///
///   ⚠ グローバルIPは、お客様のパソコンが**当社のサーバーに聞いた**値
///     （/api/whoami）。パソコンは自分のグローバルIPを自分では知らないので、
///     起動時に一度だけ聞いている。第三者のIP判定サイトは使わない。
///     まだ取れていなければ、行ごと出さない。
///   ⚠ 値が無い項目は行ごと出さない。空欄が並ぶと、壊れているように見える。
void showRemoteSysinfoDialog(PeerInfo pi, String id, String version,
    OverlayDialogManager dialogManager) {
  Map<String, dynamic> info = {};
  try {
    final raw = pi.platformAdditions[kPlatformAdditionsRlSysinfo];
    if (raw is Map) {
      info = Map<String, dynamic>.from(raw);
    }
  } catch (_) {
    // 読めなくても画面を止めない。空のまま出す。
  }

  String s(String key) => (info[key] ?? '').toString().trim();

  final rows = <List<String>>[
    ['接続番号', id],
    ['コンピューター名', s('hostname')],
    ['ログイン中のユーザー', s('username')],
    ['OS', s('os')],
    ['CPU', s('cpu')],
    ['メモリ', s('memory')],
    ['グローバルIP', s('global_ip')],
    ['ローカルIP', s('local_ips')],
    ['アプリの版', version],
  ].where((r) => r[1].isNotEmpty).toList();

  dialogManager.show((setState, close, context) {
    return CustomAlertDialog(
      title: Text(translate('Remote system info')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...rows.map((r) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 140,
                      child: Text(r[0],
                          style: const TextStyle(color: Colors.grey)),
                    ),
                    Expanded(child: SelectableText(r[1])),
                  ],
                ),
              )),
        ],
      ),
      actions: [
        // ⚠ 控えを取れるようにする。対応記録に貼るため。
        dialogButton('Copy', onPressed: () {
          final text = rows.map((r) => '${r[0]}: ${r[1]}').join('\n');
          Clipboard.setData(ClipboardData(text: text));
          showToast(translate('Copied'));
        }, isOutline: true),
        dialogButton('Close', onPressed: close),
      ],
      onCancel: close,
    );
  });
}
