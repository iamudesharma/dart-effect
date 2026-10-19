# effect_http

Optional HTTP and SSE support for Effect Dart, using Dart's `http` package.
Version `0.0.1` integrates with `effect_core 0.0.2`.

```yaml
dependencies:
  effect_core: ^0.0.2
  effect_http: ^0.0.1
```

```dart
import 'package:effect_core/effect_core.dart';
import 'package:effect_http/effect_http.dart';
import 'package:http/http.dart' as http;

final client = http.Client();
final runtime = Runtime(Unit.value);
try {
  final adapter = EffectHttp(client);
  final response = await runtime.runFuture(
    adapter.request<Unit>('GET', Uri.parse('https://example.com')),
  );
  print(response.text);
} finally {
  await runtime.shutdown();
  client.close();
}
```

The adapter borrows the client; the caller closes it after stopping its runtime.
Each effect execution and stream consumption creates a fresh `AbortableRequest`.
IOClient and BrowserClient support abortion; custom clients must implement that contract.
Requests and streams never retry automatically. Status, transport, UTF8 and size-limit
failures become `HttpFailure`; cancellation remains `Interrupted`.

```dart
final stream = EffectHttp(client).sse<Unit>(Uri.parse('https://example.com/events'));
final first = await runtime.runFuture(stream.run(Sink.first<SseEvent, HttpFailure, Unit>()));
```

Early completion cancels the subscription and aborts the request. SSE supports
UTF8 chunk boundaries, CR/LF/CRLF, comments, multiline data, IDs and retry hints.
An unterminated event at EOF is discarded. There is no automatic reconnect or
Last-Event-ID replay. Body size defaults to 8 MiB; each SSE event has a 1 Mi
character limit, including ignored fields and comments. Native driver chunk buffers
are outside these adapter limits.

Safe reads can opt into typed retry policy:

```dart
final read = adapter.request<Unit>('GET', uri).retry(
  Schedule(recurrences: 2, initialDelay: Duration(milliseconds: 100),
    maxDelay: Duration(seconds: 2), elapsedBudget: Duration(seconds: 10)),
  whileError: (e) => e.status == 429 || e.status == 503,
  retryAfter: (e, now) => e.retryDelay(now),
);
```

Retry-After is a lower-bound server instruction and overrides the local backoff
cap. A retry exceeding the elapsed budget is not started. This is not an operation
timeout. Writes and partial SSE streams require an application idempotency/replay
contract before retry can be safe.

Validation: `dart analyze`, `dart test`, and
`dart test -p chrome test/portable_test.dart`. VM integration fixtures use real
loopback HTTP/SSE, including cancellation before headers and early stop. Browser
fixtures prove portable parsing/outcomes, not live BrowserClient abort behavior.

## Unpublished memory budgets

Responses now use immutable packed bytes with defensive copying of caller input.
Requests accumulate using the SDK BytesBuilder. `EffectHttp` accepts
`maxConcurrentRequests` (32 by default, shared with SSE) and `maxBufferedBytes`
(32 MiB by default across active response accumulators). Overload is a typed
HttpFailure before sending additional work; it never retries a write.

```dart
final api = EffectHttp(client,
  maxBodyBytes: 2 * 1024 * 1024,
  maxBufferedBytes: 8 * 1024 * 1024,
  maxConcurrentRequests: 4,
);
```

The byte budget excludes responses retained by your application, transport
chunks, transient packed copies, decoded strings and SSE parsing. Bound those at
the consumer too; these are logical budgets, not a process heap/RSS ceiling.
