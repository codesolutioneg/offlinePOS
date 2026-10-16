import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../core/i18n/l10n.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_theme.dart';
import 'home_page.dart';
import 'login_art.dart';
import 'site_api.dart';
import 'site_widgets.dart';

export 'home_page.dart' show HomePage;

/// The shop's reports site: sign in, then the branches, the reports and, for
/// the owner, the accounts and the tills' pairing.
class SiteApp extends StatefulWidget {
  const SiteApp({super.key, required this.api});

  final SiteApi api;

  @override
  State<SiteApp> createState() => _SiteAppState();
}

class _SiteAppState extends State<SiteApp> {
  final _locale = LocaleController(const Locale('ar'));
  SiteSession? _session;
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    SiteSession? session;
    try {
      session = await widget.api.session();
    } catch (_) {
      session = null;
    }
    if (!mounted) return;
    setState(() {
      _session = session;
      _checking = false;
    });
  }

  Future<void> _logout() async {
    try {
      await widget.api.logout();
    } catch (_) {}
    if (mounted) setState(() => _session = null);
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Locale>(
        valueListenable: _locale,
        builder: (context, locale, _) => MaterialApp(
          title: 'Dishflow',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          locale: locale,
          supportedLocales: kSupportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: _checking
              ? const Scaffold(body: Center(child: CircularProgressIndicator()))
              : _session == null
                  ? LoginPage(api: widget.api, locale: _locale, onSignedIn: _refresh)
                  : HomePage(
                      key: ValueKey(_session!.user.id),
                      api: widget.api,
                      session: _session!,
                      locale: _locale,
                      onLogout: _logout,
                      onChanged: _refresh,
                    ),
        ),
      );
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.api, required this.locale, required this.onSignedIn});

  final SiteApi api;
  final LocaleController locale;
  final VoidCallback onSignedIn;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _hidden = true;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.login(_username.text.trim(), _password.text);
      widget.onSignedIn();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: LayoutBuilder(
          builder: (context, box) {
            final form = _form(context);
            if (box.maxWidth < 900) return form;
            // The picture stays on the left in either language.
            return Row(textDirection: TextDirection.ltr, children: [
              const Expanded(flex: 5, child: LoginArt()),
              Expanded(flex: 4, child: form),
            ]);
          },
        ),
      );

  Widget _form(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Stack(children: [
        Align(
          alignment: AlignmentDirectional.topEnd,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: siteLanguageButton(context, widget.locale),
          ),
        ),
        Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: AutofillGroup(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [AppColors.primaryLight, AppColors.primaryDark],
                          ),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Icon(Icons.insights, color: Colors.white, size: 30),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(tr(context, 'Reports site'),
                        style: theme.textTheme.headlineMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Text(tr(context, 'Sign in to your account'),
                        style: theme.textTheme.bodyLarge
                            ?.copyWith(color: AppColors.textSecondaryLight)),
                    const SizedBox(height: 32),
                    TextField(
                      key: const Key('login-username'),
                      controller: _username,
                      autofillHints: const [AutofillHints.username],
                      textDirection: TextDirection.ltr,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: tr(context, 'Username'),
                        prefixIcon: const Icon(Icons.person_outline),
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      key: const Key('login-password'),
                      controller: _password,
                      obscureText: _hidden,
                      autofillHints: const [AutofillHints.password],
                      decoration: InputDecoration(
                        labelText: tr(context, 'Password'),
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          icon: Icon(_hidden
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined),
                          onPressed: () => setState(() => _hidden = !_hidden),
                        ),
                      ),
                      onSubmitted: (_) => _busy ? null : _submit(),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.error.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(children: [
                          Icon(Icons.error_outline, color: theme.colorScheme.error, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(_error!,
                                key: const Key('login-error'),
                                style: TextStyle(color: theme.colorScheme.error)),
                          ),
                        ]),
                      ),
                    ],
                    const SizedBox(height: 24),
                    SizedBox(
                      height: 50,
                      child: FilledButton(
                        key: const Key('login-submit'),
                        onPressed: _busy ? null : _submit,
                        child: _busy
                            ? const SizedBox.square(
                                dimension: 22,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2.5, color: Colors.white))
                            : Text(tr(context, 'Sign in')),
                      ),
                    ),
                    const SizedBox(height: 40),
                    Text('© Dishflow',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: AppColors.textMutedLight)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
