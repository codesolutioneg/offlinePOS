import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/i18n/l10n.dart';
import 'site_api.dart';

Widget siteLanguageButton(BuildContext context, LocaleController locale) => TextButton(
      key: const Key('site-language'),
      onPressed: locale.toggle,
      child: Text(locale.isArabic ? 'English' : 'العربية'),
    );

/// Amounts as the till prints them, so the site and the slip read the same.
String siteMoney(double v) => v.toStringAsFixed(2);

String siteWhen(BuildContext context, DateTime? t) {
  if (t == null) return tr(context, 'Never');
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}

String roleLabel(BuildContext context, SiteRole role) => tr(context, switch (role) {
      SiteRole.owner => 'Owner',
      SiteRole.manager => 'Branch manager',
      SiteRole.accountant => 'Accountant',
    });

String capabilityLabel(BuildContext context, String capability) =>
    tr(context, switch (capability) {
      'costs' => 'Costs and margins',
      'audit' => 'Voids, cancellations and the audit trail',
      'staff' => 'Staff hours',
      'expenses' => 'Expenses',
      'backoffice' => 'Back-office reports',
      'flash' => 'Flash reports',
      _ => capability,
    });

void showSiteError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(error is SiteError ? error.message : '$error'),
    backgroundColor: Theme.of(context).colorScheme.error,
  ));
}

/// A secret the owner has to hand on (a password or a pairing code), shown
/// once with a copy button.
Future<void> showSecretDialog(
    BuildContext context, String title, String hint, String secret) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(hint),
        const SizedBox(height: 12),
        SelectableText(secret,
            key: const Key('site-secret'),
            textDirection: TextDirection.ltr,
            style: const TextStyle(fontSize: 22, fontFamily: 'monospace', fontWeight: FontWeight.bold)),
      ]),
      actions: [
        TextButton.icon(
          onPressed: () => Clipboard.setData(ClipboardData(text: secret)),
          icon: const Icon(Icons.copy),
          label: Text(tr(ctx, 'Copy')),
        ),
        FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(tr(ctx, 'Done'))),
      ],
    ),
  );
}

/// Asks for one line of text, e.g. a branch's name.
Future<String?> askText(BuildContext context, String title, String label,
    {String initial = '', String action = 'Save'}) {
  final field = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: field,
        autofocus: true,
        decoration: InputDecoration(labelText: label),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr(ctx, 'Cancel'))),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, field.text.trim()), child: Text(tr(ctx, action))),
      ],
    ),
  );
}

Future<bool> confirm(BuildContext context, String message) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr(ctx, 'Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr(ctx, 'Continue'))),
        ],
      ),
    ) ??
    false;

/// The signed-in user's own password.
Future<void> changePasswordDialog(BuildContext context, SiteApi api) async {
  final current = TextEditingController();
  final next = TextEditingController();
  final changed = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      String? error;
      var busy = false;
      return StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(tr(ctx, 'Change password')),
          content: SizedBox(
            width: 360,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: current,
                obscureText: true,
                decoration: InputDecoration(labelText: tr(ctx, 'Current password')),
              ),
              TextField(
                controller: next,
                obscureText: true,
                decoration: InputDecoration(
                    labelText: tr(ctx, 'New password'),
                    helperText: tr(ctx, 'At least 8 characters')),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(error!, style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr(ctx, 'Cancel'))),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      setLocal(() => busy = true);
                      try {
                        await api.changePassword(current.text, next.text);
                        if (ctx.mounted) Navigator.pop(ctx, true);
                      } catch (e) {
                        setLocal(() {
                          busy = false;
                          error = '$e';
                        });
                      }
                    },
              child: Text(tr(ctx, 'Save')),
            ),
          ],
        ),
      );
    },
  );
  if (changed == true && context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr(context, 'Password changed'))));
  }
}
