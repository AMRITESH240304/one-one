import 'package:one_one_app/one_one.dart';

class IdentitySession {
  const IdentitySession({
    required this.user,
    required this.device,
    required this.settings,
  });

  final AppUserProfile user;
  final UserDeviceRecord device;
  final UserSettingsRecord settings;

  String get userId => user.userId;
  String get deviceId => device.deviceId;
}
