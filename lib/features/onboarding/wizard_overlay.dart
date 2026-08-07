import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// One panel of a coach overlay.
class WizardStep {
  const WizardStep({required this.title, required this.body});

  final String title;
  final String body;
}

/// How the cashier left the wizard.
enum WizardOutcome {
  /// Read to the end. The help is still offered next time: reaching the last step is
  /// not the same as asking never to see it again, and treating it as such is how a
  /// walkthrough silently disappears for someone who wanted it.
  completed,

  /// Closed for now, by skip, by Escape, or by tapping outside.
  skipped,

  /// "Don't show this again".
  dismissedForever,
}

/// A step-by-step coach overlay drawn above a screen.
///
/// Stack it over the screen it explains. It is deliberately presentational: it is
/// handed the steps and reports how it was left, and it never touches the store, so
/// the rule about which cashier has seen what lives in one place.
class WizardOverlay extends StatefulWidget {
  const WizardOverlay({
    super.key,
    required this.steps,
    required this.onClosed,
  });

  final List<WizardStep> steps;

  /// Called once, with how the cashier left. The host removes the overlay and
  /// persists only [WizardOutcome.dismissedForever].
  final void Function(WizardOutcome) onClosed;

  @override
  State<WizardOverlay> createState() => _WizardOverlayState();
}

class _WizardOverlayState extends State<WizardOverlay> {
  int _index = 0;

  bool get _isLast => _index == widget.steps.length - 1;

  void _next() {
    if (_isLast) {
      widget.onClosed(WizardOutcome.completed);
      return;
    }
    setState(() => _index++);
  }

  void _back() {
    if (_index == 0) return;
    setState(() => _index--);
  }

  @override
  Widget build(BuildContext context) {
    // A wizard with no steps would otherwise paint a scrim with nothing in it that
    // says how to get out.
    if (widget.steps.isEmpty) return const SizedBox.shrink();

    final step = widget.steps[_index];

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            widget.onClosed(WizardOutcome.skipped),
        const SingleActivator(LogicalKeyboardKey.arrowRight): _next,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): _back,
      },
      child: Focus(
        autofocus: true,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Help that traps a cashier with a queue at the counter is worse than no
            // help, so the way out is everywhere: outside, Escape, or Skip.
            GestureDetector(
              key: const Key('wizard-barrier'),
              behavior: HitTestBehavior.opaque,
              onTap: () => widget.onClosed(WizardOutcome.skipped),
              child: const ColoredBox(color: Color(0x99000000)),
            ),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Card(
                  margin: const EdgeInsets.all(16),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                '${_index + 1} of ${widget.steps.length}',
                                key: const Key('wizard-progress'),
                                style: const TextStyle(color: Colors.black54),
                              ),
                              const Spacer(),
                              IconButton(
                                key: const Key('wizard-skip'),
                                tooltip: 'Skip',
                                icon: const Icon(Icons.close),
                                onPressed: () =>
                                    widget.onClosed(WizardOutcome.skipped),
                              ),
                            ],
                          ),
                          Text(
                            step.title,
                            key: const Key('wizard-title'),
                            style: const TextStyle(
                                fontSize: 20, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          Text(step.body, key: const Key('wizard-body')),
                          const SizedBox(height: 16),
                          // Wrapped rather than a Row: the "don't show" control must
                          // stay visible on a narrow till instead of being clipped
                          // off the edge, which would leave no way to turn help off.
                          Wrap(
                            alignment: WrapAlignment.end,
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              TextButton(
                                key: const Key('wizard-never'),
                                onPressed: () =>
                                    widget.onClosed(WizardOutcome.dismissedForever),
                                child: const Text("Don't show this again"),
                              ),
                              TextButton(
                                key: const Key('wizard-back'),
                                onPressed: _index == 0 ? null : _back,
                                child: const Text('Back'),
                              ),
                              FilledButton(
                                key: const Key('wizard-next'),
                                onPressed: _next,
                                child: Text(_isLast ? 'Done' : 'Next'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
