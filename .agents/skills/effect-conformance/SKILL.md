---
name: effect-conformance
description: Derive independent lifecycle and type conformance scenarios for Blot.
---

# effect-conformance

Read architecture contract tables and exact upstream tests from references/effect/INDEX.md. Derive externally observable scenarios with controlled completers, TestClock and seeded randomness. Compare normalized outcomes and finalizer traces using tool/conformance tooling. Run dart test and dart run tool/check_fixtures.dart. Report passed scenarios, defects, intentional differences and untested contracts separately. Node remains a development prerequisite only.

References resolve from the repository root; material stays in references/effect, outside this skill.

The upstream reference pack and Node comparison tooling are local-only and Git-ignored
by user instruction. If absent in a clone, use the committed architecture/contracts
and Dart tests; report exact reference gaps and never fetch automatically.
