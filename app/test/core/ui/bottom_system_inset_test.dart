import 'package:flutter_test/flutter_test.dart';

import 'package:one_one_app/one_one.dart';

void main() {
  testWidgets('uses viewPadding when padding.bottom is stripped', (
    tester,
  ) async {
    late double inset;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(400, 800),
          padding: EdgeInsets.zero,
          viewPadding: EdgeInsets.only(bottom: 48),
        ),
        child: Builder(
          builder: (context) {
            inset = bottomSystemInsetOf(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(inset, 48);
  });

  testWidgets('does not stack nav inset on top of the keyboard', (
    tester,
  ) async {
    late double inset;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(400, 800),
          padding: EdgeInsets.zero,
          viewPadding: EdgeInsets.only(bottom: 48),
          viewInsets: EdgeInsets.only(bottom: 300),
        ),
        child: Builder(
          builder: (context) {
            inset = bottomSystemInsetOf(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(inset, 0);
  });

  testWidgets('restores padding.bottom without touching the top inset', (
    tester,
  ) async {
    const original = MediaQueryData(
      size: Size(400, 800),
      padding: EdgeInsets.only(top: 44),
      viewPadding: EdgeInsets.only(top: 44, bottom: 48),
    );
    final restored = withEnsuredBottomInset(original);
    expect(restored.padding.top, 44);
    expect(restored.padding.bottom, 48);
  });
}
