# Sequential acceptance plan

Updated 9 October 2026. Work proceeds one task at a time. Complete the tests and
record their evidence before moving the task to Delivered. A parent milestone
stays In progress until all its acceptance tasks pass; publication and package
scores do not close that gate.

## Priority 1 — production SQL acceptance: in progress

| Order | Task | Status | Completion criteria |
| --- | --- | --- | --- |
| SQL-P1 | Trusted CA chains and hostname verification | Delivered | Both real drivers accept an isolated root/intermediate chain; prove encryption and prepared query round trips; reject an unrelated root and wrong hostname; leave no idle leases or test containers. |
| SQL-P2 | Connection loss and pool recovery | Next | Terminate an owned test connection during an actual transaction; retain the failed outcome, prove no partial write, discard the lease, and run a fresh query. Do not replay writes or claim automatic cluster failover. |
| SQL-P3 | Bounded network interruption | Planned | Introduce an isolated proxy fault during a query and acquisition. Record timeout/interruption behavior and awaited cleanup for both drivers, including MySQL's drain limitation and restoration recovery. |
| SQL-P4 | Bounded load and soak | Planned | Run a declared duration/workload at the configured connection bound. Record completed/failed operations, peak leases, latency distribution and final shutdown; preserve transaction invariants and exclude unbounded stress claims. |
| SQL-P5 | Database version matrix | Planned | Repeat relevant acceptance against explicitly selected, locally installed pinned versions; document each executed version and unsupported/unrun cells. Acquire missing images explicitly rather than silently pulling during offline runs. |
| SQL-P6 | SQL acceptance review | Planned | Run existing real database contracts and new acceptance together, inspect cleanup and evidence, then list remaining deployment-specific gates. Production CA providers and real HA topologies need their own acceptance. |

### SQL-P1 result

Run `python3 tool/sql_tls_acceptance.py` from the repository root. Prerequisites:
Dart/package dependencies installed, Docker running, OpenSSL installed, and the
two pinned database images already present. The runner never downloads images.
It generates a temporary root, intermediate and server chain, plus an unrelated
root and a separately signed server with the wrong hostname. No certificate
bypass or leaf-pinning callback is supplied to either adapter.

PostgreSQL uses `SslMode.verifyFull`; MySQL supplies a trusted `SecurityContext`
and retains the adapter's rejecting certificate callback. Each driver executes:

| Scenario | Expected observable result |
| --- | --- |
| TLS01 | Authenticate through the root/intermediate chain, confirm the database reports an encrypted session, round-trip bound Unicode/text, and close the pool. |
| TLS02 | Trust an unrelated root; connection acquisition produces expected `SqlFailureKind.connection`, with no reusable idle lease. |
| TLS03 | Trust the correct root but connect to a server whose certificate names another host; produce the same typed rejection and pool cleanup. |

**Executed: 3 PostgreSQL + 3 MySQL checks passed, zero skips and failures.** All
four runner-owned containers were removed. Fixture certificates and private keys
were temporary and deleted. The evidence is
[sql-tls-validation.json](sql-tls-validation.json); raw local test output is
under ignored `build/`. Tests skip if explicitly configured TLS endpoints and CA
files are absent; skipped runs never count as acceptance.

This proves isolated CA-chain and hostname behavior, not acceptance of a real
production CA provider, expired certificates, rotation/revocation, network
partitions, a database HA cluster, or long-running soak. Those gaps remain open.
The frozen upstream tests provide the container-backed testing approach; these
TLS scenarios derive from the Dart driver's security boundary rather than copying
Node protocol internals. No upstream reference refresh was performed.

## Priority 2 — broader live OpenAI acceptance: awaiting input

An API-enabled test account is required. A ChatGPT subscription is not general
API access. Keep existing local HTTP/SSE fixtures and historical Responses smoke
evidence separate from endpoint-specific live proof. Once access is available,
check supported request endpoints, streaming cancellation and failures, safe
backend-mediated browser transport, then bounded load/soak. Never commit a key.

## Priority 3 — runnable API and Flutter guides: planned

Start with a server example owning one runtime and shared SQL/AI service layers.
Verify safe read retry and unreplayed writes, owner shutdown, transaction failure,
and interruption. Follow with a Flutter consumer of the server and explicit
async owner closure. Verify on an allowed native target; compilation alone does
not prove device lifecycle behavior. This priority can proceed while live AI
acceptance awaits access.

## Later proposals

Configuration/schema/cache, stream operators, metrics/tracing, and Flutter/isolate
helpers remain proposals. Choose one API and its lifecycle contracts before
implementation. The complete Node inventory is outside the committed plan.
