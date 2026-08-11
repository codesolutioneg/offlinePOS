import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/i18n/l10n.dart';

void main() {
  Widget host(Locale locale, Widget child) => MaterialApp(
        locale: locale,
        supportedLocales: kSupportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: child,
      );

  testWidgets('English locale returns the source string', (t) async {
    late String out;
    await t.pumpWidget(host(const Locale('en'),
        Builder(builder: (c) => Text(out = tr(c, 'Payment')))));
    expect(out, 'Payment');
  });

  testWidgets('Arabic locale returns the translation and lays out RTL', (t) async {
    late String out;
    late TextDirection dir;
    await t.pumpWidget(host(const Locale('ar'), Builder(builder: (c) {
      out = tr(c, 'Payment');
      dir = Directionality.of(c);
      return Text(out);
    })));
    expect(out, 'الدفع');
    // Arabic drives right-to-left layout app-wide via the localization delegates.
    expect(dir, TextDirection.rtl);
  });

  testWidgets('an untranslated string falls back to English, never a raw key', (t) async {
    late String out;
    await t.pumpWidget(host(const Locale('ar'),
        Builder(builder: (c) => Text(out = tr(c, 'Some brand-new label')))));
    expect(out, 'Some brand-new label');
  });

  test('the locale controller toggles and reports the choice', () {
    String? saved;
    final c = LocaleController(const Locale('en'), onChanged: (code) => saved = code);
    expect(c.isArabic, isFalse);
    c.toggle();
    expect(c.isArabic, isTrue);
    expect(saved, 'ar');
    c.toggle();
    expect(saved, 'en');
  });
}
