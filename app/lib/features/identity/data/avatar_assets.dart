import 'package:flutter/services.dart' show AssetManifest, rootBundle;

/// Which bundled preset-avatar pack an [AvatarAsset] belongs to.
enum AvatarPack {
  avatar1('assets/avatars/', 'Avatar 1'),
  avatar2('assets/avatars2/', 'Avatar 2');

  const AvatarPack(this.assetPrefix, this.label);

  /// Folder prefix (as it appears in the asset manifest) for this pack.
  final String assetPrefix;

  /// Human-readable label for grouping avatars in picker UIs.
  final String label;
}

/// A single bundled preset avatar image.
class AvatarAsset {
  const AvatarAsset({required this.assetPath, required this.pack});

  /// The bundled asset path, e.g. `assets/avatars/avatar_01.png`.
  ///
  /// This value doubles as the avatar's stable identifier: it's what gets
  /// stored on [AppUserProfile.avatarAsset] / [GroupMemberSummary.avatarAsset]
  /// and it's exactly what `Image.asset` needs to render the avatar, so
  /// rendering a preset avatar never requires a network call or a separate
  /// id-to-path lookup step.
  final String assetPath;

  /// Which preset pack this avatar belongs to.
  final AvatarPack pack;
}

/// Enumerates and validates bundled preset-avatar assets.
///
/// Preset avatars ship as bundled app assets (not Cloudinary uploads), so an
/// avatar a user picked can always render instantly with no network call.
/// This is the single source of truth for (a) which asset paths are valid
/// preset avatars and (b) listing every bundled avatar across both packs
/// without hardcoding a fixed count per folder — new images dropped into
/// `assets/avatars/` or `assets/avatars2/` (and declared in pubspec.yaml)
/// show up automatically.
class AvatarAssets {
  AvatarAssets._();

  static Future<List<AvatarAsset>>? _loadFuture;

  /// Loads every bundled preset avatar from both packs, sorted by pack then
  /// filename. Reads Flutter's generated asset manifest, so this reflects
  /// exactly what's bundled rather than a hardcoded list.
  static Future<List<AvatarAsset>> loadAll() {
    return _loadFuture ??= _load();
  }

  /// Clears the cached asset list. Intended for tests only.
  static void resetCacheForTesting() {
    _loadFuture = null;
  }

  static Future<List<AvatarAsset>> _load() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final allPaths = manifest.listAssets();

    final avatars = <AvatarAsset>[];
    for (final pack in AvatarPack.values) {
      final packPaths =
          allPaths.where((path) => path.startsWith(pack.assetPrefix)).toList()
            ..sort();
      avatars.addAll(
        packPaths.map((path) => AvatarAsset(assetPath: path, pack: pack)),
      );
    }
    return List.unmodifiable(avatars);
  }

  /// Whether [assetPath] looks like a bundled preset avatar, as opposed to a
  /// Cloudinary URL or base64 blob. Cheap and synchronous — safe to call from
  /// render code on every build.
  static bool isPresetAvatarPath(String assetPath) {
    return AvatarPack.values.any(
      (pack) => assetPath.startsWith(pack.assetPrefix),
    );
  }
}
