import 'dart:convert';
import 'dart:html' as html;

/// Saves [text] as a file in the browser. A leading BOM lets Excel read Arabic.
void downloadReport(String filename, String text) {
  final blob = html.Blob([utf8.encode('\uFEFF$text')], 'text/csv;charset=utf-8');
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..setAttribute('download', filename)
    ..click();
  html.Url.revokeObjectUrl(url);
}
