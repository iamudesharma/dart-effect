import 'dart:async';

import 'package:effect_schema/effect_schema.dart';
import 'package:effect_schema_flutter/main.dart';
import 'package:effect_schema_flutter/profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> choose(WidgetTester tester, String name) async {
  await tester.tap(find.byType(DropdownButtonFormField<String>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('load')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('validation details are exposed to assistive technology', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(const SchemaDemo());
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel('Validated User\nName: Ada\nID: 42'),
        findsOneWidget,
      );
      await choose(tester, 'Wrong field types');
      expect(
        find.bySemanticsLabel(
          'Invalid response\n'
          r'$.id: Expected integer'
          '\n'
          r'$.display_name: Expected string',
        ),
        findsOneWidget,
      );
    } finally {
      semantics.dispose();
    }
  });

  test('model round trip uses wire names and ignores unrelated fields', () {
    final user = userJsonSchema.decode(fixtures['Valid profile']).orThrow;
    expect(user.name, 'Ada');
    expect(
      userJsonSchema.encode(user).orThrow,
      '{"id":42,"display_name":"Ada"}',
    );
    expect(
      userJsonSchema.decode('{"id":0,"display_name":"A"}'),
      isA<Invalid<User>>(),
    );
  });

  testWidgets('loads once, renders typed profile, rebuilds do not refetch', (
    tester,
  ) async {
    var calls = 0;
    final repository = UserRepository((_) async {
      calls++;
      return fixtures['Valid profile']!;
    });
    await tester.pumpWidget(SchemaDemo(repository: repository));
    await tester.pumpAndSettle();
    expect(find.text('Name: Ada'), findsOneWidget);
    await tester.pumpWidget(SchemaDemo(repository: repository));
    await tester.pumpAndSettle();
    expect(calls, 1);
  });

  for (final scenario in {
    'Wrong field types': [
      r'$.id: Expected integer',
      r'$.display_name: Expected string',
    ],
    'Missing name': [r'$.display_name: Missing field'],
    'Malformed JSON': [r'$: Invalid JSON'],
  }.entries) {
    testWidgets('shows validation paths for ${scenario.key}', (tester) async {
      await tester.pumpWidget(const SchemaDemo());
      await tester.pumpAndSettle();
      await choose(tester, scenario.key);
      expect(find.text('Invalid response'), findsOneWidget);
      for (final line in scenario.value) {
        expect(find.text(line), findsOneWidget);
      }
      expect(find.text('Name: Ada'), findsNothing);
    });
  }

  testWidgets('transport failures stay separate and recovery works', (
    tester,
  ) async {
    await tester.pumpWidget(const SchemaDemo());
    await tester.pumpAndSettle();
    await choose(tester, 'Request failure');
    expect(find.text('Request failed'), findsOneWidget);
    expect(find.text('Invalid response'), findsNothing);
    await choose(tester, 'Valid profile');
    expect(find.text('Name: Ada'), findsOneWidget);
  });

  testWidgets('form rejects invalid values, encodes and clears stale output', (
    tester,
  ) async {
    await tester.pumpWidget(const SchemaDemo());
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('name')));
    await tester.enterText(find.byKey(const Key('name')), ' ');
    await tester.ensureVisible(find.byKey(const Key('encode')));
    await tester.tap(find.byKey(const Key('encode')));
    await tester.pumpAndSettle();
    expect(find.text('Enter at least two characters'), findsOneWidget);
    expect(find.text('Outgoing JSON'), findsNothing);
    await tester.enterText(find.byKey(const Key('name')), 'Grace');
    await tester.tap(find.byKey(const Key('encode')));
    await tester.pumpAndSettle();
    expect(find.text('{"id":42,"display_name":"Grace"}'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('name')), 'G');
    await tester.pump();
    expect(find.text('Outgoing JSON'), findsNothing);
  });

  testWidgets('stale completions cannot replace the newer response', (
    tester,
  ) async {
    final first = Completer<String>();
    final second = Completer<String>();
    var calls = 0;
    await tester.pumpWidget(
      SchemaDemo(
        repository: UserRepository(
          (_) => ++calls == 1 ? first.future : second.future,
        ),
      ),
    );
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.tap(find.byKey(const Key('load')));
    await tester.pump();
    second.complete('{"id":2,"display_name":"Grace"}');
    await tester.pumpAndSettle();
    first.complete(fixtures['Wrong field types']);
    await tester.pumpAndSettle();
    expect(find.text('Name: Grace'), findsOneWidget);
    expect(find.text('Invalid response'), findsNothing);
  });

  testWidgets('late failure after unmount does not update disposed state', (
    tester,
  ) async {
    final response = Completer<String>();
    await tester.pumpWidget(
      SchemaDemo(repository: UserRepository((_) => response.future)),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    response.completeError(StateError('late transport failure'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('replacing repository reloads from the new owner', (
    tester,
  ) async {
    await tester.pumpWidget(const SchemaDemo());
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      SchemaDemo(
        repository: UserRepository(
          (_) async => '{"id":3,"display_name":"Lin"}',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Name: Lin'), findsOneWidget);
  });

  testWidgets('narrow layout and large text stay scrollable without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const ProfilePage(repository: UserRepository(fetchFixture)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('encode')));
    expect(tester.takeException(), isNull);
  });
}
