# Preparing version 0.0.1

All five packages start at 0.0.1. This checkout is a release candidate; nothing
has been published. Native database examples require database credentials. The
OpenAI API-key example requires OPENAI_API_KEY and OPENAI_MODEL; it is compiled
here, not run against a live API. Two prior native Responses smoke requests using
ChatGPT plan access are recorded separately and are not exhaustive acceptance.

## Verify

Run `dart pub get --offline`, `dart analyze`, and the package tests independently.
Run `dart test -p chrome` in core and effect_sql; in effect_openai select
`test/client_test.dart test/sdk_test.dart`. Use `dart run tool/check_fixtures.dart`
in the root for analyzer accept/reject fixtures. Run each file in `example/`.
`python3 tool/sql_integration.py` starts pinned PostgreSQL/MySQL containers, runs
the shared/native suites and both driver examples, then removes the containers.
Its temporary MySQL CA certificate validates the loopback hostname; the
PostgreSQL fixture deliberately uses plaintext loopback. Neither proves a
production network or production certificate deployment.

From a clean checkout, run `python3 tool/package_dry_run.py`. The runner exports
five standalone package directories, analyzes each one, and invokes
`dart pub publish --dry-run` for each.
Inspect the listed archive: pubspec, LICENSE, README, CHANGELOG and lib must be
present. Core excludes monorepo children and development/reference materials.
The standalone exports avoid root exclusions being inherited by nested packages. Overrides and lockfiles are
excluded from archives. Driver tests carry their contract helper locally rather
than importing a sibling package's test directory.

## Publication order (requires separate authorization)

1. effect_core 0.0.1
2. effect_sql 0.0.1
3. effect_postgres, effect_mysql and effect_openai 0.0.1

The dependent packages currently resolve the new versions with local overrides.
A dry-run hint about those overrides is expected before the dependencies are on
pub.dev. After each dependency is actually published, remove the overrides in an
isolated release checkout and rerun hosted dependency resolution, tests and the
dry run before publishing the next package. Do not bypass validation or treat a
local override as proof that hosted resolution works.

Production database failover/load/soak, broader live OpenAI endpoints and browser
live transport remain outside recorded acceptance. Retain those limits in the
package documentation. Publication ownership/name availability and server-side
checks are decided by pub.dev at publish time, not by a successful dry run.
