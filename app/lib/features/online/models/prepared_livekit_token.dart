import 'livekit_token_response.dart';

/// A LiveKit token that was fetched ahead of time (prefetched) together with
/// the app-level session identifiers used to request it.
///
/// The JWT itself only binds `identity` + `room` (not `serviceSessionId` /
/// `livekitSessionId`), so the same token can be reused for the real
/// go-online attempt as long as it has not expired. Reusing the session ids
/// keeps the backend's `livekitTokenIssuances` record consistent with the
/// `appServiceSessions` / `livekitSessions` rows the client writes on accept.
class PreparedLiveKitToken {
  const PreparedLiveKitToken({
    required this.response,
    required this.serviceSessionId,
    required this.livekitSessionId,
  });

  final LiveKitTokenResponse response;
  final String serviceSessionId;
  final String livekitSessionId;

  /// Tokens are valid for an hour. Treat anything with less than [safetySeconds]
  /// left as unusable so we never hand out a token that expires mid-connect.
  static const int safetySeconds = 30;

  bool isUsableAt(int nowSeconds) => response.expiresAt > nowSeconds + safetySeconds;
}
