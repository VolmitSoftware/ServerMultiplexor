import 'dart:async';
import 'dart:io';

import 'package:multiplexor/utils/native_directory_picker.dart';
import 'package:test/test.dart';

class _Invocation {
  _Invocation(this.executable, this.arguments, this.environment, this.timeout);

  final String executable;
  final List<String> arguments;
  final Map<String, String> environment;
  final Duration timeout;
}

void main() {
  late List<_Invocation> calls;
  late Map<String, String> environment;
  late Set<String> directories;

  setUp(() {
    calls = <_Invocation>[];
    environment = <String, String>{
      'HOME': '/home/user',
      'PATH': '/usr/bin:/bin',
    };
    directories = <String>{'/', '/home', '/home/user', '/home/user/output'};
  });

  NativeDirectoryPicker picker({
    String platform = 'macos',
    String currentDirectory = '/home/user',
    ProcessResult Function(_Invocation invocation)? respond,
  }) => NativeDirectoryPicker(
    operatingSystem: platform,
    environment: environment,
    currentDirectory: currentDirectory,
    directoryExists: directories.contains,
    runner:
        (
          String executable,
          List<String> arguments, {
          required Map<String, String> environment,
          required Duration timeout,
        }) async {
          _Invocation invocation = _Invocation(
            executable,
            List<String>.of(arguments),
            Map<String, String>.of(environment),
            timeout,
          );
          calls.add(invocation);
          if (executable == '/bin/launchctl') {
            return ProcessResult(10, 0, 'Aqua\n', '');
          }
          return respond?.call(invocation) ??
              ProcessResult(11, 0, '/home/user/output\n', '');
        },
  );

  test('macOS opens a folder dialog with the initial path as data', () async {
    String unusual = '/home/user/a "quote" \$HOME `cmd` ü';
    directories.add(unusual);
    NativeDirectoryPicker service = picker(
      respond: (_Invocation invocation) =>
          ProcessResult(11, 0, '$unusual\n', ''),
    );

    expect(await service.pickDirectory(initialDirectory: unusual), unusual);
    expect(calls.map((_Invocation call) => call.executable), <String>[
      '/bin/launchctl',
      '/usr/bin/osascript',
    ]);
    expect(calls.first.arguments, <String>['managername']);
    expect(calls.last.arguments.first, '-e');
    expect(calls.last.arguments[1], contains('choose folder'));
    expect(calls.last.arguments[1], contains('item 1 of arguments'));
    expect(calls.last.arguments[1], isNot(contains(unusual)));
    expect(calls.last.arguments.sublist(2), <String>['--', unusual]);
    expect(calls.first.timeout, const Duration(seconds: 3));
    expect(calls.last.timeout, const Duration(minutes: 5));
  });

  test('missing destination starts at its nearest existing ancestor', () async {
    await picker().pickDirectory(
      initialDirectory: '/home/user/output/not/created/yet',
    );
    expect(calls.last.arguments.last, '/home/user/output');
  });

  test('relative paths are resolved against the current directory', () async {
    await picker().pickDirectory(initialDirectory: 'output/new');
    expect(calls.last.arguments.last, '/home/user/output');
  });

  test('tilde paths expand without shell evaluation', () async {
    await picker().pickDirectory(initialDirectory: '~/output/new');
    expect(calls.last.arguments.last, '/home/user/output');
    await picker().pickDirectory(initialDirectory: '~');
    expect(calls.last.arguments.last, '/home/user');
  });

  test('empty initial path starts at home', () async {
    await picker().pickDirectory(initialDirectory: '');
    expect(calls.last.arguments.last, '/home/user');
  });

  test('missing home uses the current directory', () async {
    environment.remove('HOME');
    await picker().pickDirectory();
    expect(calls.last.arguments.last, '/home/user');
  });

  test('macOS cancellation leaves the path unset', () async {
    expect(
      await picker(
        respond: (_Invocation invocation) => ProcessResult(11, 0, '\n', ''),
      ).pickDirectory(),
      isNull,
    );
    expect(calls.last.arguments[1], contains('errorNumber is -128'));
  });

  test('selected paths retain trailing spaces and Unicode', () async {
    String selected = '/home/user/ü space ';
    directories.add(selected);
    expect(
      await picker(
        respond: (_Invocation invocation) =>
            ProcessResult(11, 0, '$selected\n', ''),
      ).pickDirectory(),
      selected,
    );
  });

  test('relative or nonexistent selections fail clearly', () async {
    for (String selected in <String>['relative', '/missing']) {
      await expectLater(
        picker(
          respond: (_Invocation invocation) =>
              ProcessResult(11, 0, '$selected\n', ''),
        ).pickDirectory(),
        throwsA(
          isA<NativeDirectoryPickerException>().having(
            (NativeDirectoryPickerException error) => error.message,
            'message',
            contains('existing absolute directory'),
          ),
        ),
      );
    }
  });

  test('process stderr is surfaced with a manual-entry action', () async {
    await expectLater(
      picker(
        respond: (_Invocation invocation) =>
            ProcessResult(11, 2, '', 'Cannot connect to the display'),
      ).pickDirectory(),
      throwsA(
        isA<NativeDirectoryPickerException>()
            .having(
              (NativeDirectoryPickerException error) => error.message,
              'message',
              contains('Cannot connect to the display'),
            )
            .having(
              (NativeDirectoryPickerException error) => error.toString(),
              'string',
              contains('Enter the path manually.'),
            ),
      ),
    );
  });

  test('process failure without stderr includes its exit code', () async {
    await expectLater(
      picker(
        respond: (_Invocation invocation) => ProcessResult(11, 3, '', ''),
      ).pickDirectory(),
      throwsA(
        isA<NativeDirectoryPickerException>().having(
          (NativeDirectoryPickerException error) => error.message,
          'message',
          contains('exit 3'),
        ),
      ),
    );
  });

  test('missing executable is an actionable picker error', () async {
    await expectLater(
      picker(
        respond: (_Invocation invocation) => throw ProcessException(
          invocation.executable,
          invocation.arguments,
          'Executable not found',
          2,
        ),
      ).pickDirectory(),
      throwsA(
        isA<NativeDirectoryPickerException>().having(
          (NativeDirectoryPickerException error) => error.message,
          'message',
          contains('Executable not found'),
        ),
      ),
    );
  });

  test('timeout becomes a picker error', () async {
    await expectLater(
      picker(
        respond: (_Invocation invocation) => throw TimeoutException('expired'),
      ).pickDirectory(),
      throwsA(
        isA<NativeDirectoryPickerException>().having(
          (NativeDirectoryPickerException error) => error.message,
          'message',
          contains('timed out'),
        ),
      ),
    );
  });

  test('SSH rejects the dialog before starting any process', () async {
    for (String key in <String>['SSH_CONNECTION', 'SSH_CLIENT', 'SSH_TTY']) {
      environment[key] = 'session';
      await expectLater(
        picker().pickDirectory(),
        throwsA(
          isA<NativeDirectoryPickerException>().having(
            (NativeDirectoryPickerException error) => error.message,
            'message',
            contains('SSH'),
          ),
        ),
      );
      environment.remove(key);
    }
    expect(calls, isEmpty);
  });

  test('macOS background sessions do not launch a dialog', () async {
    NativeDirectoryPicker service = NativeDirectoryPicker(
      operatingSystem: 'macos',
      environment: environment,
      currentDirectory: '/home/user',
      directoryExists: directories.contains,
      runner:
          (
            String executable,
            List<String> arguments, {
            required Map<String, String> environment,
            required Duration timeout,
          }) async {
            calls.add(_Invocation(executable, arguments, environment, timeout));
            return ProcessResult(10, 0, 'Background\n', '');
          },
    );
    await expectLater(
      service.pickDirectory(),
      throwsA(isA<NativeDirectoryPickerException>()),
    );
    expect(calls.single.executable, '/bin/launchctl');
  });

  test('unsupported platforms reject without spawning a process', () async {
    await expectLater(
      picker(platform: 'freebsd').pickDirectory(),
      throwsA(isA<NativeDirectoryPickerException>()),
    );
    expect(calls, isEmpty);
  });

  test('headless Linux rejects without spawning a process', () async {
    await expectLater(
      picker(platform: 'linux').pickDirectory(),
      throwsA(isA<NativeDirectoryPickerException>()),
    );
    expect(calls, isEmpty);
  });

  test('Linux uses zenity directory selection under X11 or Wayland', () async {
    for (String display in <String>['DISPLAY', 'WAYLAND_DISPLAY']) {
      environment[display] = ':1';
      expect(
        await picker(platform: 'linux').pickDirectory(),
        '/home/user/output',
      );
      expect(calls.last.executable, 'zenity');
      expect(calls.last.arguments, contains('--directory'));
      expect(calls.last.arguments, contains('--filename=/home/user/'));
      environment.remove(display);
    }
  });

  test('Linux falls back to kdialog only when zenity is missing', () async {
    environment['DISPLAY'] = ':1';
    expect(
      await picker(
        platform: 'linux',
        respond: (_Invocation invocation) {
          if (invocation.executable == 'zenity') {
            throw ProcessException('zenity', <String>[], 'Not found', 2);
          }
          return ProcessResult(11, 0, '/home/user/output\n', '');
        },
      ).pickDirectory(),
      '/home/user/output',
    );
    expect(calls.map((_Invocation call) => call.executable), <String>[
      'zenity',
      'kdialog',
    ]);
    expect(calls.last.arguments.sublist(2), <String>[
      '--getexistingdirectory',
      '/home/user',
    ]);
  });

  test('Linux cancellation does not open another dialog', () async {
    environment['DISPLAY'] = ':1';
    expect(
      await picker(
        platform: 'linux',
        respond: (_Invocation invocation) => ProcessResult(11, 1, '', ''),
      ).pickDirectory(),
      isNull,
    );
    expect(calls, hasLength(1));
  });

  test('Linux picker errors do not open another dialog', () async {
    environment['DISPLAY'] = ':1';
    await expectLater(
      picker(
        platform: 'linux',
        respond: (_Invocation invocation) => ProcessResult(11, 2, '', 'Failed'),
      ).pickDirectory(),
      throwsA(isA<NativeDirectoryPickerException>()),
    );
    expect(calls, hasLength(1));
  });

  test('Linux without installed pickers gives manual-entry guidance', () async {
    environment['DISPLAY'] = ':1';
    await expectLater(
      picker(
        platform: 'linux',
        respond: (_Invocation invocation) =>
            throw ProcessException(invocation.executable, <String>[], 'No', 2),
      ).pickDirectory(),
      throwsA(
        isA<NativeDirectoryPickerException>().having(
          (NativeDirectoryPickerException error) => error.message,
          'message',
          contains('zenity or kdialog'),
        ),
      ),
    );
  });

  test(
    'Windows passes paths through the environment with STA enabled',
    () async {
      String selected = r'C:\Users\user\ü "quoted" $HOME';
      environment = <String, String>{'USERPROFILE': r'C:\Users\user'};
      directories = <String>{r'C:\', r'C:\Users', r'C:\Users\user', selected};
      expect(
        await picker(
          platform: 'windows',
          currentDirectory: r'C:\Users\user',
          respond: (_Invocation invocation) =>
              ProcessResult(11, 0, '$selected\r\n', ''),
        ).pickDirectory(initialDirectory: selected),
        selected,
      );
      expect(calls.single.executable, 'powershell.exe');
      expect(calls.single.arguments, contains('-STA'));
      expect(calls.single.arguments, contains('-NoProfile'));
      expect(calls.single.arguments.last, contains('FolderBrowserDialog'));
      expect(calls.single.arguments.last, isNot(contains(selected)));
      expect(
        calls.single.environment['MULTIPLEXOR_PICKER_INITIAL_DIRECTORY'],
        selected,
      );
      expect(
        environment,
        isNot(contains('MULTIPLEXOR_PICKER_INITIAL_DIRECTORY')),
      );
    },
  );

  test('Windows cancellation returns null', () async {
    environment = <String, String>{'USERPROFILE': r'C:\Users\user'};
    directories = <String>{r'C:\Users\user'};
    expect(
      await picker(
        platform: 'windows',
        currentDirectory: r'C:\Users\user',
        respond: (_Invocation invocation) => ProcessResult(11, 0, '', ''),
      ).pickDirectory(),
      isNull,
    );
  });

  test('Windows services do not launch a folder dialog', () async {
    environment = <String, String>{
      'USERPROFILE': r'C:\Users\user',
      'SESSIONNAME': 'Services',
    };
    directories = <String>{r'C:\Users\user'};
    await expectLater(
      picker(
        platform: 'windows',
        currentDirectory: r'C:\Users\user',
      ).pickDirectory(),
      throwsA(isA<NativeDirectoryPickerException>()),
    );
    expect(calls, isEmpty);
  });

  test('unavailable starting folders do not launch a process', () async {
    directories.clear();
    await expectLater(
      picker().pickDirectory(),
      throwsA(
        isA<NativeDirectoryPickerException>().having(
          (NativeDirectoryPickerException error) => error.message,
          'message',
          contains('starting folder is unavailable'),
        ),
      ),
    );
    expect(calls, isEmpty);
  });

  test('filesystem failures become actionable picker errors', () async {
    NativeDirectoryPicker service = NativeDirectoryPicker(
      operatingSystem: 'macos',
      environment: environment,
      currentDirectory: '/home/user',
      directoryExists: (String directory) =>
          throw const FileSystemException('Permission denied'),
    );
    await expectLater(
      service.pickDirectory(),
      throwsA(
        isA<NativeDirectoryPickerException>().having(
          (NativeDirectoryPickerException error) => error.message,
          'message',
          contains('Permission denied'),
        ),
      ),
    );
  });
}
