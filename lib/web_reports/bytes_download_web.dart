import 'dart:html' as html;
import 'dart:typed_data';

/// Browser download for binary exports (PDF / Excel).
void downloadBytes(String filename, List<int> bytes, String mime) {
  final blob = html.Blob([Uint8List.fromList(bytes)], mime);
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..setAttribute('download', filename)
    ..click();
  html.Url.revokeObjectUrl(url);
}
