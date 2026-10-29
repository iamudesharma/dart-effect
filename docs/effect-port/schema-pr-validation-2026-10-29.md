# Independent schema PR validation — 2026-10-29

The `codex/schema-flutter` branch starts from default-branch commit
`632c5239421e8378acd2d5c79f77eb8aac45aeeb`. It extracts only the unpublished
schema package, Flutter example and evidence from the broader toolkit checkout.
It contains no changes to core runtime behavior, existing SQL adapters or the
unrelated local SQL integration runner. The remaining toolkit stays in PR #13.

Fresh checks on this isolated branch:

| Check | Result |
| --- | --- |
| Root analyzer | No issues after resolving all existing package dependencies |
| Core VM regressions | 137 passed |
| Analyzer fixtures | 5 passed |
| Schema formatting/analyzer | Passed / no issues |
| Schema VM tests | 22 passed |
| Schema Chrome tests | 22 passed |
| Schema candidate with hosted dependencies | Analyzer, 22 tests and example passed; dry run zero warnings |
| Flutter formatting/analyzer | Passed / no issues |
| Flutter VM tests | 12 passed |
| Flutter Chrome tests | 12 passed |
| Flutter web release build | Passed |

The macOS build/smoke and performance/memory results remain the separately dated
October 28 and October 24 evidence; they were not rerun for this extraction.
The dedicated Schema quality workflow covers portable schema checks, the
isolated candidate dry run, Flutter tests and the web build. GitHub CI results
are reported on the PR rather than inferred from local checks.

The package remains `0.1.0-dev.1` and unpublished. The Flutter demo uses fixtures,
not a live backend. No iPad or other mobile-device acceptance is added. No
upstream/npm snapshot, Node source, generated JavaScript, credentials or build
output is part of this branch.
