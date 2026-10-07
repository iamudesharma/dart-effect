# Effect Core project guidance

Portable standalone package, Dart >=3.13.0. Read
`docs/effect-port/architecture.md` first. The upstream/npm snapshot and Node
conformance tooling are local-only and deliberately ignored by Git. If that
optional pack exists, read references/effect/manifest.json and INDEX.md. References are
frozen: normal implementation and builds must remain offline; deliberate gaps
must be recorded and acquired explicitly. Refresh only on maintenance request.
Never mistake docs revision for source release revision.

Project skills: `.agents/skills/effect-reference/SKILL.md`,
`.agents/skills/dart-effect-runtime/SKILL.md`,
`.agents/skills/effect-conformance/SKILL.md`,
`.agents/skills/dart-package-quality/SKILL.md`.

Public runtime/types: lib/src/core.dart. Policy/context/layers: lib/src/services.dart.
Coordinate changes to shared public interfaces before parallel implementation.
Tests derive from lifecycle contracts, not implementation structure. Preserve
expected failure/defect/interruption distinctions, exactly-once masked cleanup,
child lifetimes, bounded concurrency, lazy re-execution and stack safety.

Checks: `dart format lib test example tool`, `dart analyze`, `dart test`,
`dart run tool/check_fixtures.dart`. Reference verification is optional and only
available with the local ignored snapshot. SQL acceptance: python3 tool/sql_integration.py.
Conformance and benchmarks use development tools only. Installed SDK/pub/Node
prerequisites are distinct from offline reference availability.

Completion: advertised operations run; failures and unrun platform acceptance
are recorded in progress/feature matrix. Current user scope is the reusable core,
PostgreSQL and MySQL adapters using established pub.dev drivers, plus the
user-selected openai_dart integration in packages/effect_openai. The full Node
package inventory is historical context, not a porting checklist. Native SQL
adapters live in packages/; keep driver dependencies/dart:io outside core lib/.
Read docs/effect-port/sql-adapters.md for transaction/cancellation contracts.
Use version dependencies plus local pubspec_overrides.yaml for development;
verify each package independently. OpenAI adapter contracts/tests:
docs/effect-port/openai-adapter.md. Keep live API acceptance distinct from local
HTTP/SSE fixtures; do not embed credentials or introduce Node sources. No package publication/deployment is authorized. The user authorized a private
GitHub repository and branch push; never stage upstream/npm or Node source.
