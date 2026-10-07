import 'dart:io';
import 'dart:convert';

/// Analyze isolated accepted/rejected programs with the actual installed SDK.
Future<void> main() async {
  final temporary = Directory.systemTemp.createTempSync('blot_fixtures_');
  final configuration = File('.dart_tool/package_config.json');
  final packages =
      jsonDecode(configuration.readAsStringSync()) as Map<String, dynamic>;
  for (final package in packages['packages'] as List<dynamic>) {
    package['rootUri'] = configuration.absolute.uri
        .resolve(package['rootUri'] as String)
        .toString();
  }
  final fixtureConfiguration = File(
    '${temporary.path}/.dart_tool/package_config.json',
  );
  fixtureConfiguration.parent.createSync(recursive: true);
  fixtureConfiguration.writeAsStringSync(jsonEncode(packages));
  var failures = 0;
  try {
    for (final source in Directory(
      'test/fixtures',
    ).listSync().whereType<File>()) {
      final name = source.uri.pathSegments.last.replaceAll('.txt', '');
      final file = File('${temporary.path}/$name');
      file.writeAsStringSync(source.readAsStringSync());
      final result = await Process.run('dart', [
        'analyze',
        '--format=machine',
        file.path,
      ]);
      final output = '${result.stdout}\n${result.stderr}';
      final positive = name.startsWith('positive');
      final errors = output
          .split('\n')
          .where((line) => line.startsWith('ERROR|'))
          .toList();
      final expectedCodes = name.startsWith('error_mismatch')
          ? ['RETURN_OF_INVALID_TYPE_FROM_CLOSURE']
          : ['ARGUMENT_TYPE_NOT_ASSIGNABLE'];
      final passed = positive
          ? result.exitCode == 0
          : errors.any((line) => expectedCodes.any(line.contains));
      stdout.writeln('${passed ? "PASS" : "FAIL"} $name');
      if (!passed) {
        failures++;
        stdout.writeln(output);
      }
    }
  } finally {
    temporary.deleteSync(recursive: true);
  }
  if (failures > 0) exitCode = 1;
}
