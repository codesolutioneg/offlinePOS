import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// A keyboard drawn by the app, for a touch till with no physical one.
///
/// Windows does not reliably raise its own touch keyboard for a Flutter text
/// field, so a note typed at a touch screen needs one that is always there. It
/// types into [controller] at the caret, so a physical keyboard still works
/// alongside it.
class OnScreenKeyboard extends StatefulWidget {
  const OnScreenKeyboard({
    super.key,
    required this.controller,
    this.onDone,
    this.arabicFirst,
  });

  final TextEditingController controller;

  /// The Done key. Hidden when null.
  final VoidCallback? onDone;

  /// Which layout opens first. Null follows the app language.
  final bool? arabicFirst;

  static const _digits = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'];
  static const _english = [
    ['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'],
    ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'],
    ['z', 'x', 'c', 'v', 'b', 'n', 'm'],
  ];
  static const _arabic = [
    ['ض', 'ص', 'ث', 'ق', 'ف', 'غ', 'ع', 'ه', 'خ', 'ح', 'ج', 'د'],
    ['ش', 'س', 'ي', 'ب', 'ل', 'ا', 'ت', 'ن', 'م', 'ك', 'ط'],
    ['ذ', 'ئ', 'ء', 'ؤ', 'ر', 'لا', 'ى', 'ة', 'و', 'ز', 'ظ', 'أ', 'إ'],
  ];

  @override
  State<OnScreenKeyboard> createState() => _OnScreenKeyboardState();
}

class _OnScreenKeyboardState extends State<OnScreenKeyboard> {
  bool? _arabic;
  bool _shift = false;

  bool get arabic =>
      _arabic ??
      widget.arabicFirst ??
      Localizations.maybeLocaleOf(context)?.languageCode == 'ar';

  void _insert(String text) {
    final c = widget.controller;
    final value = c.value;
    final sel = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final next = value.text.replaceRange(sel.start, sel.end, text);
    c.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: sel.start + text.length),
    );
    if (_shift) setState(() => _shift = false);
  }

  void _backspace() {
    final c = widget.controller;
    final value = c.value;
    final sel = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    if (!sel.isCollapsed) {
      c.value = TextEditingValue(
        text: value.text.replaceRange(sel.start, sel.end, ''),
        selection: TextSelection.collapsed(offset: sel.start),
      );
      return;
    }
    if (sel.start == 0) return;
    // One character as the reader sees it, not one UTF-16 unit.
    final before = value.text.characters.take(
        value.text.substring(0, sel.start).characters.length - 1);
    final start = before.toString().length;
    c.value = TextEditingValue(
      text: value.text.replaceRange(start, sel.start, ''),
      selection: TextSelection.collapsed(offset: start),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = arabic ? OnScreenKeyboard._arabic : OnScreenKeyboard._english;
    String label(String k) => _shift && !arabic ? k.toUpperCase() : k;
    return Directionality(
      // Keys sit where they sit on a real keyboard, whatever the app's direction.
      textDirection: TextDirection.ltr,
      child: Container(
        key: const Key('osk'),
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: const Color(0xFFE8EBF0),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _row([
              for (final d in OnScreenKeyboard._digits) _key(d, () => _insert(d)),
              _key('⌫', _backspace, keyId: 'osk-backspace', flex: 2, dark: true),
            ]),
            for (var i = 0; i < rows.length; i++)
              _row([
                if (i == 2 && !arabic)
                  _key('⇧', () => setState(() => _shift = !_shift),
                      keyId: 'osk-shift', flex: 2, dark: !_shift, active: _shift),
                for (final k in rows[i]) _key(label(k), () => _insert(label(k))),
              ]),
            _row([
              _key(arabic ? 'EN' : 'ع', () => setState(() {
                    _arabic = !arabic;
                    _shift = false;
                  }),
                  keyId: 'osk-language', flex: 2, dark: true),
              _key(arabic ? '،' : ',', () => _insert(arabic ? '،' : ',')),
              _key(' ', () => _insert(' '), keyId: 'osk-space', flex: 6),
              _key('.', () => _insert('.')),
              _key('-', () => _insert('-')),
              if (widget.onDone != null)
                _key('✓', widget.onDone!, keyId: 'osk-done', flex: 2, primary: true),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _row(List<Widget> keys) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: keys),
      );

  Widget _key(
    String text,
    VoidCallback onTap, {
    String? keyId,
    int flex = 1,
    bool dark = false,
    bool primary = false,
    bool active = false,
  }) {
    final background = primary
        ? AppColors.primary
        : active
            ? AppColors.brandNavy
            : dark
                ? const Color(0xFFC9CED6)
                : Colors.white;
    final foreground = primary || active ? Colors.white : AppColors.brandNavy;
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Material(
          color: background,
          borderRadius: BorderRadius.circular(8),
          elevation: 1,
          child: InkWell(
            key: Key(keyId ?? 'osk-$text'),
            // A key must never take focus away from the field it types into.
            canRequestFocus: false,
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: SizedBox(
              height: 48,
              child: Center(
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: foreground,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
