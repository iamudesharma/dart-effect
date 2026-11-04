import 'package:effect_schema/effect_schema.dart';
import 'package:flutter/material.dart';

import 'profile.dart';

void main() => runApp(const SchemaDemo());

class SchemaDemo extends StatelessWidget {
  const SchemaDemo({
    super.key,
    this.repository = const UserRepository(fetchFixture),
  });
  final UserRepository repository;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Schema in Flutter',
    theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
    home: ProfilePage(repository: repository),
  );
}

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key, required this.repository});
  final UserRepository repository;
  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late Future<ProfileResult> _request;
  String _selected = 'Valid profile';
  String _loaded = 'Valid profile';
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController(text: 'Ada');
  String? _encoded;

  @override
  void initState() {
    super.initState();
    _request = widget.repository.load(_loaded);
  }

  @override
  void didUpdateWidget(covariant ProfilePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) {
      _request = widget.repository.load(_loaded);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _load() => setState(() {
    _loaded = _selected;
    _request = widget.repository.load(_loaded);
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Schema in Flutter')),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'JSON → validation → User → widget',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Local fixtures only. No API key, network request or artificial delay.',
                ),
                const SizedBox(height: 24),
                DropdownButtonFormField<String>(
                  initialValue: _selected,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Response scenario',
                    border: OutlineInputBorder(),
                  ),
                  items: [...fixtures.keys, 'Request failure']
                      .map(
                        (name) =>
                            DropdownMenuItem(value: name, child: Text(name)),
                      )
                      .toList(),
                  onChanged: (value) => setState(() => _selected = value!),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    key: const Key('load'),
                    onPressed: _load,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Load response'),
                  ),
                ),
                const SizedBox(height: 16),
                const Text('Response body'),
                SelectableText(
                  fixtures[_loaded] ??
                      'Transport failed before a body was received.',
                ),
                const SizedBox(height: 16),
                FutureBuilder<ProfileResult>(
                  future: _request,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return Semantics(
                        label: 'Loading profile',
                        child: const LinearProgressIndicator(),
                      );
                    }
                    if (snapshot.hasError) {
                      return const ResultPanel(
                        title: 'Request failed',
                        lines: ['The response could not be loaded. Try again.'],
                      );
                    }
                    return switch (snapshot.requireData) {
                      ProfileRequestFailed() => const ResultPanel(
                        title: 'Request failed',
                        lines: ['The response could not be loaded. Try again.'],
                      ),
                      ProfileLoaded(user: final value) => ResultPanel(
                        title: 'Validated User',
                        lines: ['Name: ${value.name}', 'ID: ${value.id}'],
                      ),
                      ProfileInvalid(:final error) => ResultPanel(
                        title: 'Invalid response',
                        lines: error.issues
                            .map((issue) => issue.toString())
                            .toList(),
                      ),
                    };
                  },
                ),
                const SizedBox(height: 32),
                Text(
                  'Validate a form and encode JSON',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Form(
                  key: _form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextFormField(
                        key: const Key('name'),
                        controller: _name,
                        decoration: const InputDecoration(
                          labelText: 'Display name',
                          border: OutlineInputBorder(),
                        ),
                        validator: (text) => switch (nameSchema.decode(
                          text ?? '',
                        )) {
                          Valid() => null,
                          Invalid(:final error) => error.issues.first.message,
                        },
                        onChanged: (_) => setState(() => _encoded = null),
                      ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton(
                          key: const Key('encode'),
                          onPressed: () {
                            if (!_form.currentState!.validate()) return;
                            final encoded =
                                userJsonSchema
                                        .encode(User(id: 42, name: _name.text))
                                        .orThrow
                                    as String;
                            setState(() => _encoded = encoded);
                          },
                          child: const Text('Validate and encode'),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_encoded != null) ...[
                  const SizedBox(height: 12),
                  ResultPanel(title: 'Outgoing JSON', lines: [_encoded!]),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class ResultPanel extends StatelessWidget {
  const ResultPanel({super.key, required this.title, required this.lines});
  final String title;
  final List<String> lines;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    label: [title, ...lines].join('\n'),
    excludeSemantics: true,
    child: Card.filled(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final line in lines) SelectableText(line),
          ],
        ),
      ),
    ),
  );
}
