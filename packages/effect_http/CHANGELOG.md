## 0.0.2 — 2026-10-21

Store immutable response bodies in packed bytes. Bound active requests and SSE sessions (32 by default) and aggregate response accumulation (32 MiB by default); retain admission until actual I/O settles.

## 0.0.1

Initial optional HTTP and bounded SSE adapter, with request abortion and typed failures.
