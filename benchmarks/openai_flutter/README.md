# OpenAI native Flutter profile template

Run `python3 tool/openai_flutter_performance.py` from the repository root on
macOS with Flutter 3.47 / Dart 3.13, Xcode and cached dependencies installed.
This directory is a template, not a shipping app: the runner creates an ignored
macOS shell under build/, copies lib/main.dart and the shared Dart fixture/tool
into that shell, resolves dependencies offline, analyzes it and runs profile mode.
The generated shell disables app sandboxing solely to write local evidence.
There are no live credentials. Only runner-owned applications are launched.

The same small animated UI runs direct-SDK and Effect workloads for a fixed
six-second window, three runs each in alternating order. Faster implementations
may finish more batches: inspect operation counts together with frame metrics.
GC requests are outside recorded frame timing. Flutter FrameTiming reports build
and raster stages separately; the 16.67 ms threshold is a descriptive 60 Hz
reference, not proof of smoothness for every refresh rate or app.

Results are in docs/effect-port/openai-flutter-performance.json. Consult the
performance guide for exact results, warmups, retained-class counts, limitations
and the separate AOT comparison. No simulator or emulator is required; mobile,
browser and real application acceptance remain separate.
