import 'package:flutter/material.dart';

import 'site_api.dart';
import 'site_app.dart';

/// The shop's reports site, built with `flutter build web -t lib/web_reports/main.dart`
/// and served by the cloud server (cloud/src/web.ts).
void main() => runApp(SiteApp(api: SiteApi()));
