import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/storage/cloudinary_delivery.dart';
import '../../../core/storage/profile_photo_optimizer.dart';

/// Shared profile-photo editor used by onboarding and Settings.
///
/// Gallery/camera originals are downscaled before the crop UI, then the
/// confirmed crop is normalized off the UI isolate to a square JPEG no larger
/// than [ProfilePhotoOptimizer.maxEdge]. Small sources are not upscaled.
class ProfilePhotoEditor {
  ProfilePhotoEditor._();

  static const int outputSize = ProfilePhotoOptimizer.maxEdge;
  static final ImagePicker _picker = ImagePicker();
  static final ImageCropper _cropper = ImageCropper();

  static Future<Uint8List?> pickAndCrop(BuildContext context) async {
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: ProfilePhotoOptimizer.pickerMaxEdge.toDouble(),
      maxHeight: ProfilePhotoOptimizer.pickerMaxEdge.toDouble(),
      imageQuality: ProfilePhotoOptimizer.cropperPreviewQuality,
    );
    if (picked == null || !context.mounted) return null;
    return _cropAndNormalize(context, picked.path);
  }

  static Future<Uint8List?> recropNetworkPhoto(
    BuildContext context,
    String photoUrl,
  ) async {
    final fetchUrl = CloudinaryDelivery.urlFor(
      photoUrl,
      pixelSize: ProfilePhotoOptimizer.maxEdge,
    );
    final response = await http.get(Uri.parse(fetchUrl));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Couldn\'t load the current profile picture.');
    }

    final temporaryFile = File(
      '${Directory.systemTemp.path}/one_one_profile_${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    await temporaryFile.writeAsBytes(response.bodyBytes, flush: true);
    try {
      if (!context.mounted) return null;
      return await _cropAndNormalize(context, temporaryFile.path);
    } finally {
      try {
        await temporaryFile.delete();
      } catch (_) {
        // The OS will clear its temporary directory if cleanup fails.
      }
    }
  }

  static Future<Uint8List?> _cropAndNormalize(
    BuildContext context,
    String sourcePath,
  ) async {
    final accent = Theme.of(context).colorScheme.primary;
    final cropped = await _cropper.cropImage(
      sourcePath: sourcePath,
      maxWidth: outputSize,
      maxHeight: outputSize,
      aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
      compressFormat: ImageCompressFormat.jpg,
      compressQuality: ProfilePhotoOptimizer.cropperPreviewQuality,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Crop profile picture',
          toolbarColor: const Color(0xff101010),
          toolbarWidgetColor: Colors.white,
          backgroundColor: const Color(0xff101010),
          activeControlsWidgetColor: accent,
          lockAspectRatio: true,
          initAspectRatio: CropAspectRatioPreset.square,
          aspectRatioPresets: const [CropAspectRatioPreset.square],
        ),
        IOSUiSettings(
          title: 'Crop profile picture',
          aspectRatioLockEnabled: true,
          resetAspectRatioEnabled: false,
          aspectRatioPickerButtonHidden: true,
          aspectRatioPresets: const [CropAspectRatioPreset.square],
        ),
      ],
    );
    if (cropped == null) return null;

    final croppedBytes = await cropped.readAsBytes();
    return compute(ProfilePhotoOptimizer.normalize, croppedBytes);
  }
}
