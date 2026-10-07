# OpenAI SDK Effect adapter

`packages/effect_openai` integrates the user-selected
[openai_dart](https://pub.dev/packages/openai_dart) SDK. The [package registry](https://pub.dev/api/packages/openai_dart)
reported 10.0.1 on 7 October 2026, published 4 October 2026. Its public dependency
is ^10.0.1; the lockfile fixes the tested source. This SDK is a third-party Dart
client. No npm sources, generated Node inventories or vendor SDK source are copied.
The core runtime has no new dependencies or platform imports.

## API and ownership contract

| Surface | Implementation / proof boundary |
| --- | --- |
| Responses | create, retrieve, explicit background cancel, typed SSE streaming |
| Chat Completions | create and typed SSE streaming |
| Embeddings / moderation | typed request/response helpers |
| Other HTTP endpoints | request<A, R> invokes the SDK Future endpoint; stream<A, R> invokes its Stream endpoint |
| Tools and structured output | SDK request options, response objects and events pass through; no automatic tool execution |
| Resources | lazy effects; fresh per-run/per-consumption abort; optional owned SDK; fresh Layer per scope |
| Errors | typed SDK exceptions, original diagnostic cause and API metadata; abort is interruption; programmer errors are defects |
| Policy | no adapter retries; SDK policy is explicit configuration; Effect schedules compose normally |
| Realtime / pagination | no session transport, WebRTC/socket lifecycle or pagination collector is advertised |

The direct constructor borrows an SDK client by default. `create(config)` owns a
new one; `layer(key, factory)` owns a fresh one per layer construction scope.
SDK-close remains exactly once at adapter shutdown, including after scope defects.
An SDK with an injected HTTP client still borrows that HTTP client according to
its own ownership contract; the application's owner must close that transport.
Await Runtime.shutdown before adapter.shutdown during application teardown.

A generic callback must forward the per-run abort future to an SDK abort parameter.
Cancellation signals it and awaits request completion or stream cancellation.
Callbacks/endpoints that cannot abort are drained and may delay finalization until
their timeout/completion. Concurrent runs have independent cancellation signals.
Shutdown rejects future work, signals all active operations before awaiting them,
and closes the owned SDK. No global client is allocated during import/composition.

Streams use a scoped operation and a pause/resume bridge. Cancellation signals
abort *before* cancelling the SDK subscription, so it also terminates requests
blocked before headers. The SDK can reject subscription.cancel with its own
AbortedException in this state; this requested abort is normalized rather than
appended as a cleanup defect. Other cancellation errors remain defects. Manual
adapter shutdown interrupts a paused consumer rather than returning truncated
success. Native/SDK buffers remain subject to their own behavior; the adapter does
not claim a hard upstream memory bound. Sink.collect explicitly retains values.

Local HTTP interruption is distinct from server-side cancellation. OpenAI documents
that [explicit response cancellation](https://developers.openai.com/api/reference/resources/responses/methods/cancel)
requires a background response. `cancelResponse` exposes that operation. HTTP abort
alone does not prove remote generation stopped or prevent billing. Streaming events
follow the SDK's parser for [SSE responses](https://developers.openai.com/api/docs/guides/streaming-responses).
The adapter keeps response statuses and terminal failed/incomplete events as typed
SDK values; callers must inspect those outcomes, refusals and tool calls.

Typed failure families include authentication, permission, not-found, invalid
request, conflict, rate limit, server, timeout, connection, SDK parsing, other API,
and closed service. Status, request ID, native code and retry-after metadata remain
available when the SDK supplies them. Summary strings omit arbitrary messages and
metadata; raw causes and metadata require deliberate handling. Exceptions outside
the SDK's exception hierarchy remain defects, including malformed-wire exceptions
which the SDK does not wrap. Effect.catchAll/retry cannot recover those defects.

## Independent detailed test cases

Tests assert observable lifetimes, outbound HTTP requests and received events,
rather than the adapter's private data structures. SDK mocks exercise the actual
10.0.1 SDK with a synthetic HTTP transport. VM socket tests run an isolated Dart
HttpServer on a random loopback port and use the default SDK HTTP clients. They
require neither Node, Docker, a secret nor a paid API call.

| Cases | Given / action / expected result |
| --- | --- |
| AI01–AI03 | Construct but do not run; run twice and concurrently; observe no eager work, independent abort futures, sibling survives cancellation |
| AI04–AI06 | Timeout/abort or programmer exception; observe awaited abort cleanup, Interrupted outside typed recovery, defect without retry |
| AI07 (three families) / AI08 | Inject SDK timeout/network/parse/rate-limit errors; retain diagnostic identity, retry-after/code/ID, omit secret text from summary |
| AI09–AI12 | Shutdown active request, borrow client, use layer twice, shutdown twice; reject new work, preserve borrowed SDK, fresh scoped allocation and exactly-once owned close |
| AI13–AI16 | Consume reusable stream, take zero/one, interrupt before first value; no eager open, stable order, no open for zero demand, abort before awaited cancel |
| AI17–AI19 | Stream SDK error or defect; synchronous factory failure; shutdown while sink paused; retain failure boundary, finish ownership and interrupt truncated stream |
| AI20–AI23 | Finish parent with live child, delayed stream cancellation, closed stream, layer defect; await child before SDK close, await cancellation acknowledgement, reject opening, expire retained handle |
| WIRE01–WIRE06 | Send Responses/chat/embedding/moderation/retrieve/cancel/models calls through the actual SDK; inspect route/method, auth, Unicode input, typed content/vector/usage and generic endpoint return type |
| WIRE07 (ten statuses) | Return 400/401/403/404/409/422/429/500/503/418; assert error family/status/original SDK exception, retry-after for 429, no hidden adapter retry |
| WIRE08 | First HTTP request fails transiently, explicit one-recurrence Effect retry; second request succeeds, exactly two outbound calls |
| HTTP01–HTTP02 | Actual socket JSON/auth and request interruption before headers; typed output, aborted socket closes, reused client remains usable |
| HTTP03–HTTP04 | Split SSE UTF-8 into three-byte writes, then stop after first event on a persistent connection; reconstruct Unicode/sequence order and close real stream socket |
| HTTP05–HTTP08 | Cancel before first stream headers, consume Chat SSE, get stream HTTP 401 then reuse client, runtime shutdown; observe Interrupted/typed deltas/auth error and actual socket termination |

Run from packages/effect_openai:

```sh
dart analyze
dart test -r expanded
dart test -p chrome test/client_test.dart test/sdk_test.dart
dart run example/main.dart
dart compile js example/main.dart -o ../../build/openai-example.js
dart compile exe example/live.dart -o ../../build/openai-live-example
```

The credential-free example uses Layer/Context and an actual SDK with a synthetic
HTTP response. The live example reads OPENAI_API_KEY and OPENAI_MODEL only at runtime,
uses one Responses request, disables SDK retries and stored responses, and limits
requested output. Its compilation is not live-service acceptance. No live OpenAI
request has been run for this change. API access, real model output, production
TLS/proxy behavior, browser live transport, load/soak and every generic endpoint
remain separate acceptance checks. See openai-validation.json for executed results.
