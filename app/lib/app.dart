import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'config.dart';
import 'demo/demo_data.dart';
import 'screens/account_shell.dart';
import 'screens/login_screen.dart';
import 'theme/theme.dart';

class MerePouleApp extends StatelessWidget {
  const MerePouleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: MpConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: MpTheme.light,
      darkTheme: MpTheme.dark,
      themeMode: MpConfig.themeMode,
      locale: MpConfig.locale,
      supportedLocales: const [MpConfig.locale],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Builder(
        builder: (context) => LoginScreen(
          onTailscale: () => Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (_) => AccountShell(accounts: Demo.accounts),
            ),
          ),
        ),
      ),
    );
  }
}
