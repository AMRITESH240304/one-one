import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:purchases_ui_flutter/purchases_ui_flutter.dart';

import '../../app/app_config.dart';

/// Manage Subscription sheet with store management + Team Duo contact.
///
/// Keeps Customer Center for store-side cancel/upgrade flows while exposing
/// a clear in-app contact path during Duo Pro beta.
class SubscriptionManagementSheet extends StatelessWidget {
  const SubscriptionManagementSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xff1b1b1b),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => const SubscriptionManagementSheet(),
    );
  }

  static Future<void> contactTeamDuo(BuildContext context) {
    return _promptContactTeamDuo(context);
  }

  Future<void> _openCustomerCenter(BuildContext context) async {
    Navigator.of(context).pop();
    try {
      await RevenueCatUI.presentCustomerCenter();
    } catch (error) {
      debugPrint('Customer Center error: $error');
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open subscription management.'),
        ),
      );
    }
  }

  Future<void> _contactTeamDuo(BuildContext context) {
    return _promptContactTeamDuo(context);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Image.asset(
                  'assets/logo-new.png',
                  width: 36,
                  height: 36,
                  fit: BoxFit.contain,
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            'Manage Subscription',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          SizedBox(width: 8),
                          _SheetBetaBadge(),
                        ],
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Duo Pro is currently in beta.',
                        style: TextStyle(color: Colors.white54, fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            _SheetAction(
              icon: Icons.manage_accounts_outlined,
              label: 'Manage in store',
              subtitle: 'Upgrade, cancel, or restore with App Store / Play',
              onTap: () => _openCustomerCenter(context),
            ),
            const SizedBox(height: 8),
            _SheetAction(
              icon: Icons.mail_outline_rounded,
              label: 'Contact Team Duo',
              subtitle: 'Billing questions & beta feedback',
              onTap: () => _contactTeamDuo(context),
            ),
            const SizedBox(height: 12),
            const Text(
              'During beta, reply times may vary. For store refunds, use '
              'Manage in store when available.',
              style: TextStyle(
                color: Colors.white38,
                fontSize: 11.5,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _promptContactTeamDuo(BuildContext context) async {
  final email = AppConfig.teamDuoContactEmail;

  try {
    await Clipboard.setData(ClipboardData(text: email));
  } catch (_) {
    // Clipboard can fail on some platforms; still show the dialog.
  }

  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        backgroundColor: const Color(0xff1b1b1b),
        title: const Text(
          'Contact Team Duo',
          style: TextStyle(color: Colors.white),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Duo Pro is in beta. Email us about billing, access, or feedback:',
              style: TextStyle(color: Colors.white70, height: 1.4),
            ),
            const SizedBox(height: 14),
            SelectableText(
              email,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Email address copied to your clipboard.',
              style: TextStyle(color: Colors.white54, fontSize: 12.5),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}

class _SheetBetaBadge extends StatelessWidget {
  const _SheetBetaBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xffffb020).withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: const Color(0xffffb020).withValues(alpha: 0.55),
        ),
      ),
      child: const Text(
        'BETA',
        style: TextStyle(
          color: Color(0xffffb020),
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class _SheetAction extends StatelessWidget {
  const _SheetAction({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xff242424),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              Icon(icon, color: Colors.white70),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: Colors.white38),
            ],
          ),
        ),
      ),
    );
  }
}
