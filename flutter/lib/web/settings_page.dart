import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/pages/desktop_setting_page.dart';
import 'package:flutter_hbb/mobile/pages/settings_page.dart';

class WebSettingsPage extends StatelessWidget {
  const WebSettingsPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return _buildSettingsButton(context);
  }

  Widget _buildSettingsButton(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.more_vert),
      onPressed: () {
        final isCompact = isMobile || !isWebDesktop || MediaQuery.of(context).size.width < 700;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (BuildContext context) => isCompact
                ? Scaffold(
                    appBar: AppBar(title: Text(translate('Settings'))),
                    body: SettingsPage(),
                  )
                : DesktopSettingPage(initialTabkey: SettingsTabKey.general),
          ),
        );
      },
    );
  }
}
