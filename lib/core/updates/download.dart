import 'dart:io';

/// Bytes written so far, and the size when the sender declared one.
typedef DownloadProgress = void Function(int received, int? total);

/// Streams [response] into [to], reporting as it goes. Gives up when the
/// transfer stalls for [stall], not when it is merely long.
Future<void> saveDownload(
  HttpClientResponse response,
  File to, {
  DownloadProgress? onProgress,
  Duration stall = const Duration(seconds: 30),
}) async {
  final total = response.contentLength >= 0 ? response.contentLength : null;
  var received = 0;
  final sink = to.openWrite();
  try {
    await for (final chunk in response.timeout(stall)) {
      sink.add(chunk);
      received += chunk.length;
      onProgress?.call(received, total);
    }
    await sink.close();
  } catch (_) {
    await sink.close().catchError((_) {});
    rethrow;
  }
}
