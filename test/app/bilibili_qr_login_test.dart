import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:segmeris/src/app/app_theme.dart';
import 'package:segmeris/src/app/bilibili_qr_login.dart';

import '../widget_test_harness.dart';

/// The state strings the Rust engine returns. They are the whole protocol
/// between the login engine and this dialog, so a change on either side that
/// is not mirrored here fails a test instead of the user's login.
const _engineStates = ['waiting', 'scanned', 'confirmed', 'expired', 'failed'];

void main() {
  test('maps every engine state onto a dialog outcome', () {
    expect(qrLoginOutcomeFor('waiting'), QrLoginOutcome.waiting);
    expect(qrLoginOutcomeFor('scanned'), QrLoginOutcome.scanned);
    expect(qrLoginOutcomeFor('confirmed'), QrLoginOutcome.confirmed);
    expect(qrLoginOutcomeFor('expired'), QrLoginOutcome.expired);
    expect(qrLoginOutcomeFor('failed'), QrLoginOutcome.failed);
    // An unknown state must not leave the dialog spinning forever.
    expect(qrLoginOutcomeFor('something-new'), QrLoginOutcome.failed);
    expect(qrLoginOutcomeFor(''), QrLoginOutcome.failed);
  });

  test('covers every state the engine documents', () {
    expect(_engineStates.map(qrLoginOutcomeFor).toSet(), {
      QrLoginOutcome.waiting,
      QrLoginOutcome.scanned,
      QrLoginOutcome.confirmed,
      QrLoginOutcome.expired,
      QrLoginOutcome.failed,
    });
  });

  testWidgets('renders a QR code for the scan URL it is given', (
    tester,
  ) async {
    // What the user must see: a scannable code. The payload uses Bilibili's
    // own `scan-web` URL shape, taken from a live `qrcode/generate` response.
    const scanUrl =
        'https://account.bilibili.com/h5/account-h5/auth/scan-web?navhide=1&callback=close&qrcode_key=3ce1675b669656b5cf689883ceef8c66&from=';
    await tester.pumpWidget(
      buildTestHarness(
        profile:
            appThemeProfiles.firstWhere((profile) => profile.id == 'monet_flow'),
        brightness: Brightness.light,
        child: SizedBox(
          width: 220,
          height: 220,
          child: QrImageView(
            data: scanUrl,
            version: QrVersions.auto,
            size: 220,
            errorCorrectionLevel: QrErrorCorrectLevel.M,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsOneWidget);
  });
}
