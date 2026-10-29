import 'package:effect_schema/effect_schema.dart';

final class User {
  const User({required this.id, required this.name});
  final int id;
  final String name;
}

final nameSchema = Schema.string.refine(
  (name) => name.trim().length >= 2,
  'Enter at least two characters',
);

final userSchema =
    Schema.object({
      'id': Field(Schema.integer.refine((id) => id > 0, 'ID must be positive')),
      'name': Field(nameSchema, wireName: 'display_name'),
    }, unknown: UnknownFields.strip).transform<User>(
      (data) => User(id: data['id'] as int, name: data['name'] as String),
      (user) => {'id': user.id, 'name': user.name},
    );
final userJsonSchema = userSchema.json();

sealed class ProfileResult {
  const ProfileResult();
}

final class ProfileLoaded extends ProfileResult {
  const ProfileLoaded(this.user);
  final User user;
}

final class ProfileInvalid extends ProfileResult {
  const ProfileInvalid(this.error);
  final SchemaError error;
}

final class ProfileRequestFailed extends ProfileResult {
  const ProfileRequestFailed();
}

/// Pure schema example: no runtime, sockets, timers or owned resources.
/// A real transport should check status codes and bound response bytes first.
final class UserRepository {
  const UserRepository(this.fetchJson);
  final Future<String> Function(String scenario) fetchJson;

  Future<ProfileResult> load(String scenario) async {
    final String body;
    try {
      body = await fetchJson(scenario);
    } on Object {
      // Handle transport errors immediately, including before the next UI frame.
      // Use your HTTP adapter's typed error mapping in a real application.
      return const ProfileRequestFailed();
    }
    return switch (userJsonSchema.decode(body)) {
      Valid(:final value) => ProfileLoaded(value),
      Invalid(:final error) => ProfileInvalid(error),
    };
  }
}

const fixtures = <String, String>{
  'Valid profile': '{"id":42,"display_name":"Ada","extra":"ignored"}',
  'Wrong field types': '{"id":"wrong","display_name":false}',
  'Missing name': '{"id":42}',
  'Malformed JSON': '{"id":',
};

Future<String> fetchFixture(String scenario) async {
  if (scenario == 'Request failure') {
    throw const FormatException('Fixture transport failure');
  }
  return fixtures[scenario]!;
}
