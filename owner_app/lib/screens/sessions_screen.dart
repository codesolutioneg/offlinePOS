import 'package:flutter/material.dart';

import '../sessions.dart';
import '../widgets/session_status.dart';

class SessionsScreen extends StatelessWidget {
  const SessionsScreen({
    super.key,
    required this.sessions,
    required this.arabic,
    this.embedded = false,
  });

  final List<OwnerSessionInfo> sessions;
  final bool arabic;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final body = ListView(
      padding: EdgeInsets.fromLTRB(20, embedded ? 8 : 12, 20, 28),
      children: [
        SessionStatusSummary(sessions: sessions, arabic: arabic),
        const SizedBox(height: 14),
        SessionStatusList(sessions: sessions, arabic: arabic),
      ],
    );
    if (embedded) return body;
    return Scaffold(
      appBar: AppBar(
        title: Text(arabic ? 'حالة الجلسات' : 'Session status'),
      ),
      body: body,
    );
  }
}
