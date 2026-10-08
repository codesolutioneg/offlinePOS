import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../core/i18n/l10n.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_theme.dart';
import '../domain/order.dart';
import 'branches_page.dart';
import 'login_art.dart';
import 'reports_page.dart';
import 'site_api.dart';
import 'site_widgets.dart';
import 'users_page.dart';

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

Widget _languageButton(BuildContext context, LocaleController locale) => TextButton(
      key: const Key('site-language'),
      onPressed: locale.toggle,
      child: Text(locale.isArabic ? 'English' : 'العربية'),
    );

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
            child: _languageButton(context, widget.locale),
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

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.api,
    required this.session,
    required this.locale,
    required this.onLogout,
    required this.onChanged,
  });

  final SiteApi api;
  final SiteSession session;
  final LocaleController locale;
  final VoidCallback onLogout;

  /// The session may have changed (a branch added or renamed): read it again.
  final VoidCallback onChanged;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<SiteBranch>? _branches;
  Map<String, ({int count, double total})> _today = {};
  Object? _error;

  SiteUser get _user => widget.session.user;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final now = DateTime.now();
      final branches = await widget.api.branches();
      final rows = await widget.api.records(['order'],
          from: DateTime(now.year, now.month, now.day));
      final today = <String, ({int count, double total})>{};
      for (final r in rows) {
        final order = Order.fromMap(r.payload.cast<String, dynamic>());
        if (order.state != OrderState.paid && order.state != OrderState.synced) continue;
        final was = today[r.branchId] ?? (count: 0, total: 0.0);
        today[r.branchId] = (count: was.count + 1, total: was.total + order.total);
      }
      if (!mounted) return;
      setState(() {
        _branches = branches;
        _today = today;
        _error = null;
      });
    } catch (e) {
      if (e is SiteError && e.signedOut) return widget.onLogout();
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _open(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    widget.onChanged();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final branches = _branches;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.session.shopName),
        actions: [
          _languageButton(context, widget.locale),
          PopupMenuButton<String>(
            key: const Key('site-account'),
            tooltip: _user.displayName,
            icon: const Icon(Icons.account_circle),
            onSelected: (v) {
              if (v == 'password') changePasswordDialog(context, widget.api);
              if (v == 'logout') widget.onLogout();
            },
            itemBuilder: (ctx) => [
              PopupMenuItem(
                enabled: false,
                child: Text('${_user.displayName} · ${roleLabel(ctx, _user.role)}'),
              ),
              PopupMenuItem(value: 'password', child: Text(tr(ctx, 'Change password'))),
              PopupMenuItem(
                  key: const Key('site-logout'), value: 'logout', child: Text(tr(ctx, 'Sign out'))),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Wrap(spacing: 12, runSpacing: 12, children: [
              _tile(context, const Key('home-reports'), Icons.bar_chart, tr(context, 'Reports'),
                  () => _open(ReportsPage(api: widget.api, session: widget.session))),
              _tile(context, const Key('home-branches'), Icons.store, tr(context, 'Branches and tills'),
                  () => _open(BranchesPage(api: widget.api, canManage: _user.isOwner))),
              if (_user.isOwner)
                _tile(context, const Key('home-users'), Icons.manage_accounts,
                    tr(context, 'Users and permissions'),
                    () => _open(UsersPage(api: widget.api, me: _user))),
            ]),
            const SizedBox(height: 24),
            Text(tr(context, 'Today'), style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            if (_error != null)
              Text('$_error', style: TextStyle(color: Theme.of(context).colorScheme.error))
            else if (branches == null)
              const Center(child: CircularProgressIndicator())
            else if (branches.isEmpty)
              Text(tr(context, 'No branches yet'))
            else
              for (final b in branches) _branchCard(context, b),
          ],
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, Key key, IconData icon, String label, VoidCallback onTap) =>
      SizedBox(
        width: 220,
        height: 110,
        child: Card(
          child: InkWell(
            key: key,
            onTap: onTap,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, size: 36, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 8),
              Text(label, style: Theme.of(context).textTheme.titleMedium),
            ]),
          ),
        ),
      );

  Widget _branchCard(BuildContext context, SiteBranch b) {
    final today = _today[b.id];
    final lastSync = b.devices
        .map((d) => d.lastSyncAt)
        .whereType<DateTime>()
        .fold<DateTime?>(null, (a, t) => a == null || t.isAfter(a) ? t : a);
    return Card(
      child: ListTile(
        leading: const Icon(Icons.storefront),
        title: Text(b.name),
        subtitle: Text([
          '${tr(context, 'Tills')}: ${b.devices.length}',
          '${tr(context, 'Last sync')}: ${siteWhen(context, lastSync)}',
        ].join('  ·  ')),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(siteMoney(today?.total ?? 0),
                style: Theme.of(context).textTheme.titleMedium,
                textDirection: TextDirection.ltr),
            Text('${today?.count ?? 0} ${tr(context, 'orders')}'),
          ],
        ),
      ),
    );
  }
}
