import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segmeris/src/app/app_theme.dart';
import 'package:segmeris/src/home/home_series_card.dart';
import 'package:segmeris/src/rust/api/downloader.dart';

import '../widget_test_harness.dart';

void main() {
  const collection = MediaCollection(
    kind: 'pgc_season',
    title: 'Fixture Season',
    entries: [
      MediaCollectionEntry(
        id: 'ep:1',
        index: 1,
        title: '第1话 启程',
        durationSeconds: 1440,
        pageUrl: 'https://www.bilibili.com/bangumi/play/ep1',
        available: true,
        unavailableReason: '',
        current: true,
      ),
      MediaCollectionEntry(
        id: 'ep:2',
        index: 2,
        title: '第2话 风暴',
        durationSeconds: 1500,
        pageUrl: 'https://www.bilibili.com/bangumi/play/ep2',
        available: true,
        unavailableReason: '会员',
        current: false,
      ),
      MediaCollectionEntry(
        id: 'ep:3',
        index: 3,
        title: '第3话 归航',
        durationSeconds: 0,
        pageUrl: '',
        available: false,
        unavailableReason: '',
        current: false,
      ),
    ],
  );

  testWidgets('lists episodes and reports selection and download-all', (
    tester,
  ) async {
    MediaCollectionEntry? tappedEntry;
    var downloadAllPressed = false;

    await tester.pumpWidget(
      buildTestHarness(
        profile: appThemeProfiles
            .firstWhere((profile) => profile.id == 'monet_flow'),
        brightness: Brightness.light,
        child: HomeSeriesCard(
          collection: collection,
          running: false,
          analyzing: false,
          onEntrySelected: (entry) => tappedEntry = entry,
          onDownloadAll: () => downloadAllPressed = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Header: localized kind + title + episode count.
    expect(find.text('Bangumi'), findsOneWidget);
    expect(find.text('Fixture Season · 3 episodes'), findsOneWidget);
    // The current episode is shown in the header and highlighted in the
    // list; the membership badge travels along as secondary text.
    expect(find.text('第1话 启程'), findsNWidgets(2));
    expect(find.text('第2话 风暴'), findsOneWidget);
    expect(find.text('会员'), findsOneWidget);
    expect(find.text('24:00'), findsOneWidget);

    await tester.tap(find.text('第2话 风暴'));
    await tester.pumpAndSettle();
    expect(tappedEntry?.id, 'ep:2');

    // Only the two episodes with a usable page URL are counted.
    expect(find.text('Download all (2)'), findsOneWidget);
    await tester.tap(find.text('Download all (2)'));
    await tester.pumpAndSettle();
    expect(downloadAllPressed, isTrue);
  });

  testWidgets('disables every action while a download is running', (
    tester,
  ) async {
    var downloads = 0;
    var selections = 0;

    await tester.pumpWidget(
      buildTestHarness(
        profile: appThemeProfiles
            .firstWhere((profile) => profile.id == 'monet_flow'),
        brightness: Brightness.light,
        child: HomeSeriesCard(
          collection: collection,
          running: true,
          analyzing: false,
          onEntrySelected: (_) => selections += 1,
          onDownloadAll: () => downloads += 1,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('第2话 风暴'));
    await tester.pumpAndSettle();
    expect(selections, 0);

    final button = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Download all (2)'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(button.onPressed, isNull);
    expect(downloads, 0);
  });
}
