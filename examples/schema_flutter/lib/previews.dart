import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import 'main.dart';

@Preview(
  name: 'Validated profile',
  group: 'Schema results',
  size: Size(400, 180),
)
Widget validProfilePreview() => const MaterialApp(
  home: Scaffold(
    body: ResultPanel(title: 'Validated User', lines: ['Name: Ada', 'ID: 42']),
  ),
);

@Preview(
  name: 'Field validation errors',
  group: 'Schema results',
  size: Size(400, 220),
)
Widget invalidProfilePreview() => const MaterialApp(
  home: Scaffold(
    body: ResultPanel(
      title: 'Invalid response',
      lines: [r'$.id: Expected integer', r'$.display_name: Expected string'],
    ),
  ),
);
