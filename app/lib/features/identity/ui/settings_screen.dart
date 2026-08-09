import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/accent_theme.dart';
import '../../../core/firebase/crashlytics_service.dart';
import '../data/avatar_assets.dart';
import '../data/identity_repository.dart';
import '../models/identity_session.dart';
import 'avatar_picker_grid.dart';
import 'legal_document_screen.dart';
import 'profile_avatar.dart';
import 'profile_photo_editor.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.session,
    required this.identityRepository,
    this.groupName,
    this.onManageGroup,
  });

  final IdentitySession session;
  final IdentityRepository identityRepository;
  final String? groupName;
  final Future<bool> Function()? onManageGroup;

  /// Opens settings drifting in from the left (settings control side).
  static Future<void> open(
    BuildContext context, {
    required IdentitySession session,
    required IdentityRepository identityRepository,
    String? groupName,
    Future<bool> Function()? onManageGroup,
  }) {
    return Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        opaque: true,
        barrierColor: const Color(0xff101010),
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (context, animation, secondaryAnimation) {
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: SystemUiOverlayStyle.light,
            child: ColoredBox(
              color: const Color(0xff101010),
              child: SettingsScreen(
                session: session,
                identityRepository: identityRepository,
                groupName: groupName,
                onManageGroup: onManageGroup,
              ),
            ),
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              // From the left edge where the settings icon sits — not bottom-up.
              position: Tween<Offset>(
                begin: const Offset(-0.22, 0),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
  }

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late IdentitySession _session = widget.session;
  late String _accentColorKey = _session.settings.accentColorKey;
  late bool _hapticsEnabled = _session.settings.hapticsEnabled;
  late String _audioOutputPreference = _session.settings.audioOutputPreference;
  late String _persistedAccentColorKey = _session.settings.accentColorKey;
  late bool _persistedHapticsEnabled = _session.settings.hapticsEnabled;
  late String _persistedAudioOutputPreference =
      _session.settings.audioOutputPreference;
  bool _saving = false;
  bool _photoSaving = false;
  bool _accountActionInProgress = false;
  bool _hasUnsavedAccentPreview = false;
  /// While true, never rebuild this route from session listenable updates —
  /// parent rebuilds during the edit-profile sheet's deactivate race
  /// `_dependents.isEmpty` assertions.
  bool _profileEditorOpen = false;
  String? _message;

  Future<List<AvatarAsset>>? _avatarsFuture;

  @override
  void initState() {
    super.initState();
    _avatarsFuture = AvatarAssets.loadAll();
    final currentSession = widget.identityRepository.currentSession;
    if (currentSession != null && currentSession.userId == _session.userId) {
      _session = currentSession;
      _accentColorKey = currentSession.settings.accentColorKey;
      _hapticsEnabled = currentSession.settings.hapticsEnabled;
      _audioOutputPreference = currentSession.settings.audioOutputPreference;
      _persistedAccentColorKey = currentSession.settings.accentColorKey;
      _persistedHapticsEnabled = currentSession.settings.hapticsEnabled;
      _persistedAudioOutputPreference =
          currentSession.settings.audioOutputPreference;
    }
    try {
      widget.identityRepository.sessionListenable.addListener(
        _onRepositorySessionChanged,
      );
    } catch (_) {
      // The session listenable may be in a partially-disposed state during
      // navigation transitions. The screen still works with the session
      // captured from the constructor above.
    }
  }

  @override
  void dispose() {
    try {
      widget.identityRepository.sessionListenable.removeListener(
        _onRepositorySessionChanged,
      );
    } catch (_) {
      // Best-effort cleanup when the listenable is already torn down.
    }
    if (_hasUnsavedAccentPreview) {
      AccentThemeController.setAccentKey(_persistedAccentColorKey);
    }
    super.dispose();
  }

  void _onRepositorySessionChanged() {
    final session = widget.identityRepository.currentSession;
    if (!mounted || session == null || session.userId != _session.userId) {
      return;
    }
    // Keep data fresh without rebuilding while the edit-profile sheet (or its
    // nested photo picker) owns modal elements under this route.
    if (_profileEditorOpen) {
      _session = session;
      return;
    }
    // Defer: same-frame notify during an awaited save/pop can race Elements
    // that are mid-deactivate (_dependents.isEmpty).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _profileEditorOpen) return;
      final latest = widget.identityRepository.currentSession;
      if (latest == null || latest.userId != _session.userId) return;
      setState(() => _session = latest);
    });
  }

  bool get _hasUnsavedSettings =>
      _accentColorKey != _persistedAccentColorKey ||
      _hapticsEnabled != _persistedHapticsEnabled ||
      _audioOutputPreference != _persistedAudioOutputPreference;

  void _acceptSession(IdentitySession session) {
    _session = session;
  }

  Future<void> _changeProfilePhoto() async {
    if (_saving || _photoSaving || _profileEditorOpen) return;
    unawaited(CrashlyticsService.log('settings_photo_save_start'));
    try {
      final currentUrl = _session.user.profilePhotoUrl?.trim();
      var recropCurrent = false;
      if (currentUrl != null && currentUrl.isNotEmpty) {
        final choice = await showModalBottomSheet<String>(
          context: context,
          backgroundColor: const Color(0xff1b1b1b),
          showDragHandle: true,
          builder: (context) => SafeArea(
            child: Wrap(
              children: [
                ListTile(
                  leading: const Icon(Icons.photo_library_outlined),
                  title: const Text('Choose a new photo'),
                  onTap: () => Navigator.pop(context, 'new'),
                ),
                ListTile(
                  leading: const Icon(Icons.crop_outlined),
                  title: const Text('Re-crop current photo'),
                  onTap: () => Navigator.pop(context, 'recrop'),
                ),
              ],
            ),
          ),
        );
        if (choice == null || !mounted) return;
        recropCurrent = choice == 'recrop';
      }
      final bytes = await _openProfilePhotoEditor(
        recropCurrent: recropCurrent,
        currentUrl: currentUrl,
      );
      if (bytes == null || !mounted) return;
      setState(() {
        _photoSaving = true;
        _message = null;
      });
      final session = await widget.identityRepository.updateProfilePhoto(bytes);
      unawaited(CrashlyticsService.log('settings_photo_save_network_ok'));
      if (!mounted) return;
      // Defer setState so it doesn't run in the same microtask as any sheet
      // route disposal from the photo editor.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(CrashlyticsService.log('settings_photo_save_setState'));
        setState(() {
          _acceptSession(session);
          _message = 'Profile picture updated';
          _photoSaving = false;
        });
      });
    } catch (error, stack) {
      unawaited(
        CrashlyticsService.recordError(
          error,
          stack,
          reason: 'settings_photo_save_failed',
          feature: 'settings',
          screenName: 'settings',
        ),
      );
      if (!mounted) return;
      setState(() {
        _message = error.toString();
        _photoSaving = false;
      });
    }
  }

  Future<Uint8List?> _openProfilePhotoEditor({
    required bool recropCurrent,
    required String? currentUrl,
  }) {
    if (recropCurrent) {
      return ProfilePhotoEditor.recropNetworkPhoto(context, currentUrl!);
    }
    return ProfilePhotoEditor.pickAndCrop(context);
  }

  /// Edit Profile: display name + full avatar/photo section. Saves via a
  /// pinned floating bar so the user never has to scroll to find it.
  Future<void> _openProfileEditor() async {
    _profileEditorOpen = true;
    _EditProfileSheetResult? result;
    try {
      result = await showModalBottomSheet<_EditProfileSheetResult>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: const Color(0xff1b1b1b),
        barrierColor: Colors.black87,
        showDragHandle: true,
        // Keep the sheet alive until the reverse animation finishes so its
        // elements are not half-deactivated under a parent rebuild.
        builder: (sheetContext) {
          return _EditProfileSheet(
            session: _session,
            accentColorKey: _accentColorKey,
            avatarsFuture: _avatarsFuture,
            identityRepository: widget.identityRepository,
          );
        },
      );
    } finally {
      // Stay "open" for one more frame after the route is gone so any
      // deferred session listenable callbacks still skip setState while
      // modal dependents are clearing.
    }

    if (!mounted) {
      _profileEditorOpen = false;
      return;
    }

    // Two end-of-frame waits: (1) modal route dispose, (2) InheritedElement
    // dependent bookkeeping. Avoid `_dependents.isEmpty` races.
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(Duration.zero);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) {
      _profileEditorOpen = false;
      return;
    }

    final latest = widget.identityRepository.currentSession;
    setState(() {
      if (result?.session != null) {
        _acceptSession(result!.session!);
      } else if (latest != null && latest.userId == _session.userId) {
        _acceptSession(latest);
      }
      if (result?.message != null) {
        _message = result!.message;
      }
      _profileEditorOpen = false;
    });
  }

  void _setHapticsEnabled(bool value) {
    setState(() {
      _hapticsEnabled = value;
      _message = null;
    });
  }

  void _setAudioOutputPreference(String value) {
    setState(() {
      _audioOutputPreference = value;
      _message = null;
    });
  }

  Future<void> _saveSettings() async {
    unawaited(
      CrashlyticsService.log(
        'settings_prefs_save_start accent=$_accentColorKey',
      ),
    );
    setState(() {
      _saving = true;
      _message = null;
    });

    try {
      final session = await widget.identityRepository.updateSettings(
        accentColorKey: _accentColorKey,
        hapticsEnabled: _hapticsEnabled,
        audioOutputPreference: _audioOutputPreference,
      );
      unawaited(CrashlyticsService.log('settings_prefs_save_network_ok'));
      _persistedAccentColorKey = session.settings.accentColorKey;
      _persistedHapticsEnabled = session.settings.hapticsEnabled;
      _persistedAudioOutputPreference = session.settings.audioOutputPreference;
      _hasUnsavedAccentPreview = false;
      // Apply accent after local flags are consistent; no-op if already set.
      AccentThemeController.setAccentKey(session.settings.accentColorKey);
      unawaited(CrashlyticsService.log('settings_prefs_accent_applied'));
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(CrashlyticsService.log('settings_prefs_save_setState'));
        setState(() {
          _acceptSession(session);
          _message = 'Settings saved';
          _saving = false;
        });
      });
    } catch (error, stack) {
      unawaited(
        CrashlyticsService.recordError(
          error,
          stack,
          reason: 'settings_prefs_save_failed',
          feature: 'settings',
          screenName: 'settings',
        ),
      );
      if (!mounted) return;
      setState(() {
        _message = error.toString();
        _saving = false;
      });
    }
  }

  String get _signedInEmail {
    final user = FirebaseAuth.instance.currentUser;
    final directEmail = user?.email?.trim();
    if (directEmail != null && directEmail.isNotEmpty) return directEmail;
    for (final provider in user?.providerData ?? const <UserInfo>[]) {
      final email = provider.email?.trim();
      if (email != null && email.isNotEmpty) return email;
    }
    return 'Google account';
  }

  Future<void> _logOut() async {
    final confirmed = await _confirmAccountAction(
      title: 'Log out?',
      message: 'You will need to sign in with Google to use One One again.',
      actionLabel: 'Log out',
    );
    if (!confirmed || !mounted) return;

    setState(() {
      _accountActionInProgress = true;
      _message = null;
    });
    try {
      await widget.identityRepository.signOut();
      if (!mounted) return;
      Navigator.of(context).pushNamedAndRemoveUntil('/auth', (_) => false);
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = error.toString());
    } finally {
      if (mounted) setState(() => _accountActionInProgress = false);
    }
  }

  Future<void> _deleteAccount() async {
    final confirmed = await _confirmAccountAction(
      title: 'Delete account permanently?',
      message:
          'Your One One profile, device information, and preferences will be deleted. This cannot be undone.',
      actionLabel: 'Delete account',
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    setState(() {
      _accountActionInProgress = true;
      _message = null;
    });
    try {
      await widget.identityRepository.deleteAccount();
      if (!mounted) return;
      Navigator.of(context).pushNamedAndRemoveUntil('/auth', (_) => false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _message =
            'Account deletion couldn\'t be completed. Sign in with Google again and retry.';
      });
    } finally {
      if (mounted) setState(() => _accountActionInProgress = false);
    }
  }

  Future<bool> _confirmAccountAction({
    required String title,
    required String message,
    required String actionLabel,
    bool destructive = false,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                style: destructive
                    ? FilledButton.styleFrom(
                        backgroundColor: const Color(0xffb3261e),
                        foregroundColor: Colors.white,
                      )
                    : null,
                child: Text(actionLabel),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _openLegalDocument(LegalDocument document) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LegalDocumentScreen(document: document),
      ),
    );
  }

  Future<void> _openGroupManagement() async {
    final groupEnded = await widget.onManageGroup?.call() ?? false;
    if (groupEnded && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final accent = accentColorForKey(_accentColorKey);
    final showSaveButton = _hasUnsavedSettings || _saving;
    final closedAppReceiveReady =
        _session.device.notificationPermissionGranted &&
        _session.device.batteryOptimizationIgnored;

    return Scaffold(
      backgroundColor: const Color(0xff101010),
      appBar: AppBar(
        backgroundColor: const Color(0xff101010),
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('Settings'),
        centerTitle: true,
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.25),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        ),
        child: showSaveButton
            ? SafeArea(
                key: const ValueKey('save-settings-floating-button'),
                minimum: const EdgeInsets.symmetric(horizontal: 20),
                child: SizedBox(
                  width: MediaQuery.sizeOf(context).width - 40,
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _saveSettings,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(54),
                      backgroundColor: accent,
                      foregroundColor: Colors.black,
                    ),
                    icon: _saving
                        ? const SizedBox.square(
                            dimension: 19,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.black,
                            ),
                          )
                        : const Icon(Icons.check_rounded),
                    label: const Text('Save settings'),
                  ),
                ),
              )
            : const SizedBox.shrink(
                key: ValueKey('save-settings-button-hidden'),
              ),
      ),
      body: ColoredBox(
        color: const Color(0xff101010),
        child: SafeArea(
          top: false,
          child: ListView(
            padding: EdgeInsets.fromLTRB(20, 8, 20, showSaveButton ? 112 : 32),
            children: [
              _ProfileHeader(
                session: _session,
                accent: accent,
                photoSaving: _photoSaving,
                enabled: !_saving && !_photoSaving && !_profileEditorOpen,
                onChangePhoto: _changeProfilePhoto,
                onEditProfile: _openProfileEditor,
              ),
              const SizedBox(height: 28),
              if (widget.groupName != null && widget.onManageGroup != null) ...[
                const _SectionTitle('Group'),
                const SizedBox(height: 12),
                _SettingsSurface(
                  padding: EdgeInsets.zero,
                  children: [
                    _NavigationRow(
                      icon: Icons.group_outlined,
                      label: 'Manage ${widget.groupName}',
                      onTap: _openGroupManagement,
                    ),
                  ],
                ),
                const SizedBox(height: 28),
              ],
              const _SectionTitle('Preferences'),
              const SizedBox(height: 12),
              _SettingsSurface(
                children: [
                  _PreferenceHeading(
                    icon: Icons.palette_outlined,
                    title: 'Accent color',
                    subtitle: 'Choose the color used across One One.',
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final option in accentOptions)
                        _ColorSwatch(
                          option: option,
                          selected: _accentColorKey == option.key,
                          enabled: !_saving,
                          onSelected: () {
                            setState(() {
                              _accentColorKey = option.key;
                              _hasUnsavedAccentPreview =
                                  option.key != _persistedAccentColorKey;
                            });
                            AccentThemeController.setAccentKey(option.key);
                          },
                        ),
                    ],
                  ),
                  const _SurfaceDivider(),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(
                      Icons.vibration_outlined,
                      color: Colors.white70,
                    ),
                    title: const Text(
                      'Haptics',
                      style: TextStyle(color: Colors.white),
                    ),
                    subtitle: const Text(
                      'A short vibration when talking starts or stops.',
                      style: TextStyle(color: Colors.white54),
                    ),
                    value: _hapticsEnabled,
                    activeTrackColor: accent,
                    onChanged: _saving ? null : _setHapticsEnabled,
                  ),
                  const _SurfaceDivider(),
                  const _PreferenceHeading(
                    icon: Icons.spatial_audio_off_outlined,
                    title: 'Audio output',
                    subtitle: 'Where incoming voice should play.',
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<String>(
                      style: ButtonStyle(
                        foregroundColor: WidgetStateProperty.resolveWith(
                          (states) => states.contains(WidgetState.selected)
                              ? Colors.black
                              : Colors.white70,
                        ),
                        backgroundColor: WidgetStateProperty.resolveWith(
                          (states) => states.contains(WidgetState.selected)
                              ? accent
                              : Colors.transparent,
                        ),
                      ),
                      segments: const [
                        ButtonSegment(
                          value: 'speaker',
                          icon: Icon(Icons.volume_up_outlined),
                          label: Text('Speaker'),
                        ),
                        ButtonSegment(
                          value: 'earpiece',
                          icon: Icon(Icons.phone_in_talk_outlined),
                          label: Text('Phone'),
                        ),
                      ],
                      selected: {_audioOutputPreference},
                      onSelectionChanged: _saving
                          ? null
                          : (selection) =>
                                _setAudioOutputPreference(selection.first),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 28),
              const _SectionTitle('Background reliability'),
              const SizedBox(height: 12),
              _SettingsSurface(
                children: [
                  _ChecklistItem(
                    ok: _session.device.micPermissionGranted,
                    label: 'Microphone permission',
                    detail: _session.device.micPermissionGranted
                        ? 'Ready'
                        : 'Required before you can talk.',
                  ),
                  _ChecklistItem(
                    ok: _session.device.notificationPermissionGranted,
                    label: 'Notification permission',
                    detail: _session.device.notificationPermissionGranted
                        ? 'Ready for background activity'
                        : 'Required for reliable background activity.',
                  ),
                  _ChecklistItem(
                    ok: _session.device.batteryOptimizationIgnored,
                    label: 'Battery optimization',
                    detail: _session.device.batteryOptimizationIgnored
                        ? 'Unrestricted'
                        : 'Your device may interrupt long sessions.',
                  ),
                  _ChecklistItem(
                    ok: closedAppReceiveReady,
                    label: 'Closed-app receive',
                    detail: closedAppReceiveReady
                        ? 'Ready for nudges when the app is not open.'
                        : 'Allow notifications and unrestricted background activity.',
                    showDivider: false,
                  ),
                ],
              ),
              const SizedBox(height: 28),
              const _SectionTitle('Legal'),
              const SizedBox(height: 12),
              _SettingsSurface(
                padding: EdgeInsets.zero,
                children: [
                  _NavigationRow(
                    icon: Icons.description_outlined,
                    label: 'Terms & Conditions',
                    onTap: () => _openLegalDocument(LegalDocument.terms),
                  ),
                  const _SurfaceDivider(indent: 52),
                  _NavigationRow(
                    icon: Icons.privacy_tip_outlined,
                    label: 'Privacy Policy',
                    onTap: () => _openLegalDocument(LegalDocument.privacy),
                  ),
                ],
              ),
              const SizedBox(height: 28),
              const _SectionTitle('Account'),
              const SizedBox(height: 12),
              _SettingsSurface(
                children: [
                  _PreferenceHeading(
                    icon: Icons.account_circle_outlined,
                    title: _signedInEmail,
                    subtitle: 'Signed in with Google',
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _accountActionInProgress ? null : _logOut,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white24),
                    ),
                    icon: _accountActionInProgress
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.logout_rounded),
                    label: const Text('Log out'),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _accountActionInProgress ? null : _deleteAccount,
                    style: TextButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      foregroundColor: const Color(0xffff8a80),
                    ),
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('Delete account'),
                  ),
                ],
              ),
              if (_message != null) ...[
                const SizedBox(height: 14),
                Text(
                  _message!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

InputDecoration _darkInputDecoration(String label) {
  return InputDecoration(
    labelText: label,
    labelStyle: const TextStyle(color: Colors.white60),
    filled: true,
    fillColor: Colors.white.withValues(alpha: 0.06),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: Colors.white24),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: Colors.white70),
    ),
  );
}

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({
    required this.session,
    required this.accent,
    required this.photoSaving,
    required this.enabled,
    required this.onChangePhoto,
    required this.onEditProfile,
  });

  final IdentitySession session;
  final Color accent;
  final bool photoSaving;
  final bool enabled;
  final VoidCallback onChangePhoto;
  final VoidCallback onEditProfile;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Stack(
          alignment: Alignment.bottomRight,
          children: [
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: accent, width: 2),
              ),
              child: ProfileAvatar(
                profilePhotoUrl: session.user.profilePhotoUrl,
                profilePhotoBase64: session.user.profilePhotoBase64,
                avatarAsset: session.user.avatarAsset,
                radius: 48,
                backgroundColor: const Color(0xff2b2b2b),
                fallback: const Icon(
                  Icons.person_outline,
                  color: Colors.white54,
                  size: 42,
                ),
              ),
            ),
            Material(
              color: accent,
              shape: const CircleBorder(),
              child: IconButton(
                tooltip: 'Change profile picture',
                onPressed: enabled ? onChangePhoto : null,
                icon: photoSaving
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.black,
                        ),
                      )
                    : const Icon(Icons.camera_alt_outlined),
                color: Colors.black,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          session.user.displayName,
          maxLines: 2,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: enabled ? onEditProfile : null,
          icon: const Icon(Icons.edit_outlined, size: 18),
          label: const Text('Edit profile'),
          style: TextButton.styleFrom(foregroundColor: accent),
        ),
      ],
    );
  }
}

class _EditProfileSheetResult {
  const _EditProfileSheetResult({this.session, this.message});

  final IdentitySession? session;
  final String? message;
}

/// Self-contained edit-profile sheet. Owns the [TextEditingController] so
/// dispose is tied to the modal route's element tree — not a parent callback
/// that can fire while the field is still listening.
class _EditProfileSheet extends StatefulWidget {
  const _EditProfileSheet({
    required this.session,
    required this.accentColorKey,
    required this.avatarsFuture,
    required this.identityRepository,
  });

  final IdentitySession session;
  final String accentColorKey;
  final Future<List<AvatarAsset>>? avatarsFuture;
  final IdentityRepository identityRepository;

  @override
  State<_EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends State<_EditProfileSheet> {
  late final TextEditingController _nameController;
  late IdentitySession _session;
  String? _pendingAvatarAsset;
  late _AvatarSectionMode _avatarSectionMode;
  bool _saving = false;
  bool _changingPhoto = false;

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    _nameController = TextEditingController(text: _session.user.displayName);
    _avatarSectionMode = _session.user.avatarAsset != null
        ? _AvatarSectionMode.avatar
        : _AvatarSectionMode.photo;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<Uint8List?> _pickPhoto({
    required bool recropCurrent,
    required String? currentUrl,
  }) {
    if (recropCurrent) {
      return ProfilePhotoEditor.recropNetworkPhoto(context, currentUrl!);
    }
    return ProfilePhotoEditor.pickAndCrop(context);
  }

  /// Drop focus first so [TextField] detaches cleanly before route pop.
  Future<void> _popSheet(_EditProfileSheetResult result) async {
    FocusManager.instance.primaryFocus?.unfocus();
    // Let the field process unfocus before the element tree starts deactivating.
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    Navigator.of(context).pop(result);
  }

  Future<void> _changePhoto() async {
    if (_saving || _changingPhoto) return;
    setState(() => _changingPhoto = true);
    try {
      unawaited(CrashlyticsService.log('settings_edit_profile_photo_start'));
      final bytes = await _pickPhoto(
        recropCurrent: false,
        currentUrl: _session.user.profilePhotoUrl,
      );
      if (bytes == null || !mounted) return;
      final session =
          await widget.identityRepository.updateProfilePhoto(bytes);
      unawaited(
        CrashlyticsService.log('settings_edit_profile_photo_network_ok'),
      );
      if (!mounted) return;
      setState(() {
        _session = session;
        _pendingAvatarAsset = null;
        _avatarSectionMode = _AvatarSectionMode.photo;
      });
    } catch (error, stack) {
      unawaited(
        CrashlyticsService.recordError(
          error,
          stack,
          reason: 'settings_edit_profile_photo_failed',
          feature: 'settings',
          screenName: 'settings',
        ),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    } finally {
      if (mounted) setState(() => _changingPhoto = false);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final displayName = _nameController.text.trim();
    final nameChanged =
        displayName.isNotEmpty && displayName != _session.user.displayName;
    final avatarChanged =
        _pendingAvatarAsset != null &&
        _pendingAvatarAsset != _session.user.avatarAsset;

    if (!nameChanged && !avatarChanged) {
      unawaited(
        CrashlyticsService.log('settings_edit_profile_pop_no_change'),
      );
      if (!mounted) return;
      await _popSheet(_EditProfileSheetResult(session: _session));
      return;
    }

    unawaited(
      CrashlyticsService.log(
        'settings_edit_profile_save_start '
        'name=$nameChanged avatar=$avatarChanged',
      ),
    );
    setState(() => _saving = true);
    try {
      var session = _session;
      if (nameChanged) {
        session = await widget.identityRepository.updateDisplayName(
          displayName,
        );
        unawaited(
          CrashlyticsService.log('settings_edit_profile_name_network_ok'),
        );
      }
      if (avatarChanged) {
        session = await widget.identityRepository.updatePresetAvatar(
          _pendingAvatarAsset!,
        );
        unawaited(
          CrashlyticsService.log('settings_edit_profile_avatar_network_ok'),
        );
      }
      if (!mounted) return;
      unawaited(CrashlyticsService.log('settings_edit_profile_pop'));
      // Capture results and close before any parent setState can race modal
      // deactivation. Local state is enough for this frame; the parent applies
      // the returned session after the route is fully gone.
      await _popSheet(
        _EditProfileSheetResult(
          session: session,
          message: 'Profile updated',
        ),
      );
    } catch (error, stack) {
      unawaited(
        CrashlyticsService.recordError(
          error,
          stack,
          reason: 'settings_edit_profile_save_failed',
          feature: 'settings',
          screenName: 'settings',
        ),
      );
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = accentColorForKey(widget.accentColorKey);
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final draftAsset = _pendingAvatarAsset ?? _session.user.avatarAsset;
    final nameTrimmed = _nameController.text.trim();
    final nameChanged =
        nameTrimmed.isNotEmpty && nameTrimmed != _session.user.displayName;
    final avatarChanged =
        _pendingAvatarAsset != null &&
        _pendingAvatarAsset != _session.user.avatarAsset;
    final hasChanges = nameChanged || avatarChanged;
    final busy = _saving || _changingPhoto;

    return Padding(
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                children: [
                  Text(
                    'Edit profile',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'This is how friends see you in your groups.',
                    style: TextStyle(color: Colors.white60),
                  ),
                  const SizedBox(height: 22),
                  TextField(
                    controller: _nameController,
                    autofocus: true,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.done,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: busy ? null : (_) => _save(),
                    style: const TextStyle(color: Colors.white),
                    decoration: _darkInputDecoration('Display name'),
                  ),
                  const SizedBox(height: 28),
                  const Text(
                    'AVATAR',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _AvatarSection(
                    mode: _avatarSectionMode,
                    onModeChanged: (mode) =>
                        setState(() => _avatarSectionMode = mode),
                    avatarsFuture: widget.avatarsFuture,
                    selectedAsset: draftAsset,
                    accent: accent,
                    avatarSaving: _saving,
                    onAvatarSelected: (asset) {
                      setState(() {
                        _pendingAvatarAsset = asset;
                        _avatarSectionMode = _AvatarSectionMode.avatar;
                      });
                    },
                    showSaveAvatar: false,
                    onSaveAvatar: () {},
                    profilePhotoUrl: _session.user.profilePhotoUrl,
                    profilePhotoBase64: _session.user.profilePhotoBase64,
                    photoSaving: _changingPhoto,
                    onChangePhoto: _changePhoto,
                    enabled: !busy,
                  ),
                ],
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xff1b1b1b),
                border: Border(
                  top: BorderSide(
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 18,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
                  child: FilledButton.icon(
                    onPressed: busy ? null : _save,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                      backgroundColor: hasChanges
                          ? accent
                          : accent.withValues(alpha: 0.55),
                      foregroundColor: Colors.black,
                    ),
                    icon: _saving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.black,
                            ),
                          )
                        : Icon(
                            hasChanges
                                ? Icons.check_rounded
                                : Icons.save_outlined,
                          ),
                    label: Text(
                      _saving
                          ? 'Saving…'
                          : hasChanges
                          ? 'Save profile'
                          : 'Done',
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _AvatarSectionMode { avatar, photo }

/// Lets existing users switch between a bundled preset avatar and a custom
/// photo. Preset choice is a draft until Save; photo applies when uploaded.
class _AvatarSection extends StatelessWidget {
  const _AvatarSection({
    required this.mode,
    required this.onModeChanged,
    required this.avatarsFuture,
    required this.selectedAsset,
    required this.accent,
    required this.avatarSaving,
    required this.onAvatarSelected,
    required this.showSaveAvatar,
    required this.onSaveAvatar,
    required this.profilePhotoUrl,
    required this.profilePhotoBase64,
    required this.photoSaving,
    required this.onChangePhoto,
    required this.enabled,
  });

  final _AvatarSectionMode mode;
  final ValueChanged<_AvatarSectionMode> onModeChanged;
  final Future<List<AvatarAsset>>? avatarsFuture;
  final String? selectedAsset;
  final Color accent;
  final bool avatarSaving;
  final ValueChanged<String> onAvatarSelected;
  final bool showSaveAvatar;
  final VoidCallback onSaveAvatar;
  final String? profilePhotoUrl;
  final String? profilePhotoBase64;
  final bool photoSaving;
  final VoidCallback onChangePhoto;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<_AvatarSectionMode>(
          style: ButtonStyle(
            foregroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? Colors.black
                  : Colors.white70,
            ),
            backgroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? accent
                  : Colors.transparent,
            ),
          ),
          segments: const [
            ButtonSegment(
              value: _AvatarSectionMode.avatar,
              icon: Icon(Icons.face_retouching_natural_outlined),
              label: Text('Avatar'),
            ),
            ButtonSegment(
              value: _AvatarSectionMode.photo,
              icon: Icon(Icons.photo_camera_outlined),
              label: Text('Photo'),
            ),
          ],
          selected: {mode},
          onSelectionChanged: enabled
              ? (selection) => onModeChanged(selection.first)
              : null,
        ),
        const SizedBox(height: 18),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: mode == _AvatarSectionMode.avatar
              ? _AvatarTabContent(
                  key: const ValueKey('avatar-tab'),
                  avatarsFuture: avatarsFuture,
                  selectedAsset: selectedAsset,
                  accent: accent,
                  enabled: enabled,
                  onAvatarSelected: onAvatarSelected,
                  showSave: showSaveAvatar,
                  onSave: onSaveAvatar,
                  saving: avatarSaving,
                )
              : _PhotoTabContent(
                  key: const ValueKey('photo-tab'),
                  profilePhotoUrl: profilePhotoUrl,
                  profilePhotoBase64: profilePhotoBase64,
                  accent: accent,
                  enabled: enabled,
                  saving: photoSaving,
                  onChangePhoto: onChangePhoto,
                ),
        ),
      ],
    );
  }
}

class _AvatarTabContent extends StatelessWidget {
  const _AvatarTabContent({
    super.key,
    required this.avatarsFuture,
    required this.selectedAsset,
    required this.accent,
    required this.enabled,
    required this.onAvatarSelected,
    required this.showSave,
    required this.onSave,
    required this.saving,
  });

  final Future<List<AvatarAsset>>? avatarsFuture;
  final String? selectedAsset;
  final Color accent;
  final bool enabled;
  final ValueChanged<String> onAvatarSelected;
  final bool showSave;
  final VoidCallback onSave;
  final bool saving;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<AvatarAsset>>(
      future: avatarsFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        return Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Nested under Settings' ListView so every avatar across both
                // packs is reachable via the outer scroll.
                AvatarPickerGrid(
                  avatars: snapshot.data!,
                  selectedAsset: selectedAsset,
                  enabled: enabled,
                  accent: accent,
                  onAvatarSelected: onAvatarSelected,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                ),
                if (showSave) ...[
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: saving ? null : onSave,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                      backgroundColor: accent,
                      foregroundColor: Colors.black,
                    ),
                    icon: saving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.black,
                            ),
                          )
                        : const Icon(Icons.check_rounded),
                    label: Text(saving ? 'Saving…' : 'Save avatar'),
                  ),
                ],
              ],
            ),
            if (saving)
              const Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(color: Color(0x661b1b1b)),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _PhotoTabContent extends StatelessWidget {
  const _PhotoTabContent({
    super.key,
    required this.profilePhotoUrl,
    required this.profilePhotoBase64,
    required this.accent,
    required this.enabled,
    required this.saving,
    required this.onChangePhoto,
  });

  final String? profilePhotoUrl;
  final String? profilePhotoBase64;
  final Color accent;
  final bool enabled;
  final bool saving;
  final VoidCallback onChangePhoto;

  @override
  Widget build(BuildContext context) {
    final hasPhoto =
        (profilePhotoUrl?.trim().isNotEmpty ?? false) ||
        (profilePhotoBase64?.trim().isNotEmpty ?? false);

    return Row(
      children: [
        ClipOval(
          child: SizedBox(
            width: 64,
            height: 64,
            child: ProfileImage(
              profilePhotoUrl: profilePhotoUrl,
              profilePhotoBase64: profilePhotoBase64,
              backgroundColor: const Color(0xff2b2b2b),
              fallback: const Icon(
                Icons.person_outline,
                color: Colors.white54,
              ),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                hasPhoto ? 'Your uploaded photo' : 'No photo uploaded yet',
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: enabled ? onChangePhoto : null,
                style: OutlinedButton.styleFrom(
                  foregroundColor: accent,
                  side: BorderSide(color: accent),
                ),
                icon: saving
                    ? SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: accent,
                        ),
                      )
                    : const Icon(Icons.upload_outlined, size: 18),
                label: Text(hasPhoto ? 'Change photo' : 'Upload photo'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: const TextStyle(
        color: Colors.white54,
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
    );
  }
}

class _SettingsSurface extends StatelessWidget {
  const _SettingsSurface({
    required this.children,
    this.padding = const EdgeInsets.all(18),
  });

  final List<Widget> children;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xff1b1b1b),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.09)),
      ),
      child: Padding(
        padding: padding,
        child: Column(children: children),
      ),
    );
  }
}

class _PreferenceHeading extends StatelessWidget {
  const _PreferenceHeading({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: Colors.white70),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(color: Colors.white)),
              const SizedBox(height: 2),
              Text(subtitle, style: const TextStyle(color: Colors.white54)),
            ],
          ),
        ),
      ],
    );
  }
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    required this.option,
    required this.selected,
    required this.enabled,
    required this.onSelected,
  });

  final AccentOption option;
  final bool selected;
  final bool enabled;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: option.label,
      child: Semantics(
        button: true,
        selected: selected,
        label: '${option.label} accent',
        child: SizedBox.square(
          dimension: 48,
          child: InkWell(
            onTap: enabled ? onSelected : null,
            customBorder: const CircleBorder(),
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: option.color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? Colors.white : Colors.transparent,
                    width: 3,
                  ),
                ),
                child: selected
                    ? const Icon(
                        Icons.check_rounded,
                        color: Colors.black,
                        size: 19,
                      )
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavigationRow extends StatelessWidget {
  const _NavigationRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, color: Colors.white70),
      title: Text(label, style: const TextStyle(color: Colors.white)),
      trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white38),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 2),
    );
  }
}

class _SurfaceDivider extends StatelessWidget {
  const _SurfaceDivider({this.indent = 0});
  final double indent;

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 30,
      indent: indent,
      color: Colors.white.withValues(alpha: 0.09),
    );
  }
}

class _ChecklistItem extends StatelessWidget {
  const _ChecklistItem({
    required this.ok,
    required this.label,
    required this.detail,
    this.showDivider = true,
  });

  final bool ok;
  final String label;
  final String detail;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final statusColor = ok ? const Color(0xff7CFF6B) : const Color(0xffffb020);
    return Column(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              ok ? Icons.check_circle_outline : Icons.info_outline,
              color: statusColor,
              size: 22,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(color: Colors.white)),
                  const SizedBox(height: 3),
                  Text(
                    detail,
                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (showDivider) const _SurfaceDivider(),
      ],
    );
  }
}
