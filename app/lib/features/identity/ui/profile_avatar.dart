import 'dart:convert';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/storage/cloudinary_delivery.dart';
import '../data/avatar_assets.dart';

/// First letter of the user's display name for avatar fallbacks.
String profileDisplayInitial(String displayName) {
  final trimmed = displayName.trim();
  if (trimmed.isEmpty) return '?';
  final words = trimmed.split(RegExp(r'\s+'));
  var word = words.first;
  if (word.startsWith('@') && word.length > 1) {
    word = word.substring(1);
  }
  if (word.isEmpty) return '?';
  return word.substring(0, 1).toUpperCase();
}

/// Renders a profile photo filling its bounds, falling back to [fallback]
/// (or a person icon) when there is no photo or the photo fails to load.
///
/// Unlike a bare `CircleAvatar` with `backgroundImage`, load failures are
/// surfaced through [CachedNetworkImage]'s `errorWidget` (and logged via
/// [debugPrint]) instead of silently rendering a blank space, which was
/// previously hiding broken Cloudinary URLs.
///
/// While an update is in-flight and source fields are briefly empty, the last
/// successfully rendered avatar/photo is kept so the face never flashes blank.
class ProfileImage extends StatefulWidget {
  const ProfileImage({
    super.key,
    this.profilePhotoUrl,
    this.profilePhotoBase64,
    this.avatarAsset,
    this.backgroundColor,
    this.fallback,
    this.fit = BoxFit.cover,
    this.fadeInDuration = const Duration(milliseconds: 150),
  });

  final String? profilePhotoUrl;
  final String? profilePhotoBase64;
  final String? avatarAsset;
  final Color? backgroundColor;
  final Widget? fallback;
  final BoxFit fit;
  final Duration fadeInDuration;

  @override
  State<ProfileImage> createState() => _ProfileImageState();
}

class _ProfileImageState extends State<ProfileImage> {
  String? _stickyAvatarAsset;
  String? _stickyPhotoUrl;
  String? _stickyPhotoBase64;

  @override
  void initState() {
    super.initState();
    _captureStickySources();
  }

  @override
  void didUpdateWidget(covariant ProfileImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _captureStickySources();
  }

  /// Remembers the last non-empty visual source so a transient clear during
  /// save never collapses the tile to a blank fallback.
  void _captureStickySources() {
    final asset = widget.avatarAsset?.trim();
    if (asset != null &&
        asset.isNotEmpty &&
        AvatarAssets.isPresetAvatarPath(asset)) {
      _stickyAvatarAsset = asset;
      _stickyPhotoUrl = null;
      _stickyPhotoBase64 = null;
      return;
    }

    final url = widget.profilePhotoUrl?.trim();
    if (url != null && url.isNotEmpty) {
      _stickyAvatarAsset = null;
      _stickyPhotoUrl = url;
      _stickyPhotoBase64 = null;
      return;
    }

    final encoded = widget.profilePhotoBase64?.trim();
    if (encoded != null && encoded.isNotEmpty) {
      _stickyAvatarAsset = null;
      _stickyPhotoUrl = null;
      _stickyPhotoBase64 = encoded;
    }
    // If everything is empty, keep existing sticky values as-is.
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final resolvedBackgroundColor =
        backgroundColorOrDefault(colors);
    final resolvedFallback =
        widget.fallback ??
        Icon(Icons.person_outline, color: colors.onSurfaceVariant);

    // Prefer live widget props when present; otherwise fall back to sticky.
    final asset = _resolvedAsset();
    if (asset != null) {
      return ColoredBox(
        color: resolvedBackgroundColor,
        child: Image.asset(asset, fit: widget.fit),
      );
    }

    final url = _resolvedUrl();
    if (url != null) {
      return ColoredBox(
        color: resolvedBackgroundColor,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final deliveryUrl = CloudinaryDelivery.urlFor(
              url,
              pixelSize: _pixelSizeFor(context, constraints),
            );
            return CachedNetworkImage(
              imageUrl: deliveryUrl,
              fit: widget.fit,
              fadeInDuration: widget.fadeInDuration,
              placeholder: (context, url) =>
                  _stickyPlaceholder(
                    resolvedBackgroundColor,
                    resolvedFallback,
                  ) ??
                  Center(child: resolvedFallback),
              errorWidget: (context, url, error) {
                debugPrint(
                  'ProfileImage: failed to load profile photo: '
                  '${error.runtimeType}',
                );
                return Center(child: resolvedFallback);
              },
            );
          },
        ),
      );
    }

    final encodedPhoto = _resolvedBase64();
    if (encodedPhoto != null) {
      try {
        final bytes = base64Decode(encodedPhoto);
        return ColoredBox(
          color: resolvedBackgroundColor,
          child: Image.memory(
            bytes,
            fit: widget.fit,
            errorBuilder: (context, error, stackTrace) {
              debugPrint('ProfileImage: failed to decode base64 photo: $error');
              return Center(child: resolvedFallback);
            },
          ),
        );
      } catch (error) {
        debugPrint('ProfileImage: failed to decode base64 photo: $error');
      }
    }

    return ColoredBox(
      color: resolvedBackgroundColor,
      child: Center(child: resolvedFallback),
    );
  }

  Color backgroundColorOrDefault(ColorScheme colors) {
    return widget.backgroundColor ?? colors.surfaceContainerHighest;
  }

  /// While a network photo is loading, keep the previous preset visible so
  /// the tile doesn't blank mid-update.
  Widget? _stickyPlaceholder(Color background, Widget fallback) {
    final sticky = _stickyAvatarAsset;
    if (sticky == null) return null;
    return ColoredBox(
      color: background,
      child: Image.asset(sticky, fit: widget.fit),
    );
  }

  String? _resolvedAsset() {
    final live = widget.avatarAsset?.trim();
    if (live != null &&
        live.isNotEmpty &&
        AvatarAssets.isPresetAvatarPath(live)) {
      return live;
    }
    // If a live URL/base64 is present, don't prefer a sticky preset over it.
    final liveUrl = widget.profilePhotoUrl?.trim();
    final liveBase64 = widget.profilePhotoBase64?.trim();
    if ((liveUrl != null && liveUrl.isNotEmpty) ||
        (liveBase64 != null && liveBase64.isNotEmpty)) {
      return null;
    }
    final sticky = _stickyAvatarAsset?.trim();
    if (sticky != null &&
        sticky.isNotEmpty &&
        AvatarAssets.isPresetAvatarPath(sticky)) {
      return sticky;
    }
    return null;
  }

  String? _resolvedUrl() {
    final live = widget.profilePhotoUrl?.trim();
    if (live != null && live.isNotEmpty) return live;
    final sticky = _stickyPhotoUrl?.trim();
    if (sticky != null && sticky.isNotEmpty) return sticky;
    return null;
  }

  String? _resolvedBase64() {
    final live = widget.profilePhotoBase64?.trim();
    if (live != null && live.isNotEmpty) return live;
    final sticky = _stickyPhotoBase64?.trim();
    if (sticky != null && sticky.isNotEmpty) return sticky;
    return null;
  }

  int _pixelSizeFor(BuildContext context, BoxConstraints constraints) {
    final width = constraints.maxWidth;
    final height = constraints.maxHeight;
    final logical = math.max(
      width.isFinite ? width : 0,
      height.isFinite ? height : 0,
    );
    if (logical <= 0) return CloudinaryDelivery.maxStoredEdge;
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    return (logical * dpr).round();
  }
}

/// Circular profile avatar built on top of [ProfileImage].
class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({
    super.key,
    this.profilePhotoUrl,
    this.profilePhotoBase64,
    this.avatarAsset,
    required this.radius,
    this.backgroundColor,
    this.fallback,
  });

  final String? profilePhotoUrl;
  final String? profilePhotoBase64;
  final String? avatarAsset;
  final double radius;
  final Color? backgroundColor;
  final Widget? fallback;

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: SizedBox(
        width: radius * 2,
        height: radius * 2,
        child: ProfileImage(
          profilePhotoUrl: profilePhotoUrl,
          profilePhotoBase64: profilePhotoBase64,
          avatarAsset: avatarAsset,
          backgroundColor: backgroundColor,
          fallback: fallback,
        ),
      ),
    );
  }
}
