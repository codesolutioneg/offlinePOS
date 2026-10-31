import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Hands [content] to the browser as a download named [fileName]. Returns the
/// name, which is all a browser lets a page say about where it went.
Future<String> writeTextExport(String fileName, String content) =>
    writeBytesExport(fileName, utf8.encode(content));

/// Hands [bytes] (e.g. a PDF) to the browser as a download named [fileName].
Future<String> writeBytesExport(String fileName, List<int> bytes) async {
  final blob = web.Blob([Uint8List.fromList(bytes).toJS].toJS);
  final url = web.URL.createObjectURL(blob);
  final link = web.HTMLAnchorElement()
    ..href = url
    ..download = fileName;
  web.document.body!.append(link);
  link.click();
  link.remove();
  web.URL.revokeObjectURL(url);
  return fileName;
}
