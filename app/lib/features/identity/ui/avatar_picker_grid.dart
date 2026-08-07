import 'package:flutter/material.dart';

import '../data/avatar_assets.dart';

/// Pack switcher ("Avatar 1" / "Avatar 2") + grid of preset avatars.
///
/// Shared by onboarding ([ProfilePictureScreen]) and the Settings avatar
/// section so both present the exact same picker.
class AvatarPickerGrid extends StatelessWidget {
  const AvatarPickerGrid({
    super.key,
    required this.avatars,
    required this.selectedPack,
    required this.selectedAsset,
    required this.enabled,
    required this.accent,
    required this.onPackChanged,
    required this.onAvatarSelected,
    this.physics,
    this.shrinkWrap = false,
  });

  final List<AvatarAsset> avatars;
  final AvatarPack selectedPack;
  final String? selectedAsset;
  final bool enabled;
  final Color accent;
  final ValueChanged<AvatarPack> onPackChanged;
  final ValueChanged<String> onAvatarSelected;

  /// Scroll physics for the inner grid. Pass [NeverScrollableScrollPhysics]
  /// when embedding this inside another scrollable (e.g. a Settings list).
  final ScrollPhysics? physics;

  /// Whether the inner grid should size itself to its content instead of
  /// expanding to fill the available space. Set to true when embedding this
  /// inside another scrollable.
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    final packAvatars = avatars
        .where((avatar) => avatar.pack == selectedPack)
        .toList();

    final grid = GridView.builder(
      key: ValueKey(selectedPack),
      shrinkWrap: shrinkWrap,
      physics: physics,
      itemCount: packAvatars.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
      ),
      itemBuilder: (context, index) {
        final avatar = packAvatars[index];
        final selected = avatar.assetPath == selectedAsset;
        return _AvatarTile(
          assetPath: avatar.assetPath,
          label: 'Avatar ${index + 1}',
          selected: selected,
          accent: accent,
          onTap: enabled ? () => onAvatarSelected(avatar.assetPath) : null,
        );
      },
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: shrinkWrap ? MainAxisSize.min : MainAxisSize.max,
      children: [
        SegmentedButton<AvatarPack>(
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
            side: const WidgetStatePropertyAll(
              BorderSide(color: Colors.white24),
            ),
          ),
          segments: [
            for (final pack in AvatarPack.values)
              ButtonSegment(value: pack, label: Text(pack.label)),
          ],
          selected: {selectedPack},
          onSelectionChanged: enabled
              ? (selection) => onPackChanged(selection.first)
              : null,
        ),
        SizedBox(height: shrinkWrap ? 16 : 20),
        shrinkWrap ? grid : Expanded(child: grid),
      ],
    );
  }
}

class _AvatarTile extends StatelessWidget {
  const _AvatarTile({
    required this.assetPath,
    required this.label,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final String assetPath;
  final String label;
  final bool selected;
  final Color accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkResponse(
        onTap: onTap,
        child: Stack(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? accent : Colors.transparent,
                  width: 3,
                ),
              ),
              child: ClipOval(
                child: Image.asset(assetPath, fit: BoxFit.cover),
              ),
            ),
            if (selected)
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: accent,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.black, width: 1.5),
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    size: 14,
                    color: Colors.black,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
