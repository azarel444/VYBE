import 'dart:typed_data';
import 'dart:ui' as ui;

/// Recognizes Musicolet's specific dark music-note/play icon cover, using a
/// low-resolution image fingerprint made from a user-reported screenshot.
/// This does NOT reject generic black-and-white or minimalist album artwork.
/// A narrow template is safer than the old "flat colors = placeholder" rule.
class MusicoletPlaceholder {
  MusicoletPlaceholder._();

  // 9 x 8 luminance grid of Musicolet's default cover. No user images are
  // embedded in the distributed app, only coarse approximate luminance data.
  static const List<int> _pattern = <int>[
    33, 33, 33, 33, 33, 33, 33, 33, 33,
    33, 33, 31, 24, 21, 24, 31, 33, 33,
    33, 33, 22, 72, 78, 18, 21, 32, 33,
    33, 31, 19, 99, 143, 127, 18, 31, 33,
    33, 33, 23, 65, 64, 17, 22, 32, 33,
    33, 33, 32, 25, 22, 25, 31, 33, 33,
    33, 33, 33, 37, 35, 36, 34, 33, 33,
    33, 33, 33, 35, 35, 35, 33, 33, 33,
  ];

  static Future<bool> matches(Uint8List bytes) async {
    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await ui.instantiateImageCodec(bytes, targetWidth: 72);
      final frame = await codec.getNextFrame();
      image = frame.image;
      final w = image.width;
      final h = image.height;
      // True default art is almost exactly square. Do not classify ordinary
      // landscape/portrait music covers as this particular placeholder.
      if (w < 36 || h < 36 || (w - h).abs() > 5) return false;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return false;

      var error = 0.0;
      var chroma = 0.0;
      for (var row = 0; row < 8; row++) {
        for (var col = 0; col < 9; col++) {
          var sum = 0.0, saturation = 0.0, count = 0;
          final x0 = col * w ~/ 9;
          final x1 = (col + 1) * w ~/ 9;
          final y0 = row * h ~/ 8;
          final y1 = (row + 1) * h ~/ 8;
          for (var y = y0; y < y1; y++) {
            for (var x = x0; x < x1; x++) {
              final i = (y * w + x) * 4;
              final r = data.getUint8(i).toDouble();
              final g = data.getUint8(i + 1).toDouble();
              final b = data.getUint8(i + 2).toDouble();
              sum += .2126 * r + .7152 * g + .0722 * b;
              final hi = r > g ? (r > b ? r : b) : (g > b ? g : b);
              final lo = r < g ? (r < b ? r : b) : (g < b ? g : b);
              saturation += hi - lo;
              count++;
            }
          }
          if (count == 0) return false;
          final pixel = sum / count;
          error += (pixel - _pattern[row * 9 + col]).abs();
          chroma += saturation / count;
        }
      }
      // Match the actual branded shape AND its desaturated palette.
      return error / 72 < 19 && chroma / 72 < 22;
    } catch (_) {
      return false;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }
}
