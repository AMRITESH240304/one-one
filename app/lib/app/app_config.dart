class AppConfig {
  static const String apiBaseUrl = String.fromEnvironment(
    'ONE_ONE_API_BASE_URL',
    defaultValue: 'https://one-one-xw00.onrender.com',
  );

  static const String firebaseDatabaseUrl = String.fromEnvironment(
    'ONE_ONE_FIREBASE_DATABASE_URL',
    defaultValue:
        'https://oneone-3adb5-default-rtdb.asia-southeast1.firebasedatabase.app',
  );

  static const String cloudinaryCloudName = String.fromEnvironment(
    'ONE_ONE_CLOUDINARY_CLOUD_NAME',
    defaultValue: 'dfmdfwxlu',
  );

  static const String cloudinaryUploadPreset = String.fromEnvironment(
    'ONE_ONE_CLOUDINARY_UPLOAD_PRESET',
    defaultValue: 'one-one',
  );

  static const String cloudinaryProfileFolder = 'one_one/profile_photos';

  // RevenueCat — test/sandbox key for closed testing.
  // Swap to the production public API key before release to Google Play.
  // The entitlement ID ('Eleven Pro') and package identifiers remain
  // identical across sandbox and production.
  static const String revenueCatAppleApiKey = String.fromEnvironment(
    'REVENUECAT_APPLE_API_KEY',
    defaultValue: 'test_xyMARSpeunlaQbPftjTriypqInZ',
  );

  static const String revenueCatGoogleApiKey = String.fromEnvironment(
    'REVENUECAT_GOOGLE_API_KEY',
    defaultValue: 'test_xyMARSpeunlaQbPftjTriypqInZ',
  );

  /// The RevenueCat entitlement all "isPro" checks key off — never a specific
  /// product ID, so products can be swapped/added without code changes.
  static const String proEntitlementId = 'Eleven Pro';

  /// Support inbox for Eleven Pro beta feedback and billing questions.
  static const String teamElevenContactEmail = 'hello@oneone.app';
}
