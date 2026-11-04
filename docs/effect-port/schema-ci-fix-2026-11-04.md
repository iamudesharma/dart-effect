# Schema PR CI repair — 2026-11-04

PR #17 initially passed Schema quality but failed Cache quality during analysis.
The Cache workflow and its offline validation runner resolved only the existing
packages, leaving `effect_schema` without a package configuration for analysis.
Both prerequisite lists now include schema.

The Dart-only memory validation runner explicitly analyzes `lib`, `test`,
`example`, `tool` and `packages` with fatal infos. The Flutter example is analyzed
and tested in the separate Flutter SDK job in Schema quality. This keeps the
published core analyzer configuration unchanged without omitting package sources
from static analysis.

The root README and analyzer configuration are restored to their published
contents. Schema usage remains in the schema package and Flutter example READMEs
and toolkit documentation. Historical release fingerprints are unchanged.

## Local verification

- `python3 tool/validate_memory_fixes.py --report build/schema-ci-memory-validation.json`
  passes with source fingerprints unchanged: 269 VM/classification test executions
  and 245 Chrome test executions, analyzer fixtures, examples, web compilation,
  JIT/AOT probes, three post-GC probes and HTTP body retention checks.
- All five Dart analysis scopes pass. Fresh raw logs and the JSON report are local
  build outputs; CI uploads its corresponding validation artifacts.
- Website build and checks pass: routes, assets, anchors, search data, script
  syntax, published/draft boundaries and release evidence.
- All 61 recorded archive files match the hashes across seven released packages.

The repair changes CI setup and documentation only. It does not change runtime
behavior, publish packages, deploy the website or add live-provider/device
acceptance. CI results for the pushed commit are reported by GitHub on PR #17.
