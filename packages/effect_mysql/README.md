# effect_mysql

MySQL effects for Dart API services. Uses package:mysql_client_plus. MySQL ? placeholders bind binary prepared statements. TLS certificates are rejected by default when untrusted.

Independent Effect-inspired development package, version 0.0.1.
No publication or full upstream SQL-module parity is claimed.

Execute with SqlClient.execute, compose with Effect map/flatMap, and inspect
Runtime.runExit for typed failures. SqlClient.transaction supplies an exclusive
SqlSession; nested transactions use savepoints. Keep the callback's own session,
which expires when the callback finishes. Own the pool for the application
lifetime and await Runtime.shutdown before SqlClient.shutdown.

Public dependency versions resolve to local packages via pubspec_overrides.yaml
for this repository. Another local app must override effect_core and effect_sql
until those dependencies are published.

See example/main.dart for driver configuration and Layer/Context usage.

The repository documentation at docs/effect-port/sql-adapters.md records
API usage, parameter binding, TLS, cancellation, detailed test cases and driver
selection evidence. Root tool/sql_integration.py executes isolated real
PostgreSQL/MySQL suites and always tears down its own containers.

MySQL interruption drains the pending command before rollback/reuse; it
can wait for that query to finish.
