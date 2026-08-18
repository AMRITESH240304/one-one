/// Cloudinary delivery transforms for already-uploaded profile photos.
///
/// Uploads are locally resized to [maxStoredEdge] before they reach
/// Cloudinary. Fetch paths then ask the CDN for the smallest derivative that
/// still covers the on-screen pixel size, plus automatic format (`f_auto`)
/// so supporting devices get WebP/AVIF instead of the stored JPEG.
class CloudinaryDelivery {
  static const String uploadMarker = '/image/upload/';
  static const int maxStoredEdge = 512;
  static const int minFetchEdge = 64;

  static const List<int> sizeSteps = [
    64,
    96,
    128,
    160,
    192,
    256,
    320,
    384,
    512,
  ];

  static const List<String> _transformPrefixes = [
    'w_',
    'h_',
    'c_',
    'f_',
    'q_',
    'g_',
    'dpr_',
    'e_',
    'b_',
  ];

  /// Inserts `f_auto,q_auto,c_limit,w_N,h_N` after `/image/upload/` when the
  /// URL is a raw Cloudinary asset. Non-Cloudinary URLs and URLs that already
  /// carry transforms are returned unchanged. Query parameters (including the
  /// app's `one_one_v` cache buster) are preserved.
  static String urlFor(String url, {required int pixelSize}) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return trimmed;

    final markerIndex = trimmed.indexOf(uploadMarker);
    if (markerIndex < 0) return trimmed;

    final insertAt = markerIndex + uploadMarker.length;
    final after = trimmed.substring(insertAt);
    if (_hasTransforms(after)) return trimmed;

    final size = snapPixelSize(pixelSize);
    final transform = 'f_auto,q_auto,c_limit,w_$size,h_$size';
    return '${trimmed.substring(0, insertAt)}$transform/$after';
  }

  static int snapPixelSize(int requested) {
    final capped = requested.clamp(minFetchEdge, maxStoredEdge);
    for (final step in sizeSteps) {
      if (capped <= step) return step;
    }
    return maxStoredEdge;
  }

  static bool _hasTransforms(String afterUpload) {
    final path = afterUpload.split('?').first;
    if (path.isEmpty) return false;
    final first = path.split('/').first;
    return _transformPrefixes.any(first.startsWith);
  }
}
