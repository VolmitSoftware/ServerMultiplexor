import 'dart:convert';
import 'dart:io';

import 'package:multiplexor/services/proxy_runtime_control.dart';
import 'package:test/test.dart';

void main() {
  const String token = '0123456789abcdef0123456789abcdef';
  late ProxyRuntimeControl control;
  late List<String> commands;

  setUp(() async {
    commands = <String>[];
    control = await ProxyRuntimeControl.start(
      token: token,
      onCommand: (String command) async => commands.add(command),
    );
  });
  tearDown(() => control.close());

  test('forwards authenticated console and shutdown commands once', () async {
    for (final String command in <String>[
      'velocity info',
      'glist all',
      'end',
    ]) {
      expect(
        await ProxyRuntimeControl.send(
          port: control.port,
          token: token,
          command: command,
        ),
        isTrue,
      );
    }
    expect(commands, <String>['velocity info', 'glist all', 'end']);
  });

  test('wrong owner cannot send commands', () async {
    expect(
      await ProxyRuntimeControl.send(
        port: control.port,
        token: 'bad-owner-token',
        command: 'end',
      ),
      isFalse,
    );
    expect(commands, isEmpty);
  });

  test(
    'rejects injected newlines and excessive commands before send',
    () async {
      for (final String command in <String>[
        '',
        'end\nvelocity info',
        'a' * 4097,
      ]) {
        await expectLater(
          ProxyRuntimeControl.send(
            port: control.port,
            token: token,
            command: command,
          ),
          throwsArgumentError,
        );
      }
      expect(commands, isEmpty);
    },
  );

  test(
    'validates command framing independently of client validation',
    () async {
      final Socket client = await Socket.connect(
        InternetAddress.loopbackIPv4,
        control.port,
      );
      addTearDown(client.destroy);
      client.writeln(
        jsonEncode(<String, String>{'token': token, 'command': 'end\nstop'}),
      );
      await client.flush();
      await client.drain<void>();
      expect(commands, isEmpty);
    },
  );

  test('handles fragmented request without changing spaces', () async {
    final Socket client = await Socket.connect(
      InternetAddress.loopbackIPv4,
      control.port,
    );
    addTearDown(client.destroy);
    final String request = jsonEncode(<String, String>{
      'token': token,
      'command': 'send  Alice lobby',
    });
    client.write(request.substring(0, 10));
    await client.flush();
    client.writeln(request.substring(10));
    await client.flush();
    expect(await client.cast<List<int>>().transform(utf8.decoder).join(), 'ok\n');
    expect(commands, <String>['send  Alice lobby']);
  });
}
