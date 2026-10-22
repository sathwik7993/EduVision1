import 'package:eduvision_0_1/models/scan_result.dart';
import 'package:eduvision_0_1/models/sheet_template.dart';
import 'package:eduvision_0_1/pages/review_page.dart';
import 'package:eduvision_0_1/services/roster_service.dart';
import 'package:eduvision_0_1/theme/app_theme.dart';
import 'package:eduvision_0_1/widgets/glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Rendering checks for the glass design system. These cannot replace running
/// on a device, but they do catch layout and theme errors that would otherwise
/// only show up as a red screen at runtime.
void main() {
  Widget host(Widget child) =>
      MaterialApp(theme: AppTheme.light(), home: child);

  testWidgets('GlassScaffold renders with an app bar and body', (tester) async {
    await tester.pumpWidget(
      host(const GlassScaffold(title: 'Test', body: Text('content'))),
    );
    await tester.pumpAndSettle();

    expect(find.text('Test'), findsOneWidget);
    expect(find.text('content'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('GlassCard fires its tap callback', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      host(
        Scaffold(
          body: Center(
            child: GlassCard(
              onTap: () => taps++,
              child: const Text('tap me'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('tap me'));
    await tester.pumpAndSettle();
    expect(taps, 1);
  });

  testWidgets('EntranceFade settles to fully visible', (tester) async {
    await tester.pumpWidget(
      host(const Scaffold(body: EntranceFade(index: 2, child: Text('hi')))),
    );
    await tester.pumpAndSettle();

    final opacity = tester.widget<Opacity>(
      find.ancestor(of: find.text('hi'), matching: find.byType(Opacity)).first,
    );
    expect(opacity.opacity, 1.0);
  });

  group('ReviewPage', () {
    /// The default 800x600 test surface is shorter than the review form, and
    /// ListView only builds what is visible -- so the total card below the fold
    /// would never be constructed.
    void useTallSurface(WidgetTester tester) {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    ScanResult result({double confidence = 0.95}) => ScanResult(
          registrationNo:
              ExtractedField(value: '21B01A0512', confidence: confidence),
          partA: ExtractedField(value: '30', confidence: confidence),
          partB: ExtractedField(value: '40', confidence: confidence),
          rawText: 'Registered No 21B01A0512',
        );

    testWidgets('shows the recognised values and the derived total',
        (tester) async {
      useTallSurface(tester);
      await tester.pumpWidget(
        host(
          ReviewPage(
            result: result(),
            engineName: 'Test engine',
            engineReadsHandwriting: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('21B01A0512'), findsOneWidget);
      // 30 + 40, computed rather than read off the page.
      expect(find.text('70'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('warns when the engine cannot read handwriting',
        (tester) async {
      await tester.pumpWidget(
        host(
          ReviewPage(
            result: result(),
            engineName: 'Test engine',
            engineReadsHandwriting: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('reads printed text only'),
        findsOneWidget,
      );
    });

    testWidgets('flags low-confidence fields for the teacher', (tester) async {
      await tester.pumpWidget(
        host(
          ReviewPage(
            result: result(confidence: 0.3),
            engineName: 'Test engine',
            engineReadsHandwriting: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Needs your check'), findsOneWidget);
      expect(find.textContaining('Low •'), findsWidgets);
    });

    testWidgets('editing a field recomputes the total', (tester) async {
      useTallSurface(tester);
      await tester.pumpWidget(
        host(
          ReviewPage(
            result: result(),
            engineName: 'Test engine',
            engineReadsHandwriting: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(1), '35');
      await tester.pumpAndSettle();

      expect(find.text('75'), findsOneWidget);
    });

    testWidgets('a disagreeing written total blocks until checked',
        (tester) async {
      useTallSurface(tester);
      const template = SheetTemplate(partAMax: 40, partBMax: 80);
      await tester.pumpWidget(
        host(
          ReviewPage(
            result: ScanResult(
              registrationNo:
                  const ExtractedField(value: '23H53A66D9', confidence: 0.95),
              partA: const ExtractedField(value: '40', confidence: 0.95),
              partB: const ExtractedField(value: '80', confidence: 0.95),
              writtenTotals: const [
                LabelledMark(
                  label: 'Total in words',
                  part: '',
                  field: ExtractedField(value: '30', confidence: 0.95),
                ),
              ],
            ),
            engineName: 'Test engine',
            engineReadsHandwriting: true,
            template: template,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Needs your check'), findsOneWidget);
      expect(find.textContaining('but Part-A + Part-B = 120'), findsOneWidget);
      // Part-B 80 is within this template's maximum, so only one flag.
      expect(find.text('Matches the sheet'), findsOneWidget);

      // Fixing the arithmetic upstream clears the conflict live.
      await tester.enterText(find.byType(TextField).at(1), '10');
      await tester.enterText(find.byType(TextField).at(2), '20');
      await tester.pumpAndSettle();
      expect(find.text('Read with high confidence'), findsOneWidget);
      expect(find.text('30'), findsWidgets);
    });

    testWidgets('offers the roster suggestion for an unknown number',
        (tester) async {
      useTallSurface(tester);
      await tester.pumpWidget(
        host(
          ReviewPage(
            result: result(),
            engineName: 'Test engine',
            engineReadsHandwriting: true,
            roster: Roster(['21B01A0513']),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Not on the class roster'), findsOneWidget);
      await tester.tap(find.text('Use 21B01A0513'));
      await tester.pumpAndSettle();
      expect(find.text('21B01A0513'), findsOneWidget);
      expect(find.text('Entered by you'), findsOneWidget);
    });
  });
}
