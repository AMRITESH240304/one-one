import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image_lib;

/// Local resize + JPEG encode for user-uploaded profile photos.
///
/// Photos are shown at most around 512 CSS px on a full-bleed collage, so
/// storing more than [maxEdge] only inflates upload time. Small sources are
/// left at their native size (never upscaled). Transparency is not preserved
/// because the app always uploads a JPEG avatar.
class ProfilePhotoOptimizer {
  static const int maxEdge = 512;
  static const int jpegQuality = 85;
  static const int pickerMaxEdge = 1280;
  static const int cropperPreviewQuality = 90;

  /// Top-level entry so [compute] can run this off the UI isolate.
  static Uint8List normalize(Uint8List sourceBytes) {
    final decoded = image_lib.decodeImage(sourceBytes);
    if (decoded == null) {
      throw StateError("Couldn't process that image.");
    }

    var working = decoded;
    if (working.width != working.height) {
      final side = math.min(working.width, working.height);
      final offsetX = ((working.width - side) / 2).floor();
      final offsetY = ((working.height - side) / 2).floor();
      working = image_lib.copyCrop(
        working,
        x: offsetX,
        y: offsetY,
        width: side,
        height: side,
      );
    }

    if (working.width > maxEdge) {
      working = image_lib.copyResize(
        working,
        width: maxEdge,
        height: maxEdge,
        interpolation: image_lib.Interpolation.cubic,
      );
    }

    return Uint8List.fromList(
      image_lib.encodeJpg(working, quality: jpegQuality),
    );
  }
}
