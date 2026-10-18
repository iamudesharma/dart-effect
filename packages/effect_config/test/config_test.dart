import 'package:effect_config/effect_config.dart';
import 'package:effect_core/effect_core.dart';
import 'package:test/test.dart';

void main() {
  test('defaults/fallback treat absence separately from invalid input', () {
    final fallback = ConfigProvider({'port': '80'});
    expect(Config.port('port').withDefault(99).load(ConfigProvider({})), 99);
    expect(Config.port('port').load(ConfigProvider({}).fallback(fallback)), 80);
    expect(
      () =>
          Config.port('port')
              .withDefault(99)
              .load(ConfigProvider({'port': 'bad'}).fallback(fallback)),
      throwsA(
        isA<ConfigError>().having(
          (e) => e.kind,
          'kind',
          ConfigErrorKind.invalid,
        ),
      ),
    );
    expect(
      () => Config.port('port').optional().load(ConfigProvider({'port': '0'})),
      throwsA(isA<ConfigError>()),
    );
  });
  test('typed values, nesting and provider snapshots are deterministic', () {
    final source = {'APP_PORT': '8080', 'APP_TLS': 'true', 'WAIT': '20ms'};
    final provider = ConfigProvider(source, separator: '_');
    source['APP_PORT'] = 'broken';
    expect(Config.port('APP.PORT').load(provider), 8080);
    expect(Config.boolean('TLS').nested('APP').load(provider), true);
    expect(
      Config.duration('WAIT').load(provider),
      const Duration(milliseconds: 20),
    );
    expect(
      Config.uri('URL')
          .load(ConfigProvider({'URL': 'https://example.com'}))
          .host,
      'example.com',
    );
  });
  test(
    'redaction and invalid-value diagnostics never format supplied secrets',
    () async {
      final secret = Config.secret('KEY')
          .load(ConfigProvider({'KEY': 'do-not-log'}));
      expect(secret.toString(), '<redacted>');
      expect(secret.reveal(), 'do-not-log');
      final rt = Runtime(ConfigProvider({'PORT': 'do-not-log'}));
      addTearDown(rt.shutdown);
      final result = await rt.runExit(Config.port('PORT').effect());
      final cause =
          (result as Failure<int, ConfigError>).cause as Expected<ConfigError>;
      expect(cause.error.toString(), isNot(contains('do-not-log')));
      expect(cause.error.path, 'PORT');
    },
  );
  test(
    'nested failures retain full path and oversized durations fail validation',
    () {
      expect(
        () =>
            Config.port('port')
                .nested('db')
                .load(ConfigProvider({'db.port': 'bad'})),
        throwsA(isA<ConfigError>().having((e) => e.path, 'path', 'db.port')),
      );
      expect(
        () =>
            Config.duration('wait')
                .load(ConfigProvider({'wait': '9007199254740991h'})),
        throwsA(isA<ConfigError>()),
      );
    },
  );
}
