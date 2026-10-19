/// Optional HTTP/SSE support. No automatic retries, including for writes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:effect_core/effect_core.dart';
import 'package:http/http.dart' as http;

/// Transport, protocol, and response errors are expected failures.
final class HttpFailure implements Exception {
  const HttpFailure(this.message, {this.status, this.retryAfter, this.error});
  final String message;
  final int? status;
  final String? retryAfter;
  final Object? error;
  Duration? retryDelay(DateTime now) => parseRetryAfter(retryAfter, now);
}

/// RFC delta-seconds or IMF-fixdate. Uses supplied time for deterministic tests.
Duration? parseRetryAfter(String? value, DateTime now) {
  if (value == null) return null;
  final seconds = int.tryParse(value.trim());
  if (seconds != null) {
    return seconds < 0
        ? null
        : seconds > 9007199254
        ? const Duration(microseconds: 9007199254740991)
        : Duration(seconds: seconds);
  }
  final match = RegExp(
    r'^\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$',
  ).firstMatch(value.trim());
  if (match == null) return null;
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final month = months.indexOf(match[2]!) + 1;
  if (month == 0) return null;
  final date = DateTime.utc(
    int.parse(match[3]!),
    month,
    int.parse(match[1]!),
    int.parse(match[4]!),
    int.parse(match[5]!),
    int.parse(match[6]!),
  );
  if (date.day != int.parse(match[1]!) ||
      date.hour != int.parse(match[4]!) ||
      date.minute != int.parse(match[5]!) ||
      date.second != int.parse(match[6]!)) {
    return null;
  }
  final delay = date.difference(now.toUtc());
  return delay.isNegative ? Duration.zero : delay;
}

final class HttpResult {
  HttpResult(this.status, Map<String, String> headers, List<int> body)
    : headers = Map.unmodifiable(headers),
      body = Uint8List.fromList(body).asUnmodifiableView();
  HttpResult._owned(this.status, Map<String, String> headers, Uint8List bytes)
    : headers = Map.unmodifiable(headers),
      body = bytes.asUnmodifiableView();
  final int status;
  final Map<String, String> headers;
  final List<int> body;
  String get text => utf8.decode(body);
}

final class SseEvent {
  const SseEvent(this.data, {this.event = 'message', this.id, this.retry});
  final String data, event;
  final String? id;
  final Duration? retry;
}

/// Borrows a client. The caller owns closing it. AbortableRequest support is
/// required from the client; IOClient and BrowserClient implement it.
final class EffectHttp {
  EffectHttp(
    this.client, {
    this.maxBodyBytes = 8 * 1024 * 1024,
    this.maxEventCharacters = 1024 * 1024,
    this.maxConcurrentRequests = 32,
    this.maxBufferedBytes = 32 * 1024 * 1024,
  }) {
    if (maxBodyBytes < 1 ||
        maxEventCharacters < 1 ||
        maxConcurrentRequests < 1 ||
        maxBufferedBytes < 1) {
      throw ArgumentError('Invalid limits');
    }
  }
  final http.Client client;
  final int maxBodyBytes, maxEventCharacters;

  /// Combined active buffered requests and SSE subscriptions. No wait queue.
  final int maxConcurrentRequests;

  /// Logical bytes in active response accumulators; excludes returned results,
  /// transient packed copies, decoder strings and transport-owned chunks.
  final int maxBufferedBytes;
  int _active = 0, _buffered = 0;
  int get activeRequests => _active;
  int get bufferedBytes => _buffered;
  void _admit() {
    if (_active >= maxConcurrentRequests) {
      throw const HttpFailure('HTTP concurrent request limit reached');
    }
    _active++;
  }

  Effect<HttpResult, HttpFailure, R> request<R>(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    List<int> body = const [],
  }) => Effect.defer(() {
    final abort = Completer<void>();
    void cancel() {
      if (!abort.isCompleted) abort.complete();
    }

    return Effect.fromFuture<HttpResult, HttpFailure, R>(
      () async {
        _admit();
        var retained = 0;
        try {
          final request =
              http.AbortableRequest(method, uri, abortTrigger: abort.future)
                ..headers.addAll(headers)
                ..bodyBytes = body;
          final response = await client.send(request);
          try {
            if (response.statusCode < 200 || response.statusCode >= 300) {
              await response.stream.listen((_) {}).cancel();
              throw HttpFailure(
                'HTTP response rejected',
                status: response.statusCode,
                retryAfter: response.headers['retry-after'],
              );
            }
            final bytes = BytesBuilder();
            await for (final chunk in response.stream) {
              if (bytes.length + chunk.length > maxBodyBytes) {
                throw const HttpFailure('Response exceeds body limit');
              }
              if (_buffered + chunk.length > maxBufferedBytes) {
                throw const HttpFailure(
                  'Concurrent response byte limit reached',
                );
              }
              retained += chunk.length;
              _buffered += chunk.length;
              bytes.add(chunk);
            }
            return HttpResult._owned(
              response.statusCode,
              response.headers,
              bytes.takeBytes(),
            );
          } finally {
            cancel();
          }
        } finally {
          _buffered -= retained;
          _active--;
          cancel();
        }
      },
      onCancel: cancel,
      onError: _failure,
    );
  });

  /// A fresh GET per consumption; cancellation/early completion aborts transport.
  /// No reconnection or replay. Limits include comments and undispatched fields.
  EffectStream<SseEvent, HttpFailure, R> sse<R>(
    Uri uri, {
    Map<String, String> headers = const {},
  }) => EffectStream.fromNative(() => _sse(uri, headers), onError: _failure);

  Stream<SseEvent> _sse(Uri uri, Map<String, String> headers) {
    final abort = Completer<void>();
    void cancel() {
      if (!abort.isCompleted) abort.complete();
    }

    Stream<SseEvent> source() async* {
      _admit();
      try {
        final request = http.AbortableRequest(
          'GET',
          uri,
          abortTrigger: abort.future,
        )..headers.addAll({'accept': 'text/event-stream', ...headers});
        final response = await client.send(request);
        if (response.statusCode != 200) {
          await response.stream.listen((_) {}).cancel();
          throw HttpFailure(
            'SSE response rejected',
            status: response.statusCode,
            retryAfter: response.headers['retry-after'],
          );
        }
        if (response.headers['content-type']
                ?.split(';')
                .first
                .trim()
                .toLowerCase() !=
            'text/event-stream') {
          await response.stream.listen((_) {}).cancel();
          throw const HttpFailure('Expected text/event-stream');
        }
        var lineBuffer = StringBuffer();
        var event = 'message';
        String? id;
        Duration? retry;
        final data = <String>[];
        var size = 0, first = true, afterCr = false;
        await for (final chunk in _decodeChunks(
          response.stream,
        ).transform(utf8.decoder)) {
          for (final rune in chunk.runes) {
            if (first) {
              first = false;
              if (rune == 0xfeff) continue;
            }
            if (afterCr && rune == 10) {
              afterCr = false;
              continue;
            }
            afterCr = rune == 13;
            if (rune != 10 && rune != 13) {
              if (++size > maxEventCharacters) {
                throw const HttpFailure('SSE event exceeds limit');
              }
              lineBuffer.writeCharCode(rune);
              continue;
            }
            final line = lineBuffer.toString();
            if (line.isEmpty) {
              if (data.isNotEmpty) {
                yield SseEvent(
                  data.join('\n'),
                  event: event,
                  id: id,
                  retry: retry,
                );
              }
              data.clear();
              event = 'message';
              size = 0;
            } else if (!line.startsWith(':')) {
              final colon = line.indexOf(':');
              final field = colon < 0 ? line : line.substring(0, colon);
              var value = colon < 0 ? '' : line.substring(colon + 1);
              if (value.startsWith(' ')) value = value.substring(1);
              switch (field) {
                case 'data':
                  data.add(value);
                case 'event':
                  event = value.isEmpty ? 'message' : value;
                case 'id':
                  if (!value.contains('\u0000')) id = value;
                case 'retry':
                  if (RegExp(r'^\d+$').hasMatch(value)) {
                    retry = Duration(milliseconds: int.parse(value));
                  }
              }
            }
            lineBuffer = StringBuffer();
          }
        }
        // Unterminated events at EOF are discarded according to SSE framing.
      } finally {
        _active--;
        cancel();
      }
    }

    // onCancel must abort even while async* is waiting for response headers.
    return Stream<SseEvent>.multi((controller) {
      final subscription = source().listen(
        controller.addSync,
        onError: controller.addErrorSync,
        onDone: controller.closeSync,
      );
      controller.onPause = subscription.pause;
      controller.onResume = subscription.resume;
      controller.onCancel = () {
        cancel();
        return subscription.cancel();
      };
    });
  }
}

HttpFailure _failure(Object error, StackTrace stack) => error is HttpFailure
    ? error
    : HttpFailure('HTTP transport or decoding failed', error: error);

// Bound decoder allocations independently of driver chunk sizes. The original
// transport chunk remains driver-owned; parsing copies at most 8 KiB at once.
Stream<List<int>> _decodeChunks(Stream<List<int>> source) async* {
  await for (final chunk in source) {
    for (var start = 0; start < chunk.length; start += 8192) {
      final end = start + 8192 < chunk.length ? start + 8192 : chunk.length;
      yield chunk.sublist(start, end);
    }
  }
}
