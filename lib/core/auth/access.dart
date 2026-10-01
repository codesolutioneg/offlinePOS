import 'package:flutter/widgets.dart';

/// What a level may do with one screen or button.
enum AccessRule {
  /// Works as it always did.
  allow,

  /// Works once a manager enters their PIN.
  manager,

  /// Not offered at all: the button is gone and the screen will not open.
  hidden;

  static AccessRule parse(String? wire) => switch (wire) {
        'manager' => AccessRule.manager,
        'hidden' => AccessRule.hidden,
        _ => AccessRule.allow,
      };
}

/// The signed-in level's rules, handed to the screens that draw the buttons.
/// With no [ruleOf] everything is allowed, which is how a screen behaves in a
/// test or before anybody set a rule.
class AccessPolicy {
  const AccessPolicy({this.ruleOf, this.approve});

  final AccessRule Function(String id)? ruleOf;

  /// Asks for a manager PIN; true when one was given.
  final Future<bool> Function(BuildContext context)? approve;

  static const AccessPolicy open = AccessPolicy();

  AccessRule rule(String id) => ruleOf?.call(id) ?? AccessRule.allow;

  bool hidden(String id) => rule(id) == AccessRule.hidden;

  /// Whether [id] may run now, asking for a manager when the rule says so.
  Future<bool> allows(BuildContext context, String id) async {
    switch (rule(id)) {
      case AccessRule.allow:
        return true;
      case AccessRule.hidden:
        return false;
      case AccessRule.manager:
        return await approve?.call(context) ?? false;
    }
  }
}
