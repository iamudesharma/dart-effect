# effect_flutter

Unpublished development package (`0.1.0-dev.1`) for Flutter owners and idiomatic `ValueListenableBuilder` bindings. Core runtime remains Flutter-independent.

```yaml
dependencies:
  effect_flutter:
    path: /path/to/effect_dart/packages/effect_flutter
dependency_overrides:
  effect_core:
    path: /path/to/effect_dart
```

```dart
final controller = EffectController<User, ApiError, Services>(services);
final exit = await controller.run(loadUser);
// Render controller.value using ValueListenableBuilder<EffectState<User, ApiError>>.
await controller.close(); // Await protected cleanup at the owner boundary.
controller.dispose();
```

States distinguish idle, loading, data, failed Cause and cancellation. Latest invocation owns the visible state. A replacement interrupts and awaits its predecessor before starting. The controller owns its runtime. Widgets see idiomatic state, without backend credentials or SQL drivers.

Flutter's synchronous `dispose()` initiates close and prevents subsequent notifications; it cannot await cleanup. Call `await close()` explicitly where asynchronous shutdown must be guaranteed before navigation or owner destruction.

Run `flutter analyze` and `flutter test`. The widget test renders a real `ValueListenableBuilder` in Flutter's test engine; it is not Android/iOS device acceptance. Riverpod/BLoC integrations, EffectStream bindings and persistence remain future extensions.
