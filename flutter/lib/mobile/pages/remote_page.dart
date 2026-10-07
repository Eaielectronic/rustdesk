import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/common/widgets/toolbar.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/mobile/widgets/floating_mouse.dart';
import 'package:flutter_hbb/mobile/widgets/floating_mouse_widgets.dart';
import 'package:flutter_hbb/mobile/widgets/gesture_help.dart';
import 'package:flutter_hbb/models/chat_model.dart';
import 'package:flutter_keyboard_visibility/flutter_keyboard_visibility.dart';
import 'package:flutter_svg/svg.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';

import '../../common.dart';
import '../../common/widgets/overlay.dart';
import '../../common/widgets/dialog.dart';
import '../../common/widgets/remote_input.dart';
import '../../models/input_model.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import '../../utils/image.dart';
import '../widgets/dialog.dart';
import '../widgets/custom_scale_widget.dart';

final initText = '1' * 1024;

// Workaround for Android (default input method, Microsoft SwiftKey keyboard) when using physical keyboard.
// When connecting a physical keyboard, `KeyEvent.physicalKey.usbHidUsage` are wrong is using Microsoft SwiftKey keyboard.
// https://github.com/flutter/flutter/issues/159384
// https://github.com/flutter/flutter/issues/159383
void _disableAndroidSoftKeyboard({bool? isKeyboardVisible}) {
  if (isAndroid) {
    if (isKeyboardVisible != true) {
      // `enable_soft_keyboard` will be set to `true` when clicking the keyboard icon, in `openKeyboard()`.
      gFFI.invokeMethod("enable_soft_keyboard", false);
    }
  }
}

class RemotePage extends StatefulWidget {
  RemotePage(
      {Key? key,
      required this.id,
      this.password,
      this.isSharedPassword,
      this.forceRelay})
      : super(key: key);

  final String id;
  final String? password;
  final bool? isSharedPassword;
  final bool? forceRelay;

  @override
  State<RemotePage> createState() => _RemotePageState(id);
}

class _RemotePageState extends State<RemotePage> with WidgetsBindingObserver {
  Timer? _timer;
  bool _showBar = false;
  bool _showGestureHelp = false;
  String _value = '';
  Orientation? _currentOrientation;
  final _uniqueKey = UniqueKey();
  Timer? _iosKeyboardWorkaroundTimer;

  final _blockableOverlayState = BlockableOverlayState();

  final keyboardVisibilityController = KeyboardVisibilityController();
  late final StreamSubscription<bool> keyboardSubscription;
  final FocusNode _mobileFocusNode = FocusNode();
  final FocusNode _physicalFocusNode = FocusNode();
  var _showEdit = false;

  Worker? _waylandKeyboardGateWorker;
  bool _waylandKeyboardGateInitialized = false;

  InputModel get inputModel => gFFI.inputModel;
  SessionID get sessionId => gFFI.sessionId;

  final TextEditingController _textController =
      TextEditingController(text: initText);
  bool _showQuickSendBar = true;
  final TextEditingController _quickSendController = TextEditingController();
  bool _sidePanelOpen = false;
  bool _showPcKeyboard = false;

  _RemotePageState(String id) {
    initSharedStates(id);
    gFFI.chatModel.voiceCallStatus.value = VoiceCallStatus.notStarted;
    gFFI.dialogManager.loadMobileActionsOverlayVisible();
  }

  @override
  void initState() {
    super.initState();
    gFFI.ffiModel.updateEventListener(sessionId, widget.id);
    gFFI.start(
      widget.id,
      password: widget.password,
      isSharedPassword: widget.isSharedPassword,
      forceRelay: widget.forceRelay,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: []);
      gFFI.dialogManager
          .showLoading(translate('Connecting...'), onCancel: closeConnection);
    });
    WakelockManager.enable(_uniqueKey);
    _physicalFocusNode.requestFocus();
    gFFI.inputModel.listenToMouse(true);
    gFFI.qualityMonitorModel.checkShowQualityMonitor(sessionId);
    gFFI.canvasModel.setLocked(true);
    bind.sessionSetViewStyle(sessionId: sessionId, value: kRemoteViewStyleAdaptive);
    gFFI.canvasModel.updateViewStyle();
    keyboardSubscription =
        keyboardVisibilityController.onChange.listen(onSoftKeyboardChanged);
    gFFI.chatModel
        .changeCurrentKey(MessageKey(widget.id, ChatModel.clientModeID));
    _blockableOverlayState.applyFfi(gFFI);
    gFFI.imageModel.addCallbackOnFirstImage((String peerId) {
      bind.sessionSetViewStyle(sessionId: sessionId, value: kRemoteViewStyleAdaptive);
      gFFI.canvasModel.updateViewStyle();
      gFFI.canvasModel.setLocked(true);
      gFFI.recordingModel
          .updateStatus(bind.sessionGetIsRecording(sessionId: gFFI.sessionId));
      if (gFFI.recordingModel.start) {
        showToast(translate('Automatically record outgoing sessions'));
      }
      _disableAndroidSoftKeyboard(
          isKeyboardVisible: keyboardVisibilityController.isVisible);
    });
    WidgetsBinding.instance.addObserver(this);

    inputModel.keyboardInputAllowed = true;

    // Wayland sessions may use clipboard-based text input on the controlled side.
    // Require explicit user confirmation before allowing soft-keyboard and
    // clipboard-assisted text input. Physical keyboard events are not gated here.
    _waylandKeyboardGateWorker = ever(gFFI.ffiModel.pi.isSet, (bool isSet) {
      if (isSet) {
        _initWaylandKeyboardGateIfNeeded();
      }
    });
    if (gFFI.ffiModel.pi.isSet.value) {
      _initWaylandKeyboardGateIfNeeded();
    }
  }

  @override
  Future<void> dispose() async {
    WidgetsBinding.instance.removeObserver(this);
    // Close the session up-front. `gFFI.close()` below only calls `sessionClose`
    // after several awaits (canvas save, image update, the `enable_soft_keyboard`
    // platform call), so if the app is backgrounded while this page is disposing,
    // dispose can be suspended before reaching it and the connection is never torn
    // down. The reconnect then re-attaches to the leaked session and is stuck on
    // "Connecting...". Dispatching it here makes teardown happen synchronously on
    // pop; the `sessionClose` in `gFFI.close()` becomes a no-op once removed.
    unawaited(bind.sessionClose(sessionId: sessionId));
    // https://github.com/flutter/flutter/issues/64935
    super.dispose();
    gFFI.dialogManager.hideMobileActionsOverlay(store: false);
    gFFI.inputModel.listenToMouse(false);
    gFFI.imageModel.disposeImage();
    gFFI.cursorModel.disposeImages();
    await gFFI.invokeMethod("enable_soft_keyboard", true);
    _mobileFocusNode.dispose();
    _physicalFocusNode.dispose();
    _quickSendController.dispose();
    clearWaylandKeyboardPromptSuppressedForConnection(sessionId.toString());
    _waylandKeyboardGateWorker?.dispose();
    inputModel.keyboardInputAllowed = true;
    await gFFI.close();
    _timer?.cancel();
    _iosKeyboardWorkaroundTimer?.cancel();
    gFFI.dialogManager.dismissAll();
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
        overlays: SystemUiOverlay.values);
    WakelockManager.disable(_uniqueKey);
    await keyboardSubscription.cancel();
    removeSharedStates(widget.id);
    // `on_voice_call_closed` should be called when the connection is ended.
    // The inner logic of `on_voice_call_closed` will check if the voice call is active.
    // Only one client is considered here for now.
    gFFI.chatModel.onVoiceCallClosed("End connection");
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      trySyncClipboard();
    }
  }

  // For client side
  // When swithing from other app to this app, try to sync clipboard.
  void trySyncClipboard() {
    gFFI.invokeMethod("try_sync_clipboard");
  }

  bool _shouldGateKeyboardForWayland() {
    if (!(isAndroid || isIOS)) return false;
    final pi = gFFI.ffiModel.pi;
    return pi.platform == kPeerPlatformLinux && pi.isWayland;
  }

  void _initWaylandKeyboardGateIfNeeded() {
    if (!mounted) return;
    if (_waylandKeyboardGateInitialized) return;
    if (!_shouldGateKeyboardForWayland()) return;

    _waylandKeyboardGateInitialized = true;

    final allowWaylandKeyboard =
        mainGetPeerBoolOptionSync(widget.id, kPeerOptionAllowWaylandKeyboard);
    if (!shouldShowWaylandKeyboardPrompt(
      connectionId: sessionId.toString(),
      isWaylandPeer: _shouldGateKeyboardForWayland(),
      allowWaylandKeyboardRemembered: allowWaylandKeyboard,
    )) {
      inputModel.keyboardInputAllowed = true;
      return;
    }

    inputModel.keyboardInputAllowed = false;

    // Ensure soft keyboard is not active before user confirms.
    _showEdit = false;
    gFFI.invokeMethod("enable_soft_keyboard", false);
    _mobileFocusNode.unfocus();
    _physicalFocusNode.requestFocus();
    setState(() {});
  }

  // to-do: It should be better to use transparent color instead of the bgColor.
  // But for now, the transparent color will cause the canvas to be white.
  // I'm sure that the white color is caused by the Overlay widget in BlockableOverlay.
  // But I don't know why and how to fix it.
  Widget emptyOverlay(Color bgColor) => BlockableOverlay(
        /// the Overlay key will be set with _blockableOverlayState in BlockableOverlay
        /// see override build() in [BlockableOverlay]
        state: _blockableOverlayState,
        underlying: Container(
          color: bgColor,
        ),
      );

  void onSoftKeyboardChanged(bool visible) {
    if (!visible) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: []);
      // [pi.version.isNotEmpty] -> check ready or not, avoid login without soft-keyboard
      if (gFFI.chatModel.chatWindowOverlayEntry == null &&
          gFFI.ffiModel.pi.version.isNotEmpty) {
        gFFI.invokeMethod("enable_soft_keyboard", false);
      }

      // Workaround for iOS: physical keyboard input fails after virtual keyboard is hidden
      // https://github.com/flutter/flutter/issues/39900
      // https://github.com/rustdesk/rustdesk/discussions/11843#discussioncomment-13499698 - Virtual keyboard issue
      if (isIOS) {
        _iosKeyboardWorkaroundTimer?.cancel();
        _iosKeyboardWorkaroundTimer = Timer(Duration(milliseconds: 100), () {
          if (!mounted) return;
          _physicalFocusNode.unfocus();
          _iosKeyboardWorkaroundTimer = Timer(Duration(milliseconds: 50), () {
            if (!mounted) return;
            _physicalFocusNode.requestFocus();
          });
        });
      }
    } else {
      _iosKeyboardWorkaroundTimer?.cancel();
      _iosKeyboardWorkaroundTimer = null;
      _timer?.cancel();
      _timer = Timer(kMobileDelaySoftKeyboardFocus, () {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
            overlays: SystemUiOverlay.values);
        _mobileFocusNode.requestFocus();
      });
    }
    // update for Scaffold
    setState(() {});
  }

  void _handleIOSSoftKeyboardInput(String newValue) {
    var oldValue = _value;
    _value = newValue;
    var i = newValue.length - 1;
    for (; i >= 0 && newValue[i] != '1'; --i) {}
    var j = oldValue.length - 1;
    for (; j >= 0 && oldValue[j] != '1'; --j) {}
    if (i < j) j = i;
    var subNewValue = newValue.substring(j + 1);
    var subOldValue = oldValue.substring(j + 1);

    // get common prefix of subNewValue and subOldValue
    var common = 0;
    for (;
        common < subOldValue.length &&
            common < subNewValue.length &&
            subNewValue[common] == subOldValue[common];
        ++common) {}

    // get newStr from subNewValue
    var newStr = "";
    if (subNewValue.length > common) {
      newStr = subNewValue.substring(common);
    }

    // Set the value to the old value and early return if is still composing. (1 && 2)
    // 1. The composing range is valid
    // 2. The new string is shorter than the composing range.
    if (_textController.value.isComposingRangeValid) {
      final composingLength = _textController.value.composing.end -
          _textController.value.composing.start;
      if (composingLength > newStr.length) {
        _value = oldValue;
        return;
      }
    }

    // Delete the different part in the old value.
    for (i = 0; i < subOldValue.length - common; ++i) {
      inputModel.inputKey('VK_BACK');
    }

    // Input the new string.
    if (newStr.length > 1) {
      bind.sessionInputString(sessionId: sessionId, value: newStr);
    } else {
      inputChar(newStr);
    }
  }

  void _handleNonIOSSoftKeyboardInput(String newValue) {
    var oldValue = _value;
    _value = newValue;
    if (oldValue.isNotEmpty &&
        newValue.isNotEmpty &&
        oldValue[0] == '1' &&
        newValue[0] != '1') {
      // clipboard
      oldValue = '';
    }
    if (newValue.length == oldValue.length) {
      // ?
    } else if (newValue.length < oldValue.length) {
      final char = 'VK_BACK';
      inputModel.inputKey(char);
    } else {
      final content = newValue.substring(oldValue.length);
      if (content.length > 1) {
        if (oldValue != '' &&
            content.length == 2 &&
            (content == '""' ||
                content == '()' ||
                content == '[]' ||
                content == '<>' ||
                content == "{}" ||
                content == '”“' ||
                content == '《》' ||
                content == '（）' ||
                content == '【】')) {
          // can not only input content[0], because when input ], [ are also auo insert, which cause ] never be input
          bind.sessionInputString(sessionId: sessionId, value: content);
          _openKeyboardUnlocked();
          return;
        }
        bind.sessionInputString(sessionId: sessionId, value: content);
      } else {
        inputChar(content);
      }
    }
  }

  // handle mobile virtual keyboard
  void handleSoftKeyboardInput(String newValue) {
    if (!inputModel.keyboardInputAllowed) {
      return;
    }
    if (isIOS) {
      _handleIOSSoftKeyboardInput(newValue);
    } else {
      _handleNonIOSSoftKeyboardInput(newValue);
    }
  }

  void inputChar(String char) {
    if (!inputModel.keyboardInputAllowed) {
      return;
    }
    if (char == '\n') {
      char = 'VK_RETURN';
    } else if (char == ' ') {
      char = 'VK_SPACE';
    }
    inputModel.inputKey(char);
  }

  void openKeyboard() {
    final allowWaylandKeyboard =
        mainGetPeerBoolOptionSync(widget.id, kPeerOptionAllowWaylandKeyboard);
    if (shouldShowWaylandKeyboardPrompt(
      connectionId: sessionId.toString(),
      isWaylandPeer: _shouldGateKeyboardForWayland(),
      allowWaylandKeyboardRemembered: allowWaylandKeyboard,
    )) {
      inputModel.keyboardInputAllowed = false;
      showWaylandKeyboardInputWarningDialog(
        id: widget.id,
        connectionId: sessionId.toString(),
        ffi: gFFI,
        onEnable: () async {
          _openKeyboardUnlocked();
        },
      );
      return;
    }
    _openKeyboardUnlocked();
  }

  void _openKeyboardUnlocked() {
    inputModel.keyboardInputAllowed = true;
    gFFI.invokeMethod("enable_soft_keyboard", true);
    // destroy first, so that our _value trick can work
    _value = initText;
    _textController.text = _value;
    setState(() => _showEdit = false);
    _timer?.cancel();
    _timer = Timer(kMobileDelaySoftKeyboard, () {
      // show now, and sleep a while to requestFocus to
      // make sure edit ready, so that keyboard won't show/hide/show/hide happen
      setState(() => _showEdit = true);
      _timer?.cancel();
      _timer = Timer(kMobileDelaySoftKeyboardFocus, () {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
            overlays: SystemUiOverlay.values);
        _mobileFocusNode.requestFocus();
      });
    });
  }

  Widget _bottomWidget() {
    if (_showGestureHelp) return getGestureHelp();
    return _buildGoogleBottomBar();
  }

  Widget _buildGoogleBottomBar() {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF202124),
        border: Border(
          top: BorderSide(color: Color(0xFF3C4043), width: 1),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black54,
            blurRadius: 10,
            offset: Offset(0, -3),
          ),
        ],
      ),
      padding: EdgeInsets.only(
        left: 10,
        right: 10,
        top: 8,
        bottom: 8 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_showPcKeyboard) _buildPcKeyboardShelf(),
            if (_showPcKeyboard) const SizedBox(height: 8),
            Row(
              children: [
                InkWell(
                  onTap: () => setState(() => _showPcKeyboard = !_showPcKeyboard),
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: _showPcKeyboard ? const Color(0xFF1A73E8) : const Color(0xFF303134),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _showPcKeyboard ? const Color(0xFF8AB4F8) : Colors.white24,
                        width: 1.2,
                      ),
                    ),
                    child: const Center(
                      child: Icon(
                        Icons.keyboard,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap: openKeyboard,
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFF303134),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white24, width: 1),
                    ),
                    child: const Center(
                      child: Icon(
                        Icons.keyboard_alt_outlined,
                        color: Colors.white70,
                        size: 24,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    height: 46,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(23),
                      border: Border.all(color: const Color(0xFFDADCE0), width: 1),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black12,
                          blurRadius: 4,
                          offset: Offset(0, 1),
                        ),
                      ],
                    ),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextField(
                      controller: _quickSendController,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                      cursorColor: const Color(0xFF1A73E8),
                      autofocus: false,
                      decoration: InputDecoration(
                        hintText: translate('Type text to send...'),
                        hintStyle: const TextStyle(
                          color: Color(0xFF9AA0A6),
                          fontSize: 14,
                        ),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                      onSubmitted: (val) {
                        if (val.isNotEmpty) {
                          bind.sessionInputString(sessionId: sessionId, value: val);
                          _quickSendController.clear();
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _quickSendController,
                  builder: (context, value, child) {
                    final isEmpty = value.text.isEmpty;
                    return GestureDetector(
                      onTap: () {
                        if (isEmpty) {
                          inputModel.inputKey('VK_BACK');
                        } else {
                          bind.sessionInputString(sessionId: sessionId, value: value.text);
                          _quickSendController.clear();
                        }
                      },
                      child: Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          color: isEmpty ? const Color(0xFF3C4043) : const Color(0xFF1A73E8),
                          shape: BoxShape.circle,
                          border: isEmpty ? Border.all(color: const Color(0xFF5F6368), width: 1) : null,
                          boxShadow: isEmpty
                              ? null
                              : const [
                                  BoxShadow(
                                    color: Color(0x551A73E8),
                                    blurRadius: 8,
                                    offset: Offset(0, 2),
                                  ),
                                ],
                        ),
                        child: Center(
                          child: Icon(
                            isEmpty ? Icons.backspace_outlined : Icons.send_rounded,
                            color: isEmpty ? Colors.white70 : Colors.white,
                            size: 20,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildGoogleActionBtn(Icons.close, () => clientClose(sessionId, gFFI), color: Colors.red[400]),
                _buildGoogleActionBtn(Icons.tv, () {
                  setState(() => _showEdit = false);
                  showOptions(context, widget.id, gFFI.dialogManager);
                }),
                _buildGoogleActionBtn(Icons.menu, () => setState(() => _sidePanelOpen = !_sidePanelOpen)),
                if (gFFI.ffiModel.isPeerAndroid)
                  _buildGoogleActionBtn(Icons.build, () => gFFI.dialogManager.toggleMobileActionsOverlay(ffi: gFFI)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGoogleActionBtn(IconData icon, VoidCallback onTap, {Color? color}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Icon(icon, color: color ?? Colors.white70, size: 26),
      ),
    );
  }

  Widget _buildPcKeyboardShelf() {
    final pi = gFFI.ffiModel.pi;
    final isMac = pi.platform == kPeerPlatformMacOS;
    return Container(
      constraints: const BoxConstraints(maxHeight: 210),
      decoration: BoxDecoration(
        color: const Color(0xFF202124),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF3C4043), width: 1),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 10, offset: Offset(0, -3)),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Icon(Icons.laptop_chromebook, color: Color(0xFF8AB4F8), size: 18),
                    const SizedBox(width: 6),
                    Text(
                      translate('PC Virtual Keyboard'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    InkWell(
                      onTap: openKeyboard,
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF303134),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.white24, width: 0.8),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.smartphone, color: Colors.white70, size: 14),
                            const SizedBox(width: 4),
                            Text(
                              translate('Mobile Keyboard'),
                              style: const TextStyle(color: Colors.white70, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: () => setState(() => _showPcKeyboard = false),
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        child: const Icon(Icons.close, color: Colors.white54, size: 18),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _pcKeyBtn('Ctrl', () => setState(() => inputModel.ctrl = !inputModel.ctrl), active: inputModel.ctrl),
                  const SizedBox(width: 6),
                  _pcKeyBtn('Alt', () => setState(() => inputModel.alt = !inputModel.alt), active: inputModel.alt),
                  const SizedBox(width: 6),
                  _pcKeyBtn('Shift', () => setState(() => inputModel.shift = !inputModel.shift), active: inputModel.shift),
                  const SizedBox(width: 6),
                  _pcKeyBtn(isMac ? 'Cmd' : 'Win', () => setState(() => inputModel.command = !inputModel.command), active: inputModel.command),
                  const SizedBox(width: 6),
                  _pcKeyBtn('Esc', () => inputModel.inputKey('VK_ESCAPE')),
                  const SizedBox(width: 6),
                  _pcKeyBtn('Tab', () => inputModel.inputKey('VK_TAB')),
                  const SizedBox(width: 6),
                  _pcKeyBtn('Enter', () => inputModel.inputKey('VK_RETURN')),
                  const SizedBox(width: 6),
                  _pcKeyBtn('Bksp', () => inputModel.inputKey('VK_BACK')),
                  const SizedBox(width: 6),
                  _pcKeyBtn('Del', () => inputModel.inputKey('VK_DELETE')),
                  const SizedBox(width: 6),
                  _pcKeyBtn('Ctrl+Alt+Del', () => bind.sessionCtrlAltDel(sessionId: sessionId)),
                ],
              ),
            ),
            const SizedBox(height: 6),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: List.generate(12, (index) {
                  final fnName = 'F${index + 1}';
                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: _pcKeyBtn(fnName, () => inputModel.inputKey('VK_$fnName')),
                  );
                }),
              ),
            ),
            const SizedBox(height: 6),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _pcKeyBtn('', () => inputModel.inputKey('VK_LEFT'), icon: Icons.arrow_back),
                  const SizedBox(width: 6),
                  _pcKeyBtn('', () => inputModel.inputKey('VK_UP'), icon: Icons.arrow_upward),
                  const SizedBox(width: 6),
                  _pcKeyBtn('', () => inputModel.inputKey('VK_DOWN'), icon: Icons.arrow_downward),
                  const SizedBox(width: 6),
                  _pcKeyBtn('', () => inputModel.inputKey('VK_RIGHT'), icon: Icons.arrow_forward),
                  const SizedBox(width: 6),
                  _pcKeyBtn('Home', () => inputModel.inputKey('VK_HOME')),
                  const SizedBox(width: 6),
                  _pcKeyBtn('End', () => inputModel.inputKey('VK_END')),
                  const SizedBox(width: 6),
                  _pcKeyBtn('PgUp', () => inputModel.inputKey('VK_PRIOR')),
                  const SizedBox(width: 6),
                  _pcKeyBtn('PgDn', () => inputModel.inputKey('VK_NEXT')),
                  const SizedBox(width: 6),
                  _pcKeyBtn('Space', () => inputModel.inputKey('VK_SPACE')),
                ],
              ),
            ),
            const SizedBox(height: 6),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _pcKeyBtn(translate('Select All'), () {
                    bind.sessionInputKey(sessionId: sessionId, name: 'a', down: false, press: true, alt: false, ctrl: true, shift: false, command: false);
                  }),
                  const SizedBox(width: 6),
                  _pcKeyBtn(translate('Copy'), () {
                    bind.sessionInputKey(sessionId: sessionId, name: 'c', down: false, press: true, alt: false, ctrl: true, shift: false, command: false);
                  }),
                  const SizedBox(width: 6),
                  _pcKeyBtn(translate('Paste'), () async {
                    ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
                    if (data != null && data.text != null && data.text!.isNotEmpty) {
                      bind.sessionInputString(sessionId: sessionId, value: data.text!);
                    } else {
                      bind.sessionInputKey(sessionId: sessionId, name: 'v', down: false, press: true, alt: false, ctrl: true, shift: false, command: false);
                    }
                  }),
                  const SizedBox(width: 6),
                  _pcKeyBtn(translate('Cut'), () {
                    bind.sessionInputKey(sessionId: sessionId, name: 'x', down: false, press: true, alt: false, ctrl: true, shift: false, command: false);
                  }),
                  const SizedBox(width: 6),
                  _pcKeyBtn('Undo', () {
                    bind.sessionInputKey(sessionId: sessionId, name: 'z', down: false, press: true, alt: false, ctrl: true, shift: false, command: false);
                  }),
                  const SizedBox(width: 6),
                  _pcKeyBtn('Alt+Tab', () {
                    bind.sessionInputKey(sessionId: sessionId, name: 'Tab', down: false, press: true, alt: true, ctrl: false, shift: false, command: false);
                  }),
                  const SizedBox(width: 6),
                  _pcKeyBtn('Alt+F4', () {
                    bind.sessionInputKey(sessionId: sessionId, name: 'F4', down: false, press: true, alt: true, ctrl: false, shift: false, command: false);
                  }),
                  const SizedBox(width: 6),
                  _pcKeyBtn('Win+D', () {
                    bind.sessionInputKey(sessionId: sessionId, name: 'd', down: false, press: true, alt: false, ctrl: false, shift: false, command: true);
                  }),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pcKeyBtn(String label, VoidCallback onTap,
      {bool active = false, double? width, IconData? icon}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        height: 36,
        width: width,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? const Color(0xFF1A73E8) : const Color(0xFF2C2D32),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: active ? const Color(0xFF64B5F6) : Colors.white24,
            width: 0.8,
          ),
          boxShadow: const [
            BoxShadow(color: Colors.black26, blurRadius: 2, offset: Offset(0, 1)),
          ],
        ),
        child: icon != null
            ? Icon(icon, color: Colors.white, size: 16)
            : Text(
                label,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: active ? FontWeight.bold : FontWeight.w500,
                ),
              ),
      ),
    );
  }

  Widget _buildSidePanelTab() {
    return Positioned(
      right: 0,
      top: MediaQuery.of(context).size.height * 0.35,
      child: GestureDetector(
        onTap: () => setState(() => _sidePanelOpen = !_sidePanelOpen),
        child: Container(
          width: 28,
          height: 52,
          decoration: BoxDecoration(
            color: const Color(0xE6202124),
            borderRadius: const BorderRadius.horizontal(left: Radius.circular(10)),
            border: Border.all(color: Colors.white24, width: 0.6),
            boxShadow: const [
              BoxShadow(color: Colors.black45, blurRadius: 6, offset: Offset(-1, 2)),
            ],
          ),
          child: Icon(
            _sidePanelOpen ? Icons.chevron_right : Icons.chevron_left,
            color: Colors.white,
            size: 22,
          ),
        ),
      ),
    );
  }

  Widget _buildSidePanel(BuildContext context) {
    final width = MediaQuery.of(context).size.width * 0.85 > 320.0
        ? 320.0
        : MediaQuery.of(context).size.width * 0.85;
    return Positioned(
      right: 0,
      top: 0,
      bottom: 0,
      width: width,
      child: Material(
        color: const Color(0xF218191E),
        elevation: 12,
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'RustDesk',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: () => setState(() => _sidePanelOpen = false),
                  ),
                ],
              ),
              const Divider(color: Colors.white24),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFD93025),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                icon: const Icon(Icons.power_settings_new),
                label: Text(translate('Disconnect'), style: const TextStyle(fontWeight: FontWeight.bold)),
                onPressed: () => clientClose(sessionId, gFFI),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                activeColor: const Color(0xFF1A73E8),
                title: Text(translate('Lock canvas'), style: const TextStyle(color: Colors.white, fontSize: 14)),
                value: gFFI.canvasModel.locked,
                onChanged: (val) {
                  setState(() {
                    gFFI.canvasModel.setLocked(val);
                  });
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                activeColor: const Color(0xFF1A73E8),
                title: Text(translate('Send text bar'), style: const TextStyle(color: Colors.white, fontSize: 14)),
                value: _showQuickSendBar,
                onChanged: (val) {
                  setState(() {
                    _showQuickSendBar = val;
                  });
                },
              ),
              const SizedBox(height: 6),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white12,
                  foregroundColor: Colors.white,
                  alignment: Alignment.centerLeft,
                ),
                icon: Icon(
                  gFFI.ffiModel.touchMode ? Icons.touch_app : Icons.mouse,
                  size: 20,
                ),
                label: Text(gFFI.ffiModel.touchMode
                    ? translate('Touch mode')
                    : translate('Mouse mode')),
                onPressed: () {
                  setState(() {
                    gFFI.ffiModel.toggleTouchMode();
                  });
                },
              ),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white12,
                  foregroundColor: Colors.white,
                  alignment: Alignment.centerLeft,
                ),
                icon: const Icon(Icons.fit_screen, size: 20),
                label: Text(translate('Reset canvas')),
                onPressed: () {
                  gFFI.cursorModel.reset();
                  gFFI.canvasModel.resetOffset();
                },
              ),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white12,
                  foregroundColor: Colors.white,
                  alignment: Alignment.centerLeft,
                ),
                icon: const Icon(Icons.tv, size: 20),
                label: Text(translate('Display options')),
                onPressed: () {
                  showOptions(context, widget.id, gFFI.dialogManager);
                },
              ),
              if (gFFI.ffiModel.pi.displays.length > 1) ...[
                const SizedBox(height: 10),
                Text(translate('Displays'), style: const TextStyle(color: Colors.white60, fontSize: 13)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: List.generate(gFFI.ffiModel.pi.displays.length, (i) {
                    final current = gFFI.ffiModel.pi.currentDisplay;
                    final isCurrent = current == i;
                    return InkWell(
                      onTap: () {
                        bind.sessionSwitchDisplay(
                          isDesktop: isDesktop || isWebDesktop,
                          sessionId: sessionId,
                          value: Int32List.fromList([i]),
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: isCurrent ? const Color(0xFF1A73E8) : Colors.white12,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text('${translate("Display")} ${i + 1}', style: const TextStyle(color: Colors.white, fontSize: 12)),
                      ),
                    );
                  }),
                ),
              ],
              const SizedBox(height: 12),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white12,
                  foregroundColor: Colors.white,
                  alignment: Alignment.centerLeft,
                ),
                icon: const Icon(Icons.keyboard, size: 20),
                label: Text(translate('Keyboard')),
                onPressed: openKeyboard,
              ),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white12,
                  foregroundColor: Colors.white,
                  alignment: Alignment.centerLeft,
                ),
                icon: const Icon(Icons.paste, size: 20),
                label: Text(translate('Send clipboard keystrokes')),
                onPressed: () async {
                  ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
                  if (data != null && data.text != null && data.text!.isNotEmpty) {
                    bind.sessionInputString(sessionId: sessionId, value: data.text!);
                  }
                },
              ),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white12,
                  foregroundColor: Colors.white,
                  alignment: Alignment.centerLeft,
                ),
                icon: const Icon(Icons.folder_shared, size: 20),
                label: Text(translate('Transfer file')),
                onPressed: () {
                  final token = bind.sessionGetConnToken(sessionId: sessionId);
                  connect(context, widget.id, isFileTransfer: true, connToken: token);
                },
              ),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white12,
                  foregroundColor: Colors.white,
                  alignment: Alignment.centerLeft,
                ),
                icon: const Icon(Icons.chat, size: 20),
                label: Text(translate('Text chat')),
                onPressed: () => onPressedTextChat(widget.id),
              ),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white12,
                  foregroundColor: Colors.white,
                  alignment: Alignment.centerLeft,
                ),
                icon: const Icon(Icons.more_horiz, size: 20),
                label: Text(translate('More actions')),
                onPressed: () => showActions(widget.id),
              ),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white12,
                  foregroundColor: Colors.white,
                  alignment: Alignment.centerLeft,
                ),
                icon: const Icon(Icons.help_outline, size: 20),
                label: Text(translate('Gesture help')),
                onPressed: () {
                  setState(() {
                    _sidePanelOpen = false;
                    _showGestureHelp = !_showGestureHelp;
                  });
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        clientClose(sessionId, gFFI);
        return false;
      },
      child: Scaffold(
          floatingActionButtonLocation: null,
          floatingActionButton: null,
          bottomNavigationBar: Obx(() => Stack(
                alignment: Alignment.bottomCenter,
                children: [
                  gFFI.ffiModel.pi.isSet.isTrue &&
                          gFFI.ffiModel.waitForFirstImage.isTrue
                      ? (isWeb ? const Offstage() : emptyOverlay(MyTheme.canvasColor))
                      : () {
                          gFFI.ffiModel.tryShowAndroidActionsOverlay();
                          return const Offstage();
                        }(),
                  (!isWeb && gFFI.ffiModel.pi.isSet.isFalse)
                      ? emptyOverlay(MyTheme.canvasColor)
                      : const Offstage(),
                  _bottomWidget(),
                ],
              )),
          body: Obx(
            () => getRawPointerAndKeyBody(Overlay(
              initialEntries: [
                OverlayEntry(builder: (context) {
                  return Stack(
                    children: [
                      Container(
                        color: kColorCanvas,
                        child: isWebDesktop
                            ? getBodyForDesktopWithListener()
                            : SafeArea(
                                child:
                                    OrientationBuilder(builder: (ctx, orientation) {
                                  if (_currentOrientation != orientation) {
                                    Timer(const Duration(milliseconds: 200), () {
                                      gFFI.dialogManager
                                          .resetMobileActionsOverlay(ffi: gFFI);
                                      _currentOrientation = orientation;
                                      gFFI.canvasModel.updateViewStyle();
                                    });
                                  }
                                  return Container(
                                    color: MyTheme.canvasColor,
                                    child: inputModel.isPhysicalMouse.value
                                        ? getBodyForMobile()
                                        : RawTouchGestureDetectorRegion(
                                            child: getBodyForMobile(),
                                            ffi: gFFI,
                                          ),
                                  );
                                }),
                              ),
                      ),
                      if (isWeb || isMobile) ...[
                        _buildSidePanelTab(),
                        if (_sidePanelOpen) _buildSidePanel(context),
                      ],
                    ],
                  );
                })
              ],
            )),
          )),
    );
  }

  Widget getRawPointerAndKeyBody(Widget child) {
    final ffiModel = Provider.of<FfiModel>(context);
    return RawPointerMouseRegion(
      cursor: ffiModel.keyboard ? SystemMouseCursors.none : MouseCursor.defer,
      inputModel: inputModel,
      // Disable RawKeyFocusScope before the connecting is established.
      // The "Delete" key on the soft keyboard may be grabbed when inputting the password dialog.
      child: gFFI.ffiModel.pi.isSet.isTrue
          ? RawKeyFocusScope(
              focusNode: _physicalFocusNode,
              inputModel: inputModel,
              child: child)
          : child,
    );
  }

  Widget getBottomAppBar() {
    final ffiModel = Provider.of<FfiModel>(context);
    return BottomAppBar(
      elevation: 10,
      color: MyTheme.accent,
      child: Row(
        mainAxisSize: MainAxisSize.max,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Row(
              children: <Widget>[
                    IconButton(
                      color: Colors.white,
                      icon: Icon(Icons.clear),
                      onPressed: () {
                        clientClose(sessionId, gFFI);
                      },
                    ),
                    IconButton(
                      color: Colors.white,
                      icon: Icon(Icons.tv),
                      onPressed: () {
                        setState(() => _showEdit = false);
                        showOptions(context, widget.id, gFFI.dialogManager);
                      },
                    ),
                    IconButton(
                      color: _showQuickSendBar ? MyTheme.accent : Colors.white,
                      icon: const Icon(Icons.text_fields),
                      tooltip: translate('Quick send bar'),
                      onPressed: () => setState(() => _showQuickSendBar = !_showQuickSendBar),
                    ),
                    IconButton(
                      color: _sidePanelOpen ? MyTheme.accent : Colors.white,
                      icon: const Icon(Icons.menu_open),
                      tooltip: translate('Quick actions panel'),
                      onPressed: () => setState(() => _sidePanelOpen = !_sidePanelOpen),
                    ),
                  ] +
                  (isWebDesktop || ffiModel.viewOnly || !ffiModel.keyboard
                      ? []
                      : gFFI.ffiModel.isPeerAndroid
                          ? [
                              IconButton(
                                  color: Colors.white,
                                  icon: Icon(Icons.keyboard),
                                  onPressed: openKeyboard),
                              IconButton(
                                color: Colors.white,
                                icon: const Icon(Icons.build),
                                onPressed: () => gFFI.dialogManager
                                    .toggleMobileActionsOverlay(ffi: gFFI),
                              )
                            ]
                          : [
                              IconButton(
                                  color: Colors.white,
                                  icon: Icon(Icons.keyboard),
                                  onPressed: openKeyboard),
                              IconButton(
                                color: Colors.white,
                                icon: Icon(gFFI.ffiModel.touchMode
                                    ? Icons.touch_app
                                    : Icons.mouse),
                                onPressed: () => setState(
                                    () => _showGestureHelp = !_showGestureHelp),
                              ),
                            ]) +
                  (isWeb
                      ? [
                          IconButton(
                            color: Colors.white,
                            icon: const Icon(Icons.message),
                            onPressed: () => onPressedTextChat(widget.id),
                          ),
                        ]
                      : <Widget>[
                          futureBuilder(
                              future: gFFI.invokeMethod(
                                  "get_value", "KEY_IS_SUPPORT_VOICE_CALL"),
                              hasData: (isSupportVoiceCall) => IconButton(
                                    color: Colors.white,
                                    icon: isAndroid && isSupportVoiceCall
                                        ? SvgPicture.asset('assets/chat.svg',
                                            colorFilter: ColorFilter.mode(
                                                Colors.white, BlendMode.srcIn))
                                        : Icon(Icons.message),
                                    onPressed: () =>
                                        isAndroid && isSupportVoiceCall
                                            ? showChatOptions(widget.id)
                                            : onPressedTextChat(widget.id),
                                  ))
                        ]) +
                  [
                    IconButton(
                      color: Colors.white,
                      icon: Icon(Icons.more_vert),
                      onPressed: () {
                        setState(() => _showEdit = false);
                        showActions(widget.id);
                      },
                    ),
                  ]),
          Obx(() => IconButton(
                color: Colors.white,
                icon: Icon(Icons.expand_more),
                onPressed: gFFI.ffiModel.waitForFirstImage.isTrue
                    ? null
                    : () {
                        setState(() => _showBar = !_showBar);
                      },
              )),
        ],
      ),
    );
  }

  bool get showCursorPaint =>
      !gFFI.ffiModel.isPeerAndroid &&
      !gFFI.canvasModel.cursorEmbedded &&
      !gFFI.inputModel.relativeMouseMode.value;

  Widget getBodyForMobile() {
    final keyboardIsVisible = keyboardVisibilityController.isVisible;
    return Container(
        color: MyTheme.canvasColor,
        child: Stack(children: () {
          final paints = [
            ImagePaint(ffiModel: gFFI.ffiModel),
            Positioned(
              top: 10,
              right: 10,
              child: QualityMonitor(gFFI.qualityMonitorModel),
            ),
            KeyHelpTools(
                keyboardIsVisible: keyboardIsVisible,
                showGestureHelp: _showGestureHelp),
            SizedBox(
              width: 0,
              height: 0,
              child: !_showEdit
                  ? Container()
                  : TextFormField(
                      textInputAction: TextInputAction.newline,
                      autocorrect: false,
                      // Flutter 3.16.9 Android.
                      // `enableSuggestions` causes secure keyboard to be shown.
                      // https://github.com/flutter/flutter/issues/139143
                      // https://github.com/flutter/flutter/issues/146540
                      // enableSuggestions: false,
                      autofocus: true,
                      focusNode: _mobileFocusNode,
                      maxLines: null,
                      controller: _textController,
                      // trick way to make backspace work always
                      keyboardType: TextInputType.multiline,
                      // `onChanged` may be called depending on the input method if this widget is wrapped in
                      // `Focus(onKeyEvent: ..., child: ...)`
                      // For `Backspace` button in the soft keyboard:
                      // en/fr input method:
                      //      1. The button will not trigger `onKeyEvent` if the text field is not empty.
                      //      2. The button will trigger `onKeyEvent` if the text field is empty.
                      // ko/zh/ja input method: the button will trigger `onKeyEvent`
                      //                     and the event will not popup if `KeyEventResult.handled` is returned.
                      onChanged: handleSoftKeyboardInput,
                    ).workaroundFreezeLinuxMint(),
            ),
          ];
          if (showCursorPaint) {
            paints.add(CursorPaint(widget.id));
          }
          if (gFFI.ffiModel.touchMode) {
            paints.add(FloatingMouse(
              ffi: gFFI,
            ));
          } else {
            paints.add(FloatingMouseWidgets(
              ffi: gFFI,
            ));
          }
          return paints;
        }()));
  }

  Widget getBodyForDesktopWithListener() {
    final ffiModel = Provider.of<FfiModel>(context);
    var paints = <Widget>[ImagePaint(ffiModel: ffiModel)];
    if (showCursorPaint) {
      final cursor = bind.sessionGetToggleOptionSync(
          sessionId: sessionId, arg: 'show-remote-cursor');
      if (ffiModel.keyboard || cursor) {
        paints.add(CursorPaint(widget.id));
      }
    }
    return Container(
        color: MyTheme.canvasColor, child: Stack(children: paints));
  }

  List<TTextMenu> _getMobileActionMenus() {
    if (gFFI.ffiModel.pi.platform != kPeerPlatformAndroid ||
        !gFFI.ffiModel.keyboard) {
      return [];
    }
    final enabled = versionCmp(gFFI.ffiModel.pi.version, '1.2.7') >= 0;
    if (!enabled) return [];
    return [
      TTextMenu(
        child: Text(translate('Back')),
        onPressed: () => gFFI.inputModel.onMobileBack(),
      ),
      TTextMenu(
        child: Text(translate('Home')),
        onPressed: () => gFFI.inputModel.onMobileHome(),
      ),
      TTextMenu(
        child: Text(translate('Apps')),
        onPressed: () => gFFI.inputModel.onMobileApps(),
      ),
      TTextMenu(
        child: Text(translate('Volume up')),
        onPressed: () => gFFI.inputModel.onMobileVolumeUp(),
      ),
      TTextMenu(
        child: Text(translate('Volume down')),
        onPressed: () => gFFI.inputModel.onMobileVolumeDown(),
      ),
      TTextMenu(
        child: Text(translate('Power')),
        onPressed: () => gFFI.inputModel.onMobilePower(),
      ),
    ];
  }

  void showActions(String id) async {
    final size = MediaQuery.of(context).size;
    final x = 120.0;
    final y = size.height;
    final mobileActionMenus = _getMobileActionMenus();
    final menus = toolbarControls(context, id, gFFI);

    final List<PopupMenuEntry<int>> more = [
      ...mobileActionMenus
          .asMap()
          .entries
          .map((e) =>
              PopupMenuItem<int>(child: e.value.getChild(), value: e.key))
          .toList(),
      if (mobileActionMenus.isNotEmpty) PopupMenuDivider(),
      ...menus
          .asMap()
          .entries
          .map((e) => PopupMenuItem<int>(
              child: e.value.getChild(),
              value: e.key + mobileActionMenus.length))
          .toList(),
    ];
    () async {
      var index = await showMenu(
        context: context,
        position: RelativeRect.fromLTRB(x, y, x, y),
        items: more,
        elevation: 8,
      );
      if (index != null) {
        if (index < mobileActionMenus.length) {
          mobileActionMenus[index].onPressed?.call();
        } else if (index < mobileActionMenus.length + more.length) {
          menus[index - mobileActionMenus.length].onPressed?.call();
        }
      }
    }();
  }

  onPressedTextChat(String id) {
    gFFI.chatModel.changeCurrentKey(MessageKey(id, ChatModel.clientModeID));
    gFFI.chatModel.toggleChatOverlay();
  }

  showChatOptions(String id) async {
    onPressVoiceCall() => bind.sessionRequestVoiceCall(sessionId: sessionId);
    onPressEndVoiceCall() => bind.sessionCloseVoiceCall(sessionId: sessionId);

    makeTextMenu(String label, Widget icon, VoidCallback onPressed,
            {TextStyle? labelStyle}) =>
        TTextMenu(
          child: Text(translate(label), style: labelStyle),
          trailingIcon: Transform.scale(
            scale: (isDesktop || isWebDesktop) ? 0.8 : 1,
            child: IgnorePointer(
              child: IconButton(
                onPressed: null,
                icon: icon,
              ),
            ),
          ),
          onPressed: onPressed,
        );

    final isInVoice = [
      VoiceCallStatus.waitingForResponse,
      VoiceCallStatus.connected
    ].contains(gFFI.chatModel.voiceCallStatus.value);
    final menus = [
      makeTextMenu('Text chat', Icon(Icons.message, color: MyTheme.accent),
          () => onPressedTextChat(widget.id)),
      isInVoice
          ? makeTextMenu(
              'End voice call',
              SvgPicture.asset(
                'assets/call_wait.svg',
                colorFilter:
                    ColorFilter.mode(Colors.redAccent, BlendMode.srcIn),
              ),
              onPressEndVoiceCall,
              labelStyle: TextStyle(color: Colors.redAccent))
          : makeTextMenu(
              'Voice call',
              SvgPicture.asset(
                'assets/call_wait.svg',
                colorFilter: ColorFilter.mode(MyTheme.accent, BlendMode.srcIn),
              ),
              onPressVoiceCall),
    ];

    final menuItems = menus
        .asMap()
        .entries
        .map((e) => PopupMenuItem<int>(child: e.value.getChild(), value: e.key))
        .toList();
    Future.delayed(Duration.zero, () async {
      final size = MediaQuery.of(context).size;
      final x = 120.0;
      final y = size.height;
      var index = await showMenu(
        context: context,
        position: RelativeRect.fromLTRB(x, y, x, y),
        items: menuItems,
        elevation: 8,
      );
      if (index != null && index < menus.length) {
        menus[index].onPressed?.call();
      }
    });
  }

  /// aka changeTouchMode
  BottomAppBar getGestureHelp() {
    return BottomAppBar(
        child: SingleChildScrollView(
            controller: ScrollController(),
            padding: EdgeInsets.symmetric(vertical: 10),
            child: GestureHelp(
              touchMode: gFFI.ffiModel.touchMode,
              onTouchModeChange: (t) {
                gFFI.ffiModel.toggleTouchMode();
                final v = gFFI.ffiModel.touchMode ? 'Y' : 'N';
                bind.mainSetLocalOption(key: kOptionTouchMode, value: v);
              },
              virtualMouseMode: gFFI.ffiModel.virtualMouseMode,
              inputModel: gFFI.inputModel,
            )));
  }

  // * Currently mobile does not enable map mode
  // void changePhysicalKeyboardInputMode() async {
  //   var current = await bind.sessionGetKeyboardMode(id: widget.id) ?? "legacy";
  //   gFFI.dialogManager.show((setState, close) {
  //     void setMode(String? v) async {
  //       await bind.sessionSetKeyboardMode(id: widget.id, value: v ?? "");
  //       setState(() => current = v ?? '');
  //       Future.delayed(Duration(milliseconds: 300), close);
  //     }
  //
  //     return CustomAlertDialog(
  //         title: Text(translate('Physical Keyboard Input Mode')),
  //         content: Column(mainAxisSize: MainAxisSize.min, children: [
  //           getRadio('Legacy mode', 'legacy', current, setMode),
  //           getRadio('Map mode', 'map', current, setMode),
  //         ]));
  //   }, clickMaskDismiss: true);
  // }
}

class KeyHelpTools extends StatefulWidget {
  final bool keyboardIsVisible;
  final bool showGestureHelp;

  /// need to show by external request, etc [keyboardIsVisible] or [changeTouchMode]
  bool get requestShow => keyboardIsVisible || showGestureHelp;

  KeyHelpTools(
      {required this.keyboardIsVisible, required this.showGestureHelp});

  @override
  State<KeyHelpTools> createState() => _KeyHelpToolsState();
}

class _KeyHelpToolsState extends State<KeyHelpTools> {
  var _more = true;
  var _fn = false;
  var _pin = false;
  final _keyboardVisibilityController = KeyboardVisibilityController();
  final _key = GlobalKey();

  InputModel get inputModel => gFFI.inputModel;

  Widget wrap(String text, void Function() onPressed,
      {bool? active, IconData? icon}) {
    return TextButton(
        style: TextButton.styleFrom(
          minimumSize: Size(0, 0),
          padding: EdgeInsets.symmetric(vertical: 10, horizontal: 9.75),
          //adds padding inside the button
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          //limits the touch area to the button area
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(5.0),
          ),
          backgroundColor: active == true ? MyTheme.accent80 : null,
        ),
        child: icon != null
            ? Icon(icon, size: 14, color: Colors.white)
            : Text(translate(text),
                style: TextStyle(color: Colors.white, fontSize: 11)),
        onPressed: onPressed);
  }

  _updateRect() {
    RenderObject? renderObject = _key.currentContext?.findRenderObject();
    if (renderObject == null) {
      return;
    }
    if (renderObject is RenderBox) {
      final size = renderObject.size;
      Offset pos = renderObject.localToGlobal(Offset.zero);
      gFFI.cursorModel.keyHelpToolsVisibilityChanged(
          Rect.fromLTWH(pos.dx, pos.dy, size.width, size.height),
          widget.keyboardIsVisible);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasModifierOn = inputModel.ctrl ||
        inputModel.alt ||
        inputModel.shift ||
        inputModel.command;

    if (!_pin && !hasModifierOn && !widget.requestShow) {
      gFFI.cursorModel
          .keyHelpToolsVisibilityChanged(null, widget.keyboardIsVisible);
      return Offstage();
    }
    final size = MediaQuery.of(context).size;

    final pi = gFFI.ffiModel.pi;
    final isMac = pi.platform == kPeerPlatformMacOS;
    final isWin = pi.platform == kPeerPlatformWindows;
    final isLinux = pi.platform == kPeerPlatformLinux;
    final modifiers = <Widget>[
      wrap('Ctrl ', () {
        setState(() => inputModel.ctrl = !inputModel.ctrl);
      }, active: inputModel.ctrl),
      wrap(' Alt ', () {
        setState(() => inputModel.alt = !inputModel.alt);
      }, active: inputModel.alt),
      wrap('Shift', () {
        setState(() => inputModel.shift = !inputModel.shift);
      }, active: inputModel.shift),
      wrap(isMac ? ' Cmd ' : ' Win ', () {
        setState(() => inputModel.command = !inputModel.command);
      }, active: inputModel.command),
    ];
    final keys = <Widget>[
      wrap(
          ' Fn ',
          () => setState(
                () {
                  _fn = !_fn;
                  if (_fn) {
                    _more = false;
                  }
                },
              ),
          active: _fn),
      wrap(
          '',
          () => setState(
                () => _pin = !_pin,
              ),
          active: _pin,
          icon: Icons.push_pin),
      wrap(
          ' ... ',
          () => setState(
                () {
                  _more = !_more;
                  if (_more) {
                    _fn = false;
                  }
                },
              ),
          active: _more),
    ];
    final fn = <Widget>[
      SizedBox(width: 9999),
    ];
    for (var i = 1; i <= 12; ++i) {
      final name = 'F$i';
      fn.add(wrap(name, () {
        inputModel.inputKey('VK_$name');
      }));
    }
    final more = <Widget>[
      SizedBox(width: 9999),
      wrap('Esc', () {
        inputModel.inputKey('VK_ESCAPE');
      }),
      wrap('Tab', () {
        inputModel.inputKey('VK_TAB');
      }),
      wrap('Home', () {
        inputModel.inputKey('VK_HOME');
      }),
      wrap('End', () {
        inputModel.inputKey('VK_END');
      }),
      wrap('Ins', () {
        inputModel.inputKey('VK_INSERT');
      }),
      wrap('Del', () {
        inputModel.inputKey('VK_DELETE');
      }),
      wrap('PgUp', () {
        inputModel.inputKey('VK_PRIOR');
      }),
      wrap('PgDn', () {
        inputModel.inputKey('VK_NEXT');
      }),
      // to-do: support PrtScr on Mac
      if (isWin || isLinux)
        wrap('PrtScr', () {
          inputModel.inputKey('VK_SNAPSHOT');
        }),
      if (isWin || isLinux)
        wrap('ScrollLock', () {
          inputModel.inputKey('VK_SCROLL');
        }),
      if (isWin || isLinux)
        wrap('Pause', () {
          inputModel.inputKey('VK_PAUSE');
        }),
      if (isWin || isLinux)
        // Maybe it's better to call it "Menu"
        // https://en.wikipedia.org/wiki/Menu_key
        wrap('Menu', () {
          inputModel.inputKey('Apps');
        }),
      wrap('Enter', () {
        inputModel.inputKey('VK_ENTER');
      }),
      SizedBox(width: 9999),
      wrap('', () {
        inputModel.inputKey('VK_LEFT');
      }, icon: Icons.keyboard_arrow_left),
      wrap('', () {
        inputModel.inputKey('VK_UP');
      }, icon: Icons.keyboard_arrow_up),
      wrap('', () {
        inputModel.inputKey('VK_DOWN');
      }, icon: Icons.keyboard_arrow_down),
      wrap('', () {
        inputModel.inputKey('VK_RIGHT');
      }, icon: Icons.keyboard_arrow_right),
      wrap(isMac ? 'Cmd+C' : 'Ctrl+C', () {
        sendPrompt(isMac, 'VK_C');
      }),
      wrap(isMac ? 'Cmd+V' : 'Ctrl+V', () {
        sendPrompt(isMac, 'VK_V');
      }),
      wrap(isMac ? 'Cmd+S' : 'Ctrl+S', () {
        sendPrompt(isMac, 'VK_S');
      }),
    ];
    final space = size.width > 320 ? 4.0 : 2.0;
    // 500 ms is long enough for this widget to be built!
    Future.delayed(Duration(milliseconds: 500), () {
      _updateRect();
    });
    return Container(
        key: _key,
        color: Color(0xAA000000),
        padding: EdgeInsets.only(
            top: _keyboardVisibilityController.isVisible ? 24 : 4, bottom: 8),
        child: Wrap(
          spacing: space,
          runSpacing: space,
          children: <Widget>[SizedBox(width: 9999)] +
              modifiers +
              keys +
              (_fn ? fn : []) +
              (_more ? more : []),
        ));
  }
}

class ImagePaint extends StatelessWidget {
  final FfiModel ffiModel;
  ImagePaint({Key? key, required this.ffiModel}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final m = Provider.of<ImageModel>(context);
    final c = Provider.of<CanvasModel>(context);
    var s = c.scale;
    if (ffiModel.isPeerLinux) {
      final displays = ffiModel.pi.getCurDisplays();
      if (displays.isNotEmpty) {
        s = s / displays[0].scale;
      }
    }
    final adjust = c.getAdjustY();
    return CustomPaint(
      painter: ImagePainter(
          image: m.image, x: c.x / s, y: (c.y + adjust) / s, scale: s),
    );
  }
}

class CursorPaint extends StatelessWidget {
  late final String id;
  CursorPaint(this.id);

  @override
  Widget build(BuildContext context) {
    final m = Provider.of<CursorModel>(context);
    final c = Provider.of<CanvasModel>(context);
    final ffiModel = Provider.of<FfiModel>(context);
    final s = c.scale;
    double hotx = m.hotx;
    double hoty = m.hoty;
    var image = m.image;
    if (image == null) {
      if (preDefaultCursor.image != null) {
        image = preDefaultCursor.image;
        hotx = preDefaultCursor.image!.width / 2;
        hoty = preDefaultCursor.image!.height / 2;
      }
    }
    if (preForbiddenCursor.image != null &&
        !ffiModel.viewOnly &&
        !ffiModel.keyboard &&
        !ShowRemoteCursorState.find(id).value) {
      image = preForbiddenCursor.image;
      hotx = preForbiddenCursor.image!.width / 2;
      hoty = preForbiddenCursor.image!.height / 2;
    }
    if (image == null) {
      return Offstage();
    }

    final minSize = 12.0;
    double mins =
        minSize / (image.width > image.height ? image.width : image.height);
    double factor = 1.0;
    if (s < mins) {
      factor = s / mins;
    }
    final s2 = s < mins ? mins : s;
    final adjust = c.getAdjustY();
    return CustomPaint(
      painter: ImagePainter(
          image: image,
          x: (m.x - hotx) * factor + c.x / s2,
          y: (m.y - hoty) * factor + (c.y + adjust) / s2,
          scale: s2),
    );
  }
}

void showOptions(
    BuildContext context, String id, OverlayDialogManager dialogManager) async {
  var displays = <Widget>[];
  final pi = gFFI.ffiModel.pi;
  final image = gFFI.ffiModel.getConnectionImageText();
  if (image != null) {
    displays.add(Padding(padding: const EdgeInsets.only(top: 8), child: image));
  }
  final privacyModeState = PrivacyModeState.find(id);
  if (pi.displays.length > 1 &&
      pi.currentDisplay != kAllDisplayValue &&
      (privacyModeState.isEmpty ||
          allowDisplaySwitchInPrivacyMode(pi, privacyModeState.value))) {
    final cur = pi.currentDisplay;
    final children = <Widget>[];
    final isDarkTheme = MyTheme.currentThemeMode() == ThemeMode.dark;
    final numColorSelected = Colors.white;
    final numColorUnselected = isDarkTheme ? Colors.grey : Colors.black87;
    // We can't use `Theme.of(context).primaryColor` here, the color is:
    // - light theme: 0xff2196f3 (Colors.blue)
    // - dark theme: 0xff212121 (the canvas color?)
    final numBgSelected =
        Theme.of(context).colorScheme.primary.withOpacity(0.6);
    for (var i = 0; i < pi.displays.length; ++i) {
      children.add(InkWell(
          onTap: () {
            if (i == cur) return;
            openMonitorInTheSameTab(i, gFFI, pi);
            gFFI.dialogManager.dismissAll();
          },
          child: Ink(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).hintColor),
                  borderRadius: BorderRadius.circular(2),
                  color: i == cur ? numBgSelected : null),
              child: Center(
                  child: Text((i + 1).toString(),
                      style: TextStyle(
                          color:
                              i == cur ? numColorSelected : numColorUnselected,
                          fontWeight: FontWeight.bold))))));
    }
    displays.add(Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          children: children,
        )));
  }
  if (displays.isNotEmpty) {
    displays.add(const Divider(color: MyTheme.border));
  }

  List<TRadioMenu<String>> viewStyleRadios =
      await toolbarViewStyle(context, id, gFFI);
  List<TRadioMenu<String>> imageQualityRadios =
      await toolbarImageQuality(context, id, gFFI);
  List<TRadioMenu<String>> codecRadios = await toolbarCodec(context, id, gFFI);
  List<TToggleMenu> cursorToggles = await toolbarCursor(context, id, gFFI);
  List<TToggleMenu> displayToggles =
      await toolbarDisplayToggle(context, id, gFFI);
  if (isMobile) {
    displayToggles.insert(
        0,
        TToggleMenu(
            child: Text(translate('Lock canvas')),
            value: gFFI.canvasModel.locked,
            onChanged: (value) => gFFI.canvasModel.setLocked(value == true)));
  }

  List<TToggleMenu> privacyModeList = [];
  if ((gFFI.ffiModel.pi.features.privacyMode && gFFI.ffiModel.keyboard) ||
      privacyModeState.isNotEmpty) {
    privacyModeList = toolbarPrivacyMode(privacyModeState, context, id, gFFI);
    if (privacyModeList.length == 1) {
      displayToggles.add(privacyModeList[0]);
    }
  }

  dialogManager.show((setState, close, context) {
    var viewStyle =
        (viewStyleRadios.isNotEmpty ? viewStyleRadios[0].groupValue : '').obs;
    var imageQuality =
        (imageQualityRadios.isNotEmpty ? imageQualityRadios[0].groupValue : '')
            .obs;
    var codec = (codecRadios.isNotEmpty ? codecRadios[0].groupValue : '').obs;
    final radios = [
      for (var e in viewStyleRadios)
        Obx(() => getRadio<String>(
            e.child,
            e.value,
            viewStyle.value,
            e.onChanged != null
                ? (v) {
                    e.onChanged?.call(v);
                    if (v != null) viewStyle.value = v;
                  }
                : null)),
      // Show custom scale controls when custom view style is selected
      Obx(() => viewStyle.value == kRemoteViewStyleCustom
          ? MobileCustomScaleControls(ffi: gFFI)
          : const SizedBox.shrink()),
      const Divider(color: MyTheme.border),
      for (var e in imageQualityRadios)
        Obx(() => getRadio<String>(
            e.child,
            e.value,
            imageQuality.value,
            e.onChanged != null
                ? (v) {
                    e.onChanged?.call(v);
                    if (v != null) imageQuality.value = v;
                  }
                : null)),
      const Divider(color: MyTheme.border),
      for (var e in codecRadios)
        Obx(() => getRadio<String>(
            e.child,
            e.value,
            codec.value,
            e.onChanged != null
                ? (v) {
                    e.onChanged?.call(v);
                    if (v != null) codec.value = v;
                  }
                : null)),
      if (codecRadios.isNotEmpty) const Divider(color: MyTheme.border),
    ];
    final rxCursorToggleValues = cursorToggles.map((e) => e.value.obs).toList();
    final cursorTogglesList = cursorToggles
        .asMap()
        .entries
        .map((e) => Obx(() => CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            value: rxCursorToggleValues[e.key].value,
            onChanged: e.value.onChanged != null
                ? (v) {
                    e.value.onChanged?.call(v);
                    if (v != null) rxCursorToggleValues[e.key].value = v;
                  }
                : null,
            title: e.value.child)))
        .toList();

    final rxToggleValues = displayToggles.map((e) => e.value.obs).toList();
    final displayTogglesList = displayToggles
        .asMap()
        .entries
        .map((e) => Obx(() => CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            value: rxToggleValues[e.key].value,
            onChanged: e.value.onChanged != null
                ? (v) {
                    e.value.onChanged?.call(v);
                    if (v != null) rxToggleValues[e.key].value = v;
                  }
                : null,
            title: e.value.child)))
        .toList();
    final toggles = [
      ...cursorTogglesList,
      if (cursorToggles.isNotEmpty) const Divider(color: MyTheme.border),
      ...displayTogglesList,
    ];

    Widget privacyModeWidget = Offstage();
    if (privacyModeList.length > 1) {
      privacyModeWidget = ListTile(
        contentPadding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        title: Text(translate('Privacy mode')),
        onTap: () => setPrivacyModeDialog(
            dialogManager, privacyModeList, privacyModeState),
      );
    }

    var popupDialogMenus = List<Widget>.empty(growable: true);
    final resolution = getResolutionMenu(gFFI, id);
    if (resolution != null) {
      popupDialogMenus.add(ListTile(
        contentPadding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        title: resolution.child,
        onTap: () {
          close();
          resolution.onPressed?.call();
        },
      ));
    }
    final virtualDisplayMenu = getVirtualDisplayMenu(gFFI, id);
    if (virtualDisplayMenu != null) {
      popupDialogMenus.add(ListTile(
        contentPadding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        title: virtualDisplayMenu.child,
        onTap: () {
          close();
          virtualDisplayMenu.onPressed?.call();
        },
      ));
    }
    if (popupDialogMenus.isNotEmpty) {
      popupDialogMenus.add(const Divider(color: MyTheme.border));
    }

    return CustomAlertDialog(
      content: Column(
          mainAxisSize: MainAxisSize.min,
          children: displays +
              radios +
              popupDialogMenus +
              toggles +
              [privacyModeWidget]),
    );
  }, clickMaskDismiss: true, backDismiss: true).then((value) {
    _disableAndroidSoftKeyboard();
  });
}

TTextMenu? getVirtualDisplayMenu(FFI ffi, String id) {
  if (!showVirtualDisplayMenu(ffi)) {
    return null;
  }
  return TTextMenu(
    child: Text(translate("Virtual display")),
    onPressed: () {
      ffi.dialogManager.show((setState, close, context) {
        final children = getVirtualDisplayMenuChildren(ffi, id, close);
        return CustomAlertDialog(
          title: Text(translate('Virtual display')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        );
      }, clickMaskDismiss: true, backDismiss: true).then((value) {
        _disableAndroidSoftKeyboard();
      });
    },
  );
}

TTextMenu? getResolutionMenu(FFI ffi, String id) {
  final ffiModel = ffi.ffiModel;
  final pi = ffiModel.pi;
  final resolutions = pi.resolutions;
  final display = pi.tryGetDisplayIfNotAllDisplay(display: pi.currentDisplay);

  final visible =
      ffiModel.keyboard && (resolutions.length > 1) && display != null;
  if (!visible) return null;

  return TTextMenu(
    child: Text(translate("Resolution")),
    onPressed: () {
      ffi.dialogManager.show((setState, close, context) {
        final children = resolutions
            .map((e) => getRadio<String>(
                  Text('${e.width}x${e.height}'),
                  '${e.width}x${e.height}',
                  '${display.width}x${display.height}',
                  (value) {
                    close();
                    bind.sessionChangeResolution(
                      sessionId: ffi.sessionId,
                      display: pi.currentDisplay,
                      width: e.width,
                      height: e.height,
                    );
                  },
                ))
            .toList();
        return CustomAlertDialog(
          title: Text(translate('Resolution')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        );
      }, clickMaskDismiss: true, backDismiss: true).then((value) {
        _disableAndroidSoftKeyboard();
      });
    },
  );
}

void sendPrompt(bool isMac, String key) {
  final old = isMac ? gFFI.inputModel.command : gFFI.inputModel.ctrl;
  if (isMac) {
    gFFI.inputModel.command = true;
  } else {
    gFFI.inputModel.ctrl = true;
  }
  gFFI.inputModel.inputKey(key);
  if (isMac) {
    gFFI.inputModel.command = old;
  } else {
    gFFI.inputModel.ctrl = old;
  }
}

class FABLocation extends FloatingActionButtonLocation {
  FloatingActionButtonLocation location;
  double offsetX;
  double offsetY;
  FABLocation(this.location, this.offsetX, this.offsetY);

  @override
  Offset getOffset(ScaffoldPrelayoutGeometry scaffoldGeometry) {
    final offset = location.getOffset(scaffoldGeometry);
    return Offset(offset.dx + offsetX, offset.dy + offsetY);
  }
}
