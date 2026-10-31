import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'api.dart';
import 'l10n.dart';
import 'screens/login_screen.dart';
import 'screens/shell_screen.dart';
import 'theme.dart';
import 'widgets/dishflow_loader.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final api = OwnerApi();
  await api.loadCookie();
  runApp(OwnerApp(api: api));
}

class OwnerApp extends StatefulWidget {
  const OwnerApp({super.key, required this.api});

  final OwnerApi api;

  @override
  State<OwnerApp> createState() => _OwnerAppState();
}

class _OwnerAppState extends State<OwnerApp> {
  final _locale = LocaleController();
  OwnerSession? _session;
  var _booting = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    OwnerSession? session;
    try {
      session = await widget.api.session();
    } catch (_) {
      session = null;
    }
    if (!mounted) return;
    setState(() {
      _session = session;
      _booting = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Locale>(
      valueListenable: _locale,
      builder: (context, locale, _) => MaterialApp(
        title: 'Dishflow Owner',
        debugShowCheckedModeBanner: false,
        theme: ownerTheme(),
        locale: locale,
        supportedLocales: const [Locale('en'), Locale('ar')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: _booting
            ? const Scaffold(
                backgroundColor: AppColors.navy,
                body: DishflowLoadingBody(
                  onDark: true,
                  label: 'Dishflow',
                ),
              )
            : _session == null
                ? LoginScreen(
                    api: widget.api,
                    locale: _locale,
                    onSignedIn: _refresh,
                  )
                : ShellScreen(
                    key: ValueKey(_session!.user.id),
                    api: widget.api,
                    session: _session!,
                    locale: _locale,
                    onLogout: () => setState(() => _session = null),
                    onRefreshSession: _refresh,
                  ),
      ),
    );
  }
}
