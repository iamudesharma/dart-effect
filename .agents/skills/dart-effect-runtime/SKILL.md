---
name: dart-effect-runtime
description: Implement or review Blot lazy effects and fiber/resource lifecycles.
---

# dart-effect-runtime

Inputs: docs/effect-port/architecture.md and pinned evidence from references/effect/INDEX.md. Use explicit R aggregates and sealed E families; preserve typed recovery boundaries. Read lib/src/core.dart. Check trampoline fairness, async cancellation hooks, late completions, masked acquisition and cleanup, children and shutdown. Run dart analyze and dart test test/runtime_test.dart. Output working APIs, lifecycle tests and divergences; no implicit claim that Future interruption cancels underlying I/O.

References resolve from the repository root; material stays in references/effect, outside this skill.

The upstream reference pack and Node comparison tooling are local-only and Git-ignored
by user instruction. If absent in a clone, use the committed architecture/contracts
and Dart tests; report exact reference gaps and never fetch automatically.
