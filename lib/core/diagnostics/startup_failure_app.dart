import 'package:flutter/material.dart';

import '../db/db_key.dart';

/// What to tell the person standing at the till, in the two languages a shop here
/// runs in.
///
/// Nobody can act on `SqliteException(26)`, so the headline is the instruction and
/// the technical text is demoted to a footnote for whoever is called. The [code] is
/// there to be read down a phone.
class StartupFailure {
  const StartupFailure(this.code, this.english, this.arabic);

  final String code;
  final String english;
  final String arabic;

  static StartupFailure of(Object error) {
    if (error is MissingDatabaseKey) return _keyGone;

    final text = error.toString().toLowerCase();
    // SQLCipher's answer to a key that does not fit the file it was handed.
    if (text.contains('not a database') || text.contains('file is encrypted')) {
      return _unreadable;
    }
    if (text.contains('locked') || text.contains('busy')) return _busy;
    return _unknown;
  }

  static const _keyGone = StartupFailure(
    'E-KEY',
    'Windows has not given this till its security key, so its saved sales cannot '
        'be opened. Nothing has been deleted.\n\n'
        'Restart the computer and open the till again. If it still will not open, '
        'call support and do not reinstall the app.',
    'لم يمنح ويندوز نقطة البيع مفتاح الأمان الخاص بها، لذلك لا يمكن فتح المبيعات '
        'المحفوظة. لم يُحذف أي شيء.\n\n'
        'أعد تشغيل الكمبيوتر ثم افتح البرنامج مرة أخرى. إذا لم يفتح، اتصل بالدعم '
        'الفني ولا تقم بإعادة تثبيت البرنامج.',
  );

  static const _unreadable = StartupFailure(
    'E-DATA',
    'This till cannot read its saved sales. Nothing has been deleted.\n\n'
        'Call support. Do not reinstall the app and do not delete anything: any '
        'sale that has not reached the server yet is still inside this computer.',
    'لا تستطيع نقطة البيع قراءة المبيعات المحفوظة. لم يُحذف أي شيء.\n\n'
        'اتصل بالدعم الفني. لا تقم بإعادة تثبيت البرنامج ولا تحذف أي شيء: أي '
        'فاتورة لم تصل إلى السيرفر بعد لا تزال موجودة داخل هذا الكمبيوتر.',
  );

  static const _busy = StartupFailure(
    'E-BUSY',
    'This till is already open on this computer, or it did not close properly '
        'last time.\n\n'
        'Restart the computer, then open the till again.',
    'نقطة البيع مفتوحة بالفعل على هذا الكمبيوتر، أو أنها لم تُغلق بشكل صحيح في '
        'المرة السابقة.\n\n'
        'أعد تشغيل الكمبيوتر ثم افتح البرنامج مرة أخرى.',
  );

  static const _unknown = StartupFailure(
    'E-START',
    'This till could not start. Nothing has been deleted.\n\n'
        'Restart the computer, then open the till again. If it still will not '
        'open, call support.',
    'لم تتمكن نقطة البيع من البدء. لم يُحذف أي شيء.\n\n'
        'أعد تشغيل الكمبيوتر ثم افتح البرنامج مرة أخرى. إذا لم يفتح، اتصل بالدعم '
        'الفني.',
  );
}

/// Shown when the till could not be opened at all.
///
/// Built from nothing but Flutter: no theme, no localisation delegate and no
/// store, because any of those may be the thing that just failed. Both languages
/// are on screen at once for the same reason — choosing one needs a saved setting,
/// and the setting lives in the database that would not open.
class StartupFailureApp extends StatelessWidget {
  const StartupFailureApp({
    super.key,
    required this.error,
    required this.logPath,
    this.reportPath,
  });

  final Object error;

  /// The full log, for whoever is called.
  final String logPath;

  /// Where the report was copied for the operator to send, when it could be.
  final String? reportPath;

  @override
  Widget build(BuildContext context) {
    final failure = StartupFailure.of(error);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF1B1B1F),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 780),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.error_outline, color: Color(0xFFFFB4A9), size: 30),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'The till could not open  ·  ${failure.code}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 28),
                    Text(failure.english, style: _instruction),
                    const SizedBox(height: 24),
                    const Divider(color: Colors.white12, height: 1),
                    const SizedBox(height: 24),
                    Directionality(
                      textDirection: TextDirection.rtl,
                      child: Text(
                        failure.arabic,
                        style: _instruction,
                        textAlign: TextAlign.right,
                      ),
                    ),
                    const SizedBox(height: 32),
                    if (reportPath != null)
                      _Note(
                        'A report has been saved for support:\n$reportPath',
                        'تم حفظ تقرير للدعم الفني في:\n$reportPath',
                      ),
                    const SizedBox(height: 20),
                    // Last, smallest, and never the headline: it is for the person
                    // who gets called, not the person standing at the counter.
                    SelectableText(
                      'For support · $error\nFull log · $logPath',
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 12,
                        fontFamily: 'monospace',
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static const _instruction =
      TextStyle(color: Colors.white, fontSize: 17, height: 1.55);
}

class _Note extends StatelessWidget {
  const _Note(this.english, this.arabic);

  final String english;
  final String arabic;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A30),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(english, style: _note),
          const SizedBox(height: 10),
          Directionality(
            textDirection: TextDirection.rtl,
            child: Text(arabic, style: _note, textAlign: TextAlign.right),
          ),
        ],
      ),
    );
  }

  static const _note = TextStyle(color: Colors.white70, fontSize: 13, height: 1.5);
}
