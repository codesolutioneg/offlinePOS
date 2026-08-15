import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// The shop's mark on the receipt, done the way a thermal printer wants it.
///
/// A logo is the one picture a receipt legitimately has, and there are two ways to
/// put it on paper. The printer can keep it in its own flash and print it on command
/// (four bytes per receipt, no image data on the wire, no cost to the sale), or the
/// dots can travel with every single slip. The first is what [EscPos] would choose
/// on its own, given what that file says about never rasterising a receipt, so it is
/// the default here and the second is a fallback for a printer with no flash slot.
///
/// Dots are held row-major, most significant bit leftmost, which is what `GS v 0`
/// prints directly and what [defineNv] repacks into the column layout `FS q` wants.
class PrinterLogo {
  const PrinterLogo({
    required this.widthDots,
    required this.heightDots,
    required this.bits,
  });

  /// A multiple of 8: a row is whole bytes on both routes.
  final int widthDots;

  /// A multiple of 8: the NV route counts height in bytes of 8 vertical dots.
  final int heightDots;

  final Uint8List bits;

  int get widthBytes => widthDots ~/ 8;
  int get heightBytes => heightDots ~/ 8;

  /// `FS p n m`: print the image already sitting in the printer's flash.
  ///
  /// Four bytes, whatever the logo weighs. Static because a receipt built on a till
  /// that has never seen the picture still prints it: the printer holds it, the app
  /// only says when.
  static Uint8List printStored({int index = 1, bool doubleWidth = false, bool doubleHeight = false}) {
    var mode = 0;
    if (doubleWidth) mode |= 1;
    if (doubleHeight) mode |= 2;
    return Uint8List.fromList([0x1c, 0x70, index & 0xff, mode]);
  }

  /// `FS q`: write this image into the printer's flash under [index].
  ///
  /// Sent once, by hand, from the receipt designer. Never spooled and never on a
  /// selling path: flash has a limited number of writes, and a queued job that
  /// replayed itself for a week would eat them.
  ///
  /// [index] is the slot, and every slot below it has to be defined in the same
  /// command, because `FS q n` always defines images 1..n. So slot 1 is the only one
  /// this writes, and a shop that wants another slot says so on the printer's own
  /// tool.
  Uint8List defineNv() {
    final out = BytesBuilder()
      ..add([
        0x1c, 0x71, 0x01, // FS q 1: define image number 1
        widthBytes & 0xff, (widthBytes >> 8) & 0xff,
        heightBytes & 0xff, (heightBytes >> 8) & 0xff,
      ])
      ..add(_columns());
    return out.toBytes();
  }

  /// `GS v 0`: the whole picture, on this receipt, in this job.
  ///
  /// The fallback. Honest about its cost: a 384 by 200 logo is nearly ten kilobytes
  /// on the wire for every slip, which a busy printer feels.
  Uint8List raster() {
    final out = BytesBuilder()
      ..add([
        0x1d, 0x76, 0x30, 0x00,
        widthBytes & 0xff, (widthBytes >> 8) & 0xff,
        heightDots & 0xff, (heightDots >> 8) & 0xff,
      ])
      ..add(bits);
    return out.toBytes();
  }

  /// The dots as `FS q` wants them: one byte per 8 vertical dots, column by column
  /// from the left, top group first. The raster route reads the same picture by
  /// rows, so one of the two has to be repacked and this is the one that is written
  /// once rather than per receipt.
  Uint8List _columns() {
    final out = Uint8List(widthDots * heightBytes);
    for (var x = 0; x < widthDots; x++) {
      for (var block = 0; block < heightBytes; block++) {
        var byte = 0;
        for (var bit = 0; bit < 8; bit++) {
          final y = block * 8 + bit;
          final on = bits[(y * widthBytes) + (x >> 3)] & (0x80 >> (x & 7)) != 0;
          if (on) byte |= 0x80 >> bit;
        }
        out[(x * heightBytes) + block] = byte;
      }
    }
    return out;
  }

  /// Held on the device so the raster fallback does not need the source file again,
  /// and so the designer can say what is loaded rather than only what is switched on.
  String encode() => '$widthDots:$heightDots:${base64Encode(bits)}';

  /// Null for anything unreadable: a mangled value costs the receipt its logo, never
  /// the receipt.
  static PrinterLogo? decode(String? stored) {
    if (stored == null || stored.isEmpty) return null;
    final parts = stored.split(':');
    if (parts.length != 3) return null;
    final width = int.tryParse(parts[0]);
    final height = int.tryParse(parts[1]);
    if (width == null || height == null || width <= 0 || height <= 0) return null;
    if (width % 8 != 0 || height % 8 != 0) return null;
    try {
      final bits = base64Decode(parts[2]);
      if (bits.length != (width ~/ 8) * height) return null;
      return PrinterLogo(widthDots: width, heightDots: height, bits: bits);
    } catch (_) {
      return null;
    }
  }

  /// One bit per dot from straight RGBA pixels: a dot is inked where the pixel is
  /// both opaque enough to be there and dark enough to be ink, so a logo exported on
  /// a transparent or a white background both come out as the mark and not a block.
  static PrinterLogo fromRgba(
    ByteData pixels,
    int width,
    int height, {
    int threshold = 160,
  }) {
    // Whole bytes both ways: the row is what GS v 0 counts, the 8-dot column block
    // is what FS q counts. The edges that fall off are padding, not picture.
    final w = width - (width % 8);
    final h = height + ((8 - (height % 8)) % 8);
    final widthBytes = w ~/ 8;
    final bits = Uint8List(widthBytes * h);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < w; x++) {
        final i = ((y * width) + x) * 4;
        final alpha = pixels.getUint8(i + 3);
        if (alpha < 96) continue;
        final luminance =
            (pixels.getUint8(i) * 30 + pixels.getUint8(i + 1) * 59 + pixels.getUint8(i + 2) * 11) ~/ 100;
        if (luminance < threshold) bits[(y * widthBytes) + (x >> 3)] |= 0x80 >> (x & 7);
      }
    }
    return PrinterLogo(widthDots: w, heightDots: h, bits: bits);
  }
}

/// Reads an image file and turns it into printer dots, or null when it is not an
/// image, is not there, or is too small to say anything.
///
/// [maxWidthDots] is the printable width: 384 dots on 58 mm paper, 576 on 80 mm.
/// Anything wider is scaled down rather than cropped, because a manager picking a
/// file has no reason to know the printer's dot count.
Future<PrinterLogo?> loadPrinterLogo(
  String path, {
  int maxWidthDots = 384,
  int threshold = 160,
}) async {
  try {
    final file = File(path);
    if (!await file.exists()) return null;
    final codec = await ui.instantiateImageCodec(
      await file.readAsBytes(),
      targetWidth: maxWidthDots,
    );
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final pixels = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      if (pixels == null) return null;
      final logo = PrinterLogo.fromRgba(pixels, image.width, image.height,
          threshold: threshold);
      return logo.widthDots < 8 ? null : logo;
    } finally {
      image.dispose();
      codec.dispose();
    }
  } catch (_) {
    return null;
  }
}
