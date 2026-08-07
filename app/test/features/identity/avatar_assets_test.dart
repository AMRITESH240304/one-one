import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:one_one_app/features/identity/data/avatar_assets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  int countPngsOnDisk(String folder) {
    final dir = Directory('assets/$folder');
    return dir
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.png'))
        .length;
  }

  test('enumerates every bundled avatar without hardcoding a count', () async {
    final avatars = await AvatarAssets.loadAll();

    final avatar1 = avatars.where((a) => a.pack == AvatarPack.avatar1);
    final avatar2 = avatars.where((a) => a.pack == AvatarPack.avatar2);

    expect(avatar1.length, countPngsOnDisk('avatars'));
    expect(avatar2.length, countPngsOnDisk('avatars2'));
    expect(avatars.length, avatar1.length + avatar2.length);

    // No duplicates, and every path actually points at the pack it's
    // grouped under.
    expect(avatars.map((a) => a.assetPath).toSet().length, avatars.length);
    for (final avatar in avatars) {
      expect(avatar.assetPath.startsWith(avatar.pack.assetPrefix), isTrue);
    }
  });

  test('every enumerated avatar loads from the asset bundle', () async {
    final avatars = await AvatarAssets.loadAll();
    expect(avatars, isNotEmpty);

    for (final avatar in avatars) {
      final bytes = await rootBundle.load(avatar.assetPath);
      expect(
        bytes.lengthInBytes,
        greaterThan(0),
        reason: '${avatar.assetPath} should not be empty',
      );
    }
  });

  test('isPresetAvatarPath validates preset paths only', () {
    expect(
      AvatarAssets.isPresetAvatarPath('assets/avatars/avatar_01.png'),
      isTrue,
    );
    expect(
      AvatarAssets.isPresetAvatarPath('assets/avatars2/avatar_42.png'),
      isTrue,
    );
    expect(
      AvatarAssets.isPresetAvatarPath('https://example.com/photo.jpg'),
      isFalse,
    );
    expect(AvatarAssets.isPresetAvatarPath('assets/logo.png'), isFalse);
  });
}
