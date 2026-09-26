import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Intl.defaultLocale = 'fr_FR';
  await initializeDateFormatting('fr_FR');
  LicenseRegistry.addLicense(_fontLicense);
  runApp(const MerePouleApp());
}

/// La police est sous licence OFL : son texte doit accompagner l'app.
Stream<LicenseEntry> _fontLicense() async* {
  yield LicenseEntryWithLineBreaks([
    'Noto Sans',
  ], await rootBundle.loadString('assets/fonts/OFL-NotoSans.txt'));
}
