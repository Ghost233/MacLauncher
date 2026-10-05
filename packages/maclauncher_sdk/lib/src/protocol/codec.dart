/// Line-delimited UTF-8 JSON framing shared by client and server.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Splits a byte stream into decoded JSON message maps, one per line.
Stream<Map<String, Object?>> decodeMessages(Stream<List<int>> bytes) {
  // Cast first: sockets surface as Stream<Uint8List> at runtime, which does
  // not satisfy utf8.decoder's StreamTransformer<List<int>, String> typing.
  return bytes
      .cast<List<int>>()
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .where((line) => line.trim().isNotEmpty)
      .map((line) {
        final decoded = jsonDecode(line);
        if (decoded is! Map) {
          throw const FormatException('protocol message must be a JSON object');
        }
        return decoded.cast<String, Object?>();
      });
}

/// Writes one message as a single JSON line.
void writeMessage(IOSink sink, Map<String, Object?> message) {
  sink.writeln(jsonEncode(message));
}
