import 'package:flutter_test/flutter_test.dart';
import 'package:one_one_app/features/identity/models/app_user_profile.dart';

void main() {
  AppUserProfile profile({
    bool setupCompleted = false,
    String displayName = '',
    String? profilePhotoUrl,
  }) {
    return AppUserProfile(
      userId: 'user',
      displayName: displayName,
      authProvider: 'google',
      accountState: 'active',
      createdAt: 1,
      updatedAt: 1,
      lastSeenAt: 1,
      setupCompleted: setupCompleted,
      profilePhotoUrl: profilePhotoUrl,
    );
  }

  test('explicit completion survives reinstall', () {
    expect(
      hasCompletedProfileSetup(
        profile(setupCompleted: true),
        isLegacyProfile: false,
      ),
      isTrue,
    );
  });

  test('legacy completed profile is migrated without onboarding', () {
    expect(
      hasCompletedProfileSetup(
        profile(
          displayName: 'Asha',
          profilePhotoUrl: 'https://example.com/photo.jpg',
        ),
        isLegacyProfile: true,
      ),
      isTrue,
    );
    expect(
      hasCompletedProfileSetup(
        profile(displayName: 'Asha'),
        isLegacyProfile: true,
      ),
      isFalse,
    );
  });

  test('new partial profile cannot trigger legacy migration', () {
    expect(
      hasCompletedProfileSetup(
        profile(
          displayName: 'Google default',
          profilePhotoUrl: 'https://example.com/photo.jpg',
        ),
        isLegacyProfile: false,
      ),
      isFalse,
    );
  });
}
