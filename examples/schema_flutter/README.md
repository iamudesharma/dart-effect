# effect_schema in Flutter

A runnable development example: fixture response → schema validation → typed
`User` → Flutter widget. It also validates a name form and encodes a model back
to JSON using the wire field `display_name`.

The app uses the local, unpublished `effect_schema` package and resolves
`effect_core` from pub.dev. There is no API key, live network request, artificial
sleep, generated model, generated form or generated schema. The asynchronous
fixture function is injectable so tests can control request ordering.

## Run

Requires a Flutter SDK containing Dart >=3.13.0. Verified with Flutter 3.47.0.
From this directory:

```sh
flutter pub get
flutter run -d macos
# Or:
flutter run -d chrome
```

Choose a response scenario, then select **Load response**. Inspect the validated
model or field paths. In the form, enter a name and select **Validate and encode**.
Changing the name clears the old encoded result.

## Where the behavior lives

- `lib/profile.dart`: reusable schemas, explicit `User` mapping, fixture source
  and `UserRepository`. The repository returns separate loaded/invalid/request
  failure results. Expected transport errors are handled before the next frame;
  they cannot become an unhandled future error while the widget is rebuilding.
- `lib/main.dart`: a normal stateful Flutter screen. It obtains futures outside
  `build`, reloads on repository replacement and lets `FutureBuilder` ignore stale
  completions. Its text controller is disposed with the screen.
- `lib/previews.dart`: interactive valid/invalid result previews using Flutter's
  built-in Widget Preview annotations. Run `flutter widget-preview start` to view.
- `test/widget_test.dart`: valid data, wrong types, missing fields, malformed JSON,
  transport failures and recovery, form errors/encoding, stale responses, late
  completion after unmount, repository replacement, rebuilds and narrow/large-text
  layout.

## Integrate a real backend

Replace `fetchFixture` with a function returning a successful HTTP response body.
Check HTTP status, impose a response-body limit and map transport errors in that
adapter. Do not store credentials in this client. The example's broad fixture
error mapping is intentionally small; a production service should expose its
specific network error family and log sanitized diagnostics.

`FutureBuilder` prevents a stale completion from updating the view; it does not
cancel underlying I/O. This demo owns no network client. A real client must own
and close its transport, and provide explicit cancellation when requests can
outlive a screen. `effect_core` and `effect_http` can provide those service
policies separately from the schema. Their use is not required for these pure
validation calls.

Schemas are built once and reused. Validation is synchronous. Depth/error limits
bound diagnostic traversal, not JSON parsing memory, valid output size or UI
frame time. Profile large payloads before deciding whether to move decoding to
an isolate. This example does not make device-performance or leak-freedom claims.

## Verify

```sh
flutter analyze
flutter test
flutter build web
flutter build macos
```

Widget tests and release builds are distinct from native/device acceptance.
No mobile simulator or iPad run is part of this example's validation.
