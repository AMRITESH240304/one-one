import 'package:flutter_test/flutter_test.dart';

import 'package:image/image.dart' as image_lib;

import 'package:one_one_app/one_one.dart';

void main() {
  test('large camera-like JPEGs shrink to a 512px JPEG around quality 85', () {
    final camera = _noisyImage(1920, 1080);
    final cameraJpeg = Uint8List.fromList(
      image_lib.encodeJpg(camera, quality: 95),
    );

    final square512 = image_lib.copyResize(
      image_lib.copyCrop(
        camera,
        x: 420,
        y: 0,
        width: 1080,
        height: 1080,
      ),
      width: 512,
      height: 512,
      interpolation: image_lib.Interpolation.cubic,
    );
    final previousPipeline = Uint8List.fromList(
      image_lib.encodeJpg(square512, quality: 92),
    );
    final optimized = ProfilePhotoOptimizer.normalize(cameraJpeg);
    final decoded = image_lib.decodeImage(optimized)!;

    expect(decoded.width, 512);
    expect(decoded.height, 512);
    expect(optimized.length, lessThan(cameraJpeg.length));
    expect(optimized.length, lessThan(previousPipeline.length));

    // ignore: avoid_print
    print(
      'profile photo sizes (noise): camera=${cameraJpeg.length} '
      'previous_512_q92=${previousPipeline.length} '
      'optimized_512_q85=${optimized.length} '
      'vs_camera=${(optimized.length / cameraJpeg.length * 100).toStringAsFixed(1)}% '
      'vs_previous=${(optimized.length / previousPipeline.length * 100).toStringAsFixed(1)}%',
    );
  });

  test('photo-like portraits land well under 100KB after local optimize', () {
    final camera = _photoLikeImage(2048, 1536);
    final cameraJpeg = Uint8List.fromList(
      image_lib.encodeJpg(camera, quality: 92),
    );
    final optimized = ProfilePhotoOptimizer.normalize(cameraJpeg);
    final decoded = image_lib.decodeImage(optimized)!;

    expect(decoded.width, ProfilePhotoOptimizer.maxEdge);
    expect(decoded.height, ProfilePhotoOptimizer.maxEdge);
    expect(optimized.length, lessThan(100 * 1024));
    expect(optimized.length, lessThan(cameraJpeg.length / 4));

    // ignore: avoid_print
    print(
      'profile photo sizes (photo-like 2048x1536): camera=${cameraJpeg.length} '
      'optimized_512_q85=${optimized.length} '
      'vs_camera=${(optimized.length / cameraJpeg.length * 100).toStringAsFixed(1)}%',
    );
  });

  test('small images are not upscaled', () {
    final tiny = _noisyImage(80, 80);
    final source = Uint8List.fromList(image_lib.encodeJpg(tiny, quality: 92));
    final optimized = ProfilePhotoOptimizer.normalize(source);
    final decoded = image_lib.decodeImage(optimized)!;
    expect(decoded.width, 80);
    expect(decoded.height, 80);
  });

  test('wide images keep aspect by center-cropping to a square', () {
    final wide = _noisyImage(800, 400);
    final source = Uint8List.fromList(image_lib.encodeJpg(wide, quality: 92));
    final optimized = ProfilePhotoOptimizer.normalize(source);
    final decoded = image_lib.decodeImage(optimized)!;
    expect(decoded.width, decoded.height);
    expect(decoded.width, 400);
  });
}

image_lib.Image _noisyImage(int width, int height) {
  final image = image_lib.Image(width: width, height: height);
  final rng = Random(7);
  for (var y = 0; y < height; y += 1) {
    for (var x = 0; x < width; x += 1) {
      image.setPixelRgb(
        x,
        y,
        rng.nextInt(256),
        rng.nextInt(256),
        rng.nextInt(256),
      );
    }
  }
  return image;
}

/// Smooth gradients plus a few hard-edged shapes. Compresses like a real
/// photograph, unlike the high-entropy noise fixture above.
image_lib.Image _photoLikeImage(int width, int height) {
  final image = image_lib.Image(width: width, height: height);
  for (var y = 0; y < height; y += 1) {
    for (var x = 0; x < width; x += 1) {
      final sky = (220 - (y * 80 / height)).round();
      image.setPixelRgb(x, y, sky, 170 + (x * 40 ~/ width), 210);
    }
  }
  image_lib.fillCircle(
    image,
    x: width ~/ 2,
    y: height ~/ 2,
    radius: width ~/ 6,
    color: image_lib.ColorRgb8(210, 160, 120),
  );
  image_lib.fillRect(
    image,
    x1: width ~/ 5,
    y1: (height * 0.7).round(),
    x2: (width * 0.8).round(),
    y2: height - 1,
    color: image_lib.ColorRgb8(70, 110, 60),
  );
  return image;
}
