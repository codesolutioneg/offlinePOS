import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
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

  /// Rows per `GS v 0` strip in [raster]. Small enough for the receive buffer of a
  /// cheap printer: one command carrying the whole picture made those stall
  /// mid-logo and print the overflow as black streaks.
  static const int bandRows = 64;

  /// `GS v 0`: the whole picture, on this receipt, in this job, as strips of
  /// [bandRows] rows that print edge to edge.
  Uint8List raster() {
    final out = BytesBuilder();
    for (var top = 0; top < heightDots; top += bandRows) {
      final rows = heightDots - top < bandRows ? heightDots - top : bandRows;
      out
        ..add([
          0x1d, 0x76, 0x30, 0x00,
          widthBytes & 0xff, (widthBytes >> 8) & 0xff,
          rows & 0xff, (rows >> 8) & 0xff,
        ])
        ..add(Uint8List.sublistView(bits, top * widthBytes, (top + rows) * widthBytes));
    }
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

  /// At or above this a pixel is paper: a JPG's near-white background is noise,
  /// not a pale tint, and shading it would sprinkle dots over the whole slip.
  static const int paperLevel = 225;

  /// At or below this a pixel is solid ink.
  static const int inkLevel = 40;

  /// The grey of a straight RGBA pixel laid on white paper, 0 black to 255 white.
  static int paperGrey(ByteData pixels, int i) {
    final alpha = pixels.getUint8(i + 3);
    final lum = (pixels.getUint8(i) * 299 +
            pixels.getUint8(i + 1) * 587 +
            pixels.getUint8(i + 2) * 114) ~/
        1000;
    return (lum * alpha + 255 * (255 - alpha)) ~/ 255;
  }

  /// One bit per dot from straight RGBA pixels, laid on white so a transparent
  /// background is paper.
  ///
  /// Black and white stay solid; colours and greys between them are shaded with
  /// error diffusion. A plain cut turned every red or grey part of a logo into a
  /// solid black block, which is both the wrong picture and the slowest thing a
  /// thermal head can print.
  static PrinterLogo fromRgba(ByteData pixels, int width, int height) {
    // Whole bytes both ways: the row is what GS v 0 counts, the 8-dot column block
    // is what FS q counts. The edges that fall off are padding, not picture.
    final w = width - (width % 8);
    final h = height + ((8 - (height % 8)) % 8);
    final widthBytes = w ~/ 8;
    final bits = Uint8List(widthBytes * h);
    if (w == 0) return PrinterLogo(widthDots: 0, heightDots: h, bits: bits);

    final grey = Int32List(w * height);
    final solid = Uint8List(w * height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < w; x++) {
        final g = paperGrey(pixels, ((y * width) + x) * 4);
        final at = y * w + x;
        if (g >= paperLevel) {
          grey[at] = 255;
          solid[at] = 1;
        } else if (g <= inkLevel) {
          grey[at] = 0;
          solid[at] = 1;
        } else {
          grey[at] = g;
        }
      }
    }

    // Floyd–Steinberg, only among the shaded pixels: a solid one neither takes nor
    // passes on error, so the background stays clean and the edges stay sharp.
    void spread(int x, int y, int amount) {
      if (x < 0 || x >= w || y >= height) return;
      final at = y * w + x;
      if (solid[at] == 0) grey[at] += amount;
    }

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < w; x++) {
        final at = y * w + x;
        final old = grey[at];
        final ink = old < 128;
        if (ink) bits[(y * widthBytes) + (x >> 3)] |= 0x80 >> (x & 7);
        if (solid[at] == 1) continue;
        final error = old - (ink ? 0 : 255);
        spread(x + 1, y, error * 7 ~/ 16);
        spread(x - 1, y + 1, error * 3 ~/ 16);
        spread(x, y + 1, error * 5 ~/ 16);
        spread(x + 1, y + 1, error ~/ 16);
      }
    }
    return PrinterLogo(widthDots: w, heightDots: h, bits: bits);
  }
}

/// Reads an image file and turns it into printer dots, or null when it is not an
/// image, is not there, or is too small to say anything.
///
/// The empty border around the mark is cut off first, then the mark is fitted
/// inside [maxWidthDots] by [maxHeightDots], keeping its shape. [maxWidthDots] is
/// the printable width: 384 dots on 58 mm paper, 576 on 80 mm. The height cap is
/// what keeps the dots sent with every receipt to a few kilobytes: stretching a
/// square logo to the full width of 80 mm paper made it 40 KB a slip.
Future<PrinterLogo?> loadPrinterLogo(
  String path, {
  int maxWidthDots = 384,
  int maxHeightDots = 160,
}) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? source;
  ui.Image? fitted;
  try {
    final file = File(path);
    if (!await file.exists()) return null;
    buffer = await ui.ImmutableBuffer.fromUint8List(await file.readAsBytes());
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    // Finding the edges of the mark does not need a camera-sized original.
    final shrink = math.min(1.0, _workingWidth / descriptor.width);
    codec = await descriptor.instantiateCodec(
      targetWidth: math.max(1, (descriptor.width * shrink).round()),
      targetHeight: math.max(1, (descriptor.height * shrink).round()),
    );
    source = (await codec.getNextFrame()).image;
    final raw = await source.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    if (raw == null) return null;
    final box = _markBounds(raw, source.width, source.height);
    if (box == null) return null;

    final scale = math.min(
      _maxUpscale,
      math.min(maxWidthDots / box.width, maxHeightDots / box.height),
    );
    final width = math.max(8, (box.width * scale).round());
    final height = math.max(1, (box.height * scale).round());
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );
    canvas.drawImageRect(
      source,
      box,
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    final picture = recorder.endRecording();
    fitted = await picture.toImage(width, height);
    picture.dispose();
    final pixels = await fitted.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    if (pixels == null) return null;
    final logo = PrinterLogo.fromRgba(pixels, width, height);
    return logo.widthDots < 8 ? null : logo;
  } catch (_) {
    return null;
  } finally {
    fitted?.dispose();
    source?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

const int _workingWidth = 1600;

/// A small icon may be enlarged this much at most; past that it prints as blocks.
const double _maxUpscale = 4;

/// The smallest rectangle holding everything that is not paper, or null for a
/// picture that is all paper.
ui.Rect? _markBounds(ByteData pixels, int width, int height) {
  var left = width, top = height, right = -1, bottom = -1;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      if (PrinterLogo.paperGrey(pixels, ((y * width) + x) * 4) >= PrinterLogo.paperLevel) {
        continue;
      }
      if (x < left) left = x;
      if (x > right) right = x;
      if (y < top) top = y;
      if (y > bottom) bottom = y;
    }
  }
  if (right < 0) return null;
  return ui.Rect.fromLTRB(
      left.toDouble(), top.toDouble(), (right + 1).toDouble(), (bottom + 1).toDouble());
}
