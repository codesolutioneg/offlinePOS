import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// A short green note across the top of the screen that fades out by itself.
///
/// For courtesy confirmations (such as "clocked in" on sign-in) that must not
/// sit over the button bar or hold up the snackbar queue the way a toast would:
/// it ignores taps, so the till underneath is usable the moment it appears.
void showPassingNote(OverlayState overlay, String message, {Key? key}) {
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _PassingNote(
      key: key,
      message: message,
      onDone: () {
        if (entry.mounted) entry.remove();
      },
    ),
  );
  overlay.insert(entry);
}

class _PassingNote extends StatefulWidget {
  const _PassingNote({super.key, required this.message, required this.onDone});

  final String message;
  final VoidCallback onDone;

  @override
  State<_PassingNote> createState() => _PassingNoteState();
}

class _PassingNoteState extends State<_PassingNote>
    with SingleTickerProviderStateMixin {
  static const Duration _shown = Duration(milliseconds: 2500);

  late final AnimationController _life =
      AnimationController(vsync: this, duration: _shown)
        ..forward().whenComplete(widget.onDone);

  /// Fully visible for most of its life, fading over the last fifth.
  late final Animation<double> _opacity = TweenSequence<double>([
    TweenSequenceItem(tween: ConstantTween(1), weight: 80),
    TweenSequenceItem(tween: Tween(begin: 1, end: 0), weight: 20),
  ]).animate(_life);

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Positioned(
        top: 16,
        left: 0,
        right: 0,
        child: IgnorePointer(
          child: SafeArea(
            child: Center(
              child: FadeTransition(
                opacity: _opacity,
                child: Material(
                  color: AppColors.success,
                  elevation: 6,
                  borderRadius: BorderRadius.circular(24),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.check_circle,
                          size: 20, color: Colors.white),
                      const SizedBox(width: 10),
                      Text(widget.message,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600)),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}
