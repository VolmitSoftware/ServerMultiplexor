import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Result of a Minecraft Server List Ping (SLP) status query.
///
/// SLP is the same status handshake the vanilla client uses to populate the
/// multiplayer server list. It works against any running server on its
/// `server-port` without requiring `enable-query` or `enable-rcon`, which is
/// why this is the default source of live player counts.
class MinecraftPingResult {
  const MinecraftPingResult({
    required this.online,
    required this.max,
    required this.versionName,
    required this.motd,
    required this.sample,
    required this.latency,
  });

  /// Number of players currently online.
  final int online;

  /// Maximum player slots advertised by the server.
  final int max;

  /// Human-readable version string (e.g. "Purpur 26.1.2").
  final String versionName;

  /// Message of the day, flattened to plain text with color codes stripped.
  final String motd;

  /// Sample of online player names (servers may truncate or omit this list).
  final List<String> sample;

  /// Round-trip time of the status exchange.
  final Duration latency;

  /// Builds a result from the decoded status JSON object and a measured
  /// [latency]. Missing or malformed fields fall back to safe defaults.
  factory MinecraftPingResult.fromStatusJson(
    Map<String, dynamic> json,
    Duration latency,
  ) {
    final players = json['players'];
    int online = 0;
    int max = 0;
    final sample = <String>[];
    if (players is Map) {
      online = (players['online'] as num?)?.toInt() ?? 0;
      max = (players['max'] as num?)?.toInt() ?? 0;
      final rawSample = players['sample'];
      if (rawSample is List) {
        for (final entry in rawSample) {
          if (entry is Map && entry['name'] is String) {
            sample.add(stripFormatting(entry['name'] as String));
          }
        }
      }
    }

    String versionName = '?';
    final version = json['version'];
    if (version is Map && version['name'] is String) {
      versionName = stripFormatting(version['name'] as String);
    }

    return MinecraftPingResult(
      online: online,
      max: max,
      versionName: versionName,
      motd: extractMotd(json['description']),
      sample: sample,
      latency: latency,
    );
  }
}

final RegExp _sectionCodePattern = RegExp('§.');

/// Removes legacy section-sign (§) color/format codes from [text].
String stripFormatting(String text) =>
    text.replaceAll(_sectionCodePattern, '').trim();

/// Flattens a server description (MOTD) into plain text.
///
/// The `description` field may be a plain string or a chat component object
/// (with nested `extra` parts), depending on server version. Both shapes are
/// collapsed to a single line with formatting stripped and newlines spaced.
String extractMotd(dynamic description) {
  final buffer = StringBuffer();
  void walk(dynamic node) {
    if (node is String) {
      buffer.write(node);
    } else if (node is Map) {
      if (node['text'] is String) {
        buffer.write(node['text']);
      }
      final extra = node['extra'];
      if (extra is List) {
        for (final part in extra) {
          walk(part);
        }
      }
    } else if (node is List) {
      for (final part in node) {
        walk(part);
      }
    }
  }

  walk(description);
  return stripFormatting(buffer.toString().replaceAll('\n', ' ').trim());
}

/// Encodes [value] as a Minecraft-protocol VarInt (little-endian base-128,
/// continuation bit in the high bit). Negative values are encoded as their
/// 32-bit two's-complement representation, matching the wire format.
List<int> encodeVarInt(int value) {
  final bytes = <int>[];
  var v = value & 0xFFFFFFFF;
  while (true) {
    final byte = v & 0x7F;
    v >>>= 7;
    if (v != 0) {
      bytes.add(byte | 0x80);
    } else {
      bytes.add(byte);
      break;
    }
  }
  return bytes;
}

/// Reads a VarInt from [bytes] starting at [offset].
///
/// Returns the decoded value and the number of bytes consumed, or `null` if
/// the buffer does not yet hold a complete VarInt (or it exceeds the 5-byte
/// maximum, which signals a malformed stream).
(int value, int size)? readVarInt(List<int> bytes, [int offset = 0]) {
  int result = 0;
  int shift = 0;
  int index = offset;
  while (index < bytes.length) {
    final byte = bytes[index];
    result |= (byte & 0x7F) << shift;
    index++;
    if (byte & 0x80 == 0) {
      return (result, index - offset);
    }
    shift += 7;
    if (shift >= 35) {
      return null;
    }
  }
  return null;
}

/// Builds the handshake + status-request byte stream for [host]:[port].
///
/// Protocol version is sent as -1 ("unspecified"), which every status-capable
/// server accepts. The two packets are concatenated so they can be written in
/// a single socket flush.
List<int> buildHandshakeRequest(String host, int port) {
  final hostBytes = utf8.encode(host);
  final handshake = <int>[
    0x00, // packet id: handshake
    ...encodeVarInt(-1), // protocol version
    ...encodeVarInt(hostBytes.length),
    ...hostBytes,
    (port >> 8) & 0xFF, // server port, big-endian unsigned short
    port & 0xFF,
    0x01, // next state: status
  ];

  final statusRequest = <int>[0x00]; // packet id: status request (empty body)

  return <int>[
    ...encodeVarInt(handshake.length),
    ...handshake,
    ...encodeVarInt(statusRequest.length),
    ...statusRequest,
  ];
}

/// Extracts a complete length-prefixed packet body from [bytes] if one has
/// fully arrived, returning the body (without the length prefix). Returns
/// `null` while the packet is still incomplete.
List<int>? extractPacketBody(List<int> bytes) {
  final header = readVarInt(bytes);
  if (header == null) {
    return null;
  }
  final (length, prefixSize) = header;
  if (length < 0 || bytes.length < prefixSize + length) {
    return null;
  }
  return bytes.sublist(prefixSize, prefixSize + length);
}

/// Parses a status-response packet body into its decoded JSON object.
///
/// The body is `[packet id VarInt][json length VarInt][json UTF-8]`. Returns
/// `null` if the structure is malformed or the JSON is not an object.
Map<String, dynamic>? parseStatusResponse(List<int> body) {
  final idHeader = readVarInt(body);
  if (idHeader == null) {
    return null;
  }
  final (_, idSize) = idHeader;
  final lengthHeader = readVarInt(body, idSize);
  if (lengthHeader == null) {
    return null;
  }
  final (jsonLength, lengthSize) = lengthHeader;
  final start = idSize + lengthSize;
  if (jsonLength < 0 || body.length < start + jsonLength) {
    return null;
  }
  try {
    final decoded = json.decode(
      utf8.decode(body.sublist(start, start + jsonLength), allowMalformed: true),
    );
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}

/// Performs a Server List Ping against [host]:[port] and returns the parsed
/// status, or `null` if the server did not respond within [timeout] (not
/// running, still starting, unreachable, or not speaking the protocol).
Future<MinecraftPingResult?> pingMinecraftServer(
  String host,
  int port, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  Socket? socket;
  final stopwatch = Stopwatch()..start();
  try {
    socket = await Socket.connect(host, port, timeout: timeout);
    socket.add(buildHandshakeRequest(host, port));
    await socket.flush();

    final buffer = <int>[];
    final completer = Completer<List<int>?>();
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    });
    final subscription = socket.listen(
      (chunk) {
        buffer.addAll(chunk);
        final body = extractPacketBody(buffer);
        if (body != null && !completer.isCompleted) {
          completer.complete(body);
        }
      },
      onError: (_) {
        if (!completer.isCompleted) {
          completer.complete(null);
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete(extractPacketBody(buffer));
        }
      },
      cancelOnError: true,
    );

    final body = await completer.future;
    stopwatch.stop();
    timer.cancel();
    await subscription.cancel();
    if (body == null) {
      return null;
    }
    final status = parseStatusResponse(body);
    if (status == null) {
      return null;
    }
    return MinecraftPingResult.fromStatusJson(status, stopwatch.elapsed);
  } catch (_) {
    return null;
  } finally {
    socket?.destroy();
  }
}
