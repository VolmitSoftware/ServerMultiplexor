import 'dart:async';
import 'dart:io';

import 'package:multiplexor/services/rcon_client.dart';
import 'package:test/test.dart';

import 'support/fake_rcon.dart';

/// Polls [condition] until it holds, rather than guessing at how long the
/// loopback needs to deliver a FIN.
Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  required String describe,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out after $timeout waiting for: $describe');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  group('parseTps', () {
    test('parses a plain Paper tps line', () {
      expect(
        parseTps('TPS from last 1m, 5m, 15m: 19.98, 20.0, 20.0'),
        closeTo(19.98, 0.001),
      );
    });

    test('ignores section-sign color codes', () {
      expect(
        parseTps('§6TPS from last 1m, 5m, 15m: §a20.0, §a20.0, §a20.0'),
        20.0,
      );
    });

    test('clamps values above 20', () {
      expect(parseTps('TPS: 20.05'), 20.0);
    });

    test('returns null when there is no number to read', () {
      expect(parseTps(null), isNull);
      expect(parseTps(''), isNull);
      expect(parseTps('nothing numeric after the colon:'), isNull);
    });
  });

  group('RconConnectionPool', () {
    test('runs command side effects before returning the response', () async {
      final Set<String> operators = <String>{};
      final FakeRcon server = await FakeRcon.start(
        password: 'secret',
        onCommand: (String command) {
          operators.add(command.substring('op '.length));
          return 'Granted operator';
        },
      );
      addTearDown(server.close);
      final RconConnectionPool pool = RconConnectionPool();
      addTearDown(pool.disposeAll);

      final String? response = await pool.command(
        '127.0.0.1',
        server.port,
        'secret',
        'op controller',
      );

      expect(response, 'Granted operator');
      expect(operators, <String>{'controller'});
    });

    test('returns null when a command handler drops the connection', () async {
      final List<String> commands = <String>[];
      final FakeRcon server = await FakeRcon.start(
        password: 'secret',
        response: 'must not replace a failed command',
        onCommand: (String command) {
          commands.add(command);
          return command == 'deop controller' ? null : 'ready';
        },
      );
      addTearDown(server.close);
      final RconConnectionPool pool = RconConnectionPool();
      addTearDown(pool.disposeAll);

      expect(
        await pool.command(
          '127.0.0.1',
          server.port,
          'secret',
          'deop controller',
        ),
        isNull,
      );
      expect(server.liveClientCount, 0);
      expect(
        await pool.command('127.0.0.1', server.port, 'secret', 'list'),
        'ready',
      );
      expect(commands, <String>['deop controller', 'list']);
      expect(server.acceptCount, 2);
    });

    test('authenticates and returns the command output', () async {
      final FakeRcon server = await FakeRcon.start(
        password: 'secret',
        response: 'TPS from last 1m, 5m, 15m: 20.0, 20.0, 20.0',
      );
      addTearDown(server.close);
      final pool = RconConnectionPool();
      addTearDown(pool.disposeAll);

      final out = await pool.command('127.0.0.1', server.port, 'secret', 'tps');
      expect(out, contains('20.0'));
      expect(parseTps(out), 20.0);
    });

    test('reuses a single connection across sequential commands', () async {
      final FakeRcon server = await FakeRcon.start(
        password: 'secret',
        response: 'TPS from last 1m, 5m, 15m: 20.0, 20.0, 20.0',
      );
      addTearDown(server.close);
      final pool = RconConnectionPool();
      addTearDown(pool.disposeAll);

      final a = await pool.command('127.0.0.1', server.port, 'secret', 'tps');
      final b = await pool.command('127.0.0.1', server.port, 'secret', 'tps');
      final c = await pool.command('127.0.0.1', server.port, 'secret', 'tps');

      expect(parseTps(a), 20.0);
      expect(parseTps(b), 20.0);
      expect(parseTps(c), 20.0);
      expect(
        server.acceptCount,
        1,
        reason: 'the pool must reuse one socket, not reconnect per command',
      );
    });

    test('reconnects after the server drops the connection', () async {
      final FakeRcon server = await FakeRcon.start(
        password: 'secret',
        response: 'TPS from last 1m, 5m, 15m: 19.5, 19.5, 19.5',
      );
      addTearDown(server.close);
      final pool = RconConnectionPool();
      addTearDown(pool.disposeAll);

      final first = await pool.command(
        '127.0.0.1',
        server.port,
        'secret',
        'tps',
      );
      expect(parseTps(first), closeTo(19.5, 0.001));
      expect(server.acceptCount, 1);

      await server.dropClients();
      // Give the pool a chance to observe the FIN before the next command so it
      // reconnects cleanly rather than writing into a dead socket.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final second = await pool.command(
        '127.0.0.1',
        server.port,
        'secret',
        'tps',
      );
      expect(parseTps(second), closeTo(19.5, 0.001));
      expect(
        server.acceptCount,
        2,
        reason: 'a dropped connection must be re-established transparently',
      );
    });

    test('returns null on a bad password', () async {
      final FakeRcon server = await FakeRcon.start(
        password: 'secret',
        response: 'x',
      );
      addTearDown(server.close);
      final pool = RconConnectionPool();
      addTearDown(pool.disposeAll);

      final out = await pool.command(
        '127.0.0.1',
        server.port,
        'wrong-password',
        'tps',
      );
      expect(out, isNull);
    });

    test('returns null when the connection is refused', () async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      final pool = RconConnectionPool();
      addTearDown(pool.disposeAll);

      final out = await pool.command(
        '127.0.0.1',
        port,
        'secret',
        'tps',
        timeout: const Duration(milliseconds: 300),
      );
      expect(out, isNull);
    });

    // The CLI's exit path depends on these two facts: a pooled socket really
    // closes on disposal (an open one keeps the Dart event loop alive after
    // main returns), and disposal can happen twice — the interactive monitor
    // tears the pool down itself, and the runner does it again on the way out.
    test(
      'disposeAll closes the pooled connection and clears the pool',
      () async {
        final FakeRcon server = await FakeRcon.start(
          password: 'secret',
          response: 'TPS from last 1m, 5m, 15m: 20.0, 20.0, 20.0',
        );
        addTearDown(server.close);
        final pool = RconConnectionPool();
        addTearDown(pool.disposeAll);

        expect(
          parseTps(
            await pool.command('127.0.0.1', server.port, 'secret', 'tps'),
          ),
          20.0,
        );
        expect(server.liveClientCount, 1);

        pool.disposeAll();
        await _waitUntil(
          () => server.liveClientCount == 0,
          describe: 'the server to see the pooled socket close',
        );

        // A cleared pool has nothing to reuse, so the next command dials again.
        expect(
          parseTps(
            await pool.command('127.0.0.1', server.port, 'secret', 'tps'),
          ),
          20.0,
        );
        expect(server.acceptCount, 2);
      },
    );

    test('disposeAll is idempotent', () async {
      final FakeRcon server = await FakeRcon.start(
        password: 'secret',
        response: 'TPS from last 1m, 5m, 15m: 20.0, 20.0, 20.0',
      );
      addTearDown(server.close);
      final pool = RconConnectionPool();
      addTearDown(pool.disposeAll);

      await pool.command('127.0.0.1', server.port, 'secret', 'tps');

      pool.disposeAll();
      pool.disposeAll();
      pool.disposeAll();

      await _waitUntil(
        () => server.liveClientCount == 0,
        describe: 'the server to see the pooled socket close',
      );
      expect(
        parseTps(await pool.command('127.0.0.1', server.port, 'secret', 'tps')),
        20.0,
      );
    });
  });
}
