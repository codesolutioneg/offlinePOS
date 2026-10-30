import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../api.dart';
import '../l10n.dart';
import '../theme.dart';
import '../widgets/dishflow_brand.dart';
import '../widgets/dishflow_loader.dart';

/// Navy hero + light sign-in sheet — first preferred layout, with the till's clear mark.
class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.api,
    required this.locale,
    required this.onSignedIn,
  });

  final OwnerApi api;
  final LocaleController locale;
  final VoidCallback onSignedIn;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with TickerProviderStateMixin {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  var _busy = false;
  var _hidden = true;
  String? _error;

  late final AnimationController _page;
  late final AnimationController _orbit;
  late final Animation<double> _heroFade;
  late final Animation<double> _heroLift;
  late final Animation<double> _sheetFade;
  late final Animation<Offset> _sheetSlide;

  @override
  void initState() {
    super.initState();
    _page = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..forward();
    _orbit = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 14),
    )..repeat();
    _heroFade = CurvedAnimation(
      parent: _page,
      curve: const Interval(0, 0.45, curve: Curves.easeOut),
    );
    _heroLift = CurvedAnimation(
      parent: _page,
      curve: const Interval(0, 0.55, curve: Curves.easeOutCubic),
    );
    _sheetFade = CurvedAnimation(
      parent: _page,
      curve: const Interval(0.32, 0.85, curve: Curves.easeOut),
    );
    _sheetSlide = Tween<Offset>(
      begin: const Offset(0, 0.1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _page,
      curve: const Interval(0.32, 1, curve: Curves.easeOutCubic),
    ));
  }

  @override
  void dispose() {
    _page.dispose();
    _orbit.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.login(_user.text, _pass.text);
      widget.onSignedIn();
    } catch (e) {
      if (mounted) {
        setState(() => _error = '$e');
        HapticFeedback.heavyImpact();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final compact = keyboard > 0;
    final arabic = widget.locale.isArabic;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: AppColors.navy,
        resizeToAvoidBottomInset: true,
        body: Stack(
          fit: StackFit.expand,
          children: [
            AnimatedBuilder(
              animation: _orbit,
              builder: (_, __) => _HeroBackdrop(t: _orbit.value),
            ),
            SafeArea(
              bottom: false,
              child: Column(
                children: [
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: Padding(
                      padding:
                          const EdgeInsetsDirectional.only(top: 4, end: 12),
                      child: TextButton(
                        onPressed: () {
                          widget.locale.toggle();
                          setState(() {});
                        },
                        style: TextButton.styleFrom(
                          foregroundColor:
                              Colors.white.withValues(alpha: 0.92),
                        ),
                        child: Text(
                          arabic ? 'English' : 'العربية',
                          style: GoogleFonts.cairo(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Fixed (non-Expanded) hero so the keyboard cannot squeeze
                  // Spacer/Expanded into a yellow bottom-overflow stripe.
                  FadeTransition(
                    opacity: _heroFade,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.05),
                        end: Offset.zero,
                      ).animate(_heroLift),
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          28,
                          compact ? 0 : 4,
                          28,
                          compact ? 8 : 16,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            DishflowBrandMark(
                              height: compact ? 44 : 58,
                              showSubtitle: true,
                              onDark: true,
                            ),
                            SizedBox(height: compact ? 10 : 28),
                            if (!compact) ...[
                              Text(
                                'OWNER',
                                style: GoogleFonts.cairo(
                                  color: AppColors.skyLight,
                                  letterSpacing: 4,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 8),
                            ],
                            Text(
                              tr(context, 'Sign in to your account'),
                              style: GoogleFonts.cairo(
                                color: Colors.white,
                                fontSize: compact ? 18 : 24,
                                fontWeight: FontWeight.w700,
                                height: 1.25,
                              ),
                            ),
                            if (!compact) ...[
                              const SizedBox(height: 8),
                              Text(
                                arabic
                                    ? 'تقارير المبيعات والتكلفة والطلبات — في أي وقت.'
                                    : 'Sales, costs, and open orders — anywhere.',
                                style: GoogleFonts.cairo(
                                  color:
                                      Colors.white.withValues(alpha: 0.55),
                                  fontSize: 14,
                                  height: 1.45,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: FadeTransition(
                      opacity: _sheetFade,
                      child: SlideTransition(
                        position: _sheetSlide,
                        child: _SignInSheet(
                          bottomInset: bottom,
                          user: _user,
                          pass: _pass,
                          hidden: _hidden,
                          busy: _busy,
                          error: _error,
                          onToggleHidden: () =>
                              setState(() => _hidden = !_hidden),
                          onSubmit: _busy ? null : _submit,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroBackdrop extends StatelessWidget {
  const _HeroBackdrop({required this.t});
  final double t;

  @override
  Widget build(BuildContext context) {
    final angle = t * math.pi * 2;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF152233),
            Color(0xFF1B2838),
            Color(0xFF0F1A26),
            Color(0xFF163247),
          ],
          stops: [0, 0.35, 0.7, 1],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: -120 + 20 * math.sin(angle),
            right: -80 + 30 * math.cos(angle),
            child: _Glow(
              size: 340,
              color: AppColors.sky.withValues(alpha: 0.22),
            ),
          ),
          Positioned(
            bottom: 160 + 16 * math.cos(angle),
            left: -100 + 24 * math.sin(angle),
            child: _Glow(
              size: 280,
              color: AppColors.skyDark.withValues(alpha: 0.16),
            ),
          ),
        ],
      ),
    );
  }
}

class _Glow extends StatelessWidget {
  const _Glow({required this.size, required this.color});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
      ),
    );
  }
}

class _SignInSheet extends StatelessWidget {
  const _SignInSheet({
    required this.bottomInset,
    required this.user,
    required this.pass,
    required this.hidden,
    required this.busy,
    required this.error,
    required this.onToggleHidden,
    required this.onSubmit,
  });

  final double bottomInset;
  final TextEditingController user;
  final TextEditingController pass;
  final bool hidden;
  final bool busy;
  final String? error;
  final VoidCallback onToggleHidden;
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFFF7FAFC).withValues(alpha: 0.98),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(
              top: BorderSide(color: Colors.white.withValues(alpha: 0.7)),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 28,
                offset: const Offset(0, -6),
              ),
            ],
          ),
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(24, 16, 24, 18 + bottomInset),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.border,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  tr(context, 'Username'),
                  style: GoogleFonts.cairo(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: AppColors.navy,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: user,
                  textDirection: TextDirection.ltr,
                  textInputAction: TextInputAction.next,
                  // Empty hints opt the field out of Android Autofill's
                  // yellow highlight overlay.
                  autofillHints: const [],
                  enableSuggestions: false,
                  autocorrect: false,
                  cursorColor: AppColors.skyDark,
                  style: GoogleFonts.cairo(fontWeight: FontWeight.w500),
                  decoration: _field(
                    hint: tr(context, 'Enter username'),
                    icon: Icons.person_outline_rounded,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  tr(context, 'Password'),
                  style: GoogleFonts.cairo(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: AppColors.navy,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: pass,
                  obscureText: hidden,
                  autofillHints: const [],
                  enableSuggestions: false,
                  autocorrect: false,
                  cursorColor: AppColors.skyDark,
                  onSubmitted: (_) => onSubmit?.call(),
                  style: GoogleFonts.cairo(fontWeight: FontWeight.w500),
                  decoration: _field(
                    hint: tr(context, 'Enter password'),
                    icon: Icons.lock_outline_rounded,
                    suffix: IconButton(
                      onPressed: onToggleHidden,
                      splashColor: Colors.transparent,
                      highlightColor: Colors.transparent,
                      icon: Icon(
                        hidden
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        color: AppColors.muted,
                      ),
                    ),
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 14),
                  Text(
                    error!,
                    style: GoogleFonts.cairo(
                      color: AppColors.danger,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 22),
                SizedBox(
                  height: 54,
                  child: FilledButton(
                    onPressed: onSubmit,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.skyDark,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: busy
                        ? SizedBox(
                            width: 40,
                            height: 40,
                            child: DishflowLoader(size: 28),
                          )
                        : Text(
                            tr(context, 'Sign in'),
                            style: GoogleFonts.cairo(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '© Dishflow Restaurant POS',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.cairo(
                    color: AppColors.muted.withValues(alpha: 0.85),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _field({
    required String hint,
    required IconData icon,
    Widget? suffix,
  }) {
    return InputDecoration(
      hintText: hint,
      hintStyle: GoogleFonts.cairo(
        color: AppColors.muted.withValues(alpha: 0.55),
      ),
      prefixIcon: Icon(icon, color: AppColors.muted),
      suffixIcon: suffix,
      filled: true,
      fillColor: Colors.white,
      hoverColor: Colors.transparent,
      focusColor: Colors.transparent,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.skyDark, width: 1.6),
      ),
    );
  }
}
