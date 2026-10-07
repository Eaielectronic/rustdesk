import 'dart:html' as html;
import 'dart:js' as js;
import 'package:flutter_hbb/consts.dart';

final isAndroid_ = false;
final isIOS_ = false;
final isWindows_ = false;
final isMacOS_ = false;
final isLinux_ = false;
final isWeb_ = true;
bool get isWebDesktop_ {
  try {
    final forced = js.context.callMethod('getByName', ['option:local', 'web-force-mobile']);
    if (forced == 'Y') return false;
    if (forced == 'N') return true;
  } catch (_) {}
  try {
    final width = html.window.innerWidth;
    if (width != null && width <= 800) return false;
    final ua = (html.window.navigator.userAgent).toLowerCase();
    if (ua.contains('mobile') || ua.contains('android') || ua.contains('iphone') || ua.contains('ipad')) {
      return false;
    }
    return !js.context.callMethod('isMobile');
  } catch (_) {
    try {
      final width = html.window.innerWidth;
      if (width != null && width <= 800) return false;
    } catch (_) {}
    return false;
  }
}

final isDesktop_ = false;

final _localOs = js.context.callMethod('getByName', ['local_os', '']);
final isWebOnWindows_ = _localOs == kPeerPlatformWindows;
final isWebOnLinux_ = _localOs == kPeerPlatformLinux;
final isWebOnMacOS_ = _localOs == kPeerPlatformMacOS;
