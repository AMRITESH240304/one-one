import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../features/identity/data/identity_repository.dart';
import '../features/identity/models/identity_session.dart';

class ProfilePictureScreen extends StatefulWidget {
  const ProfilePictureScreen({
    super.key,
    required this.session,
    required this.identityRepository,
    required this.onComplete,
  });

  final IdentitySession session;
  final IdentityRepository identityRepository;
  final Future<void> Function(IdentitySession session) onComplete;

  @override
  State<ProfilePictureScreen> createState() => _ProfilePictureScreenState();
}

class _ProfilePictureScreenState extends State<ProfilePictureScreen> {
  static const _avatars = [
    'assets/avatars/avatar_01.png',
    'assets/avatars/avatar_02.png',
    'assets/avatars/avatar_03.png',
    'assets/avatars/avatar_04.png',
    'assets/avatars/avatar_05.png',
    'assets/avatars/avatar_06.png',
    'assets/avatars/avatar_07.png',
    'assets/avatars/avatar_08.png',
    'assets/avatars/avatar_09.png',
    'assets/avatars/avatar_10.png',
    'assets/avatars2/avatar_01.png',
    'assets/avatars2/avatar_02.png',
    'assets/avatars2/avatar_03.png',
    'assets/avatars2/avatar_04.png',
    'assets/avatars2/avatar_05.png',
    'assets/avatars2/avatar_06.png',
  ];

  String? _selected;
  bool _saving = false;

  Future<void> _continue() async {
    final avatar = _selected;
    if (avatar == null || _saving) return;
    setState(() => _saving = true);
    try {
      await widget.onComplete(
        await widget.identityRepository.updatePresetAvatar(avatar),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(24.w, 36.h, 24.w, 24.h),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'choose an avatar',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 27.sp,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: 8.h),
              Text(
                'You can add a custom photo later in Settings.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white60, fontSize: 13.sp),
              ),
              SizedBox(height: 32.h),
              Expanded(
                child: GridView.builder(
                  itemCount: _avatars.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 16,
                  ),
                  itemBuilder: (context, index) {
                    final avatar = _avatars[index];
                    final selected = avatar == _selected;
                    return Semantics(
                      button: true,
                      selected: selected,
                      label: 'Avatar ${index + 1}',
                      child: InkResponse(
                        onTap: _saving
                            ? null
                            : () => setState(() => _selected = avatar),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: selected
                                  ? const Color(0xffF8BE03)
                                  : Colors.transparent,
                              width: 3,
                            ),
                          ),
                          child: ClipOval(
                            child: Image.asset(avatar, fit: BoxFit.cover),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              SizedBox(height: 16.h),
              FilledButton(
                onPressed: _selected == null || _saving ? null : _continue,
                style: FilledButton.styleFrom(
                  minimumSize: Size.fromHeight(54.h),
                  backgroundColor: const Color(0xffF8BE03),
                  foregroundColor: Colors.black,
                ),
                child: _saving
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.black,
                        ),
                      )
                    : const Text('Continue'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
