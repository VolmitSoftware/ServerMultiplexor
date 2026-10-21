import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

typedef NativeDirectoryPickerRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      required Map<String, String> environment,
      required Duration timeout,
    });

class NativeDirectoryPickerException implements Exception {
  const NativeDirectoryPickerException(this.message);

  final String message;

  @override
  String toString() => message;
}

class NativeDirectoryPicker {
  NativeDirectoryPicker({
    NativeDirectoryPickerRunner? runner,
    String? operatingSystem,
    Map<String, String>? environment,
    String? currentDirectory,
    bool Function(String directory)? directoryExists,
  }) : _runner = runner ?? _runProcess,
       _operatingSystem = operatingSystem ?? Platform.operatingSystem,
       _environment = Map<String, String>.unmodifiable(
         environment ?? Platform.environment,
       ),
       _currentDirectory = currentDirectory ?? Directory.current.path,
       _directoryExists = directoryExists ?? _exists;

  static const Duration _dialogTimeout = Duration(minutes: 5);
  static const Duration _sessionTimeout = Duration(seconds: 3);
  static const String _manualPath = 'Enter the path manually.';
  static const String _appleScript = '''
on run arguments
  try
    activate
    set startingFolder to POSIX file (item 1 of arguments) as alias
    set selectedFolder to choose folder with prompt "Choose a build destination folder" default location startingFolder
    return POSIX path of selectedFolder
  on error errorMessage number errorNumber
    if errorNumber is -128 then return ""
    error errorMessage number errorNumber
  end try
end run
''';
  static const String _powerShell = r'''
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
if (-not [Environment]::UserInteractive) {
  [Console]::Error.WriteLine('No interactive desktop session is available.')
  exit 2
}
Add-Type -AssemblyName System.Windows.Forms
$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
try {
  $dialog.Description = 'Choose a build destination folder'
  $dialog.ShowNewFolderButton = $false
  $dialog.SelectedPath = $env:MULTIPLEXOR_PICKER_INITIAL_DIRECTORY
  if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    [Console]::WriteLine($dialog.SelectedPath)
  }
} finally {
  $dialog.Dispose()
}
''';

  final NativeDirectoryPickerRunner _runner;
  final String _operatingSystem;
  final Map<String, String> _environment;
  final String _currentDirectory;
  final bool Function(String directory) _directoryExists;

  Future<String?> pickDirectory({String? initialDirectory}) async {
    if (<String>[
      'SSH_CONNECTION',
      'SSH_CLIENT',
      'SSH_TTY',
    ].any((String key) => _environment[key]?.isNotEmpty ?? false)) {
      throw const NativeDirectoryPickerException(
        'The folder picker is unavailable over SSH. $_manualPath',
      );
    }
    if (!<String>['macos', 'linux', 'windows'].contains(_operatingSystem)) {
      throw const NativeDirectoryPickerException(
        'The folder picker is unavailable on this platform. $_manualPath',
      );
    }
    if (_operatingSystem == 'linux' &&
        !<String>[
          'DISPLAY',
          'WAYLAND_DISPLAY',
        ].any((String key) => _environment[key]?.isNotEmpty ?? false)) {
      throw const NativeDirectoryPickerException(
        'The folder picker needs a desktop session. $_manualPath',
      );
    }
    try {
      String initialPath = _initialPath(initialDirectory);
      ProcessResult result;
      switch (_operatingSystem) {
        case 'macos':
          ProcessResult session = await _runner(
            '/bin/launchctl',
            <String>['managername'],
            environment: _environment,
            timeout: _sessionTimeout,
          );
          if (session.exitCode != 0 ||
              session.stdout.toString().trim() != 'Aqua') {
            throw const NativeDirectoryPickerException(
              'The folder picker needs a macOS desktop session. $_manualPath',
            );
          }
          result = await _runner(
            '/usr/bin/osascript',
            <String>['-e', _appleScript, '--', initialPath],
            environment: _environment,
            timeout: _dialogTimeout,
          );
        case 'windows':
          if (_environment['SESSIONNAME']?.toLowerCase() == 'services') {
            throw const NativeDirectoryPickerException(
              'The folder picker needs a Windows desktop session. $_manualPath',
            );
          }
          result = await _runner(
            'powershell.exe',
            <String>[
              '-NoProfile',
              '-NonInteractive',
              '-STA',
              '-Command',
              _powerShell,
            ],
            environment: <String, String>{
              ..._environment,
              'MULTIPLEXOR_PICKER_INITIAL_DIRECTORY': initialPath,
            },
            timeout: _dialogTimeout,
          );
        case 'linux':
          result = await _linuxPicker(initialPath);
          if (result.exitCode == 1) return null;
        default:
          throw const NativeDirectoryPickerException(
            'The folder picker is unavailable on this platform. $_manualPath',
          );
      }
      if (result.exitCode != 0) {
        String detail = result.stderr.toString().trim();
        throw NativeDirectoryPickerException(
          'The folder picker failed${detail.isEmpty ? ' (exit ${result.exitCode})' : ': $detail'}. $_manualPath',
        );
      }
      String selected = result.stdout.toString().replaceFirst(
        RegExp(r'\r?\n$'),
        '',
      );
      if (selected.isEmpty) return null;
      if (!_pathContext.isAbsolute(selected) || !_directoryExists(selected)) {
        throw const NativeDirectoryPickerException(
          'The folder picker did not return an existing absolute directory. $_manualPath',
        );
      }
      return _pathContext.normalize(selected);
    } on ProcessException catch (error) {
      throw NativeDirectoryPickerException(
        'Could not open the folder picker: ${error.message}. $_manualPath',
      );
    } on TimeoutException {
      throw const NativeDirectoryPickerException(
        'The folder picker timed out. $_manualPath',
      );
    } on FileSystemException catch (error) {
      throw NativeDirectoryPickerException(
        'Could not access the folder: ${error.message}. $_manualPath',
      );
    }
  }

  path.Context get _pathContext => path.Context(
    style: _operatingSystem == 'windows'
        ? path.Style.windows
        : path.Style.posix,
    current: _currentDirectory,
  );

  String _initialPath(String? requested) {
    String home =
        _environment[_operatingSystem == 'windows' ? 'USERPROFILE' : 'HOME'] ??
        _currentDirectory;
    String candidate = requested == null || requested.isEmpty
        ? home
        : requested;
    if (candidate == '~') {
      candidate = home;
    } else if (candidate.startsWith('~/') ||
        (_operatingSystem == 'windows' && candidate.startsWith(r'~\'))) {
      candidate = _pathContext.join(home, candidate.substring(2));
    }
    candidate = _pathContext.normalize(_pathContext.absolute(candidate));
    while (!_directoryExists(candidate)) {
      String parent = _pathContext.dirname(candidate);
      if (parent == candidate) {
        throw const NativeDirectoryPickerException(
          'The starting folder is unavailable. $_manualPath',
        );
      }
      candidate = parent;
    }
    return candidate;
  }

  Future<ProcessResult> _linuxPicker(String initialPath) async {
    try {
      return await _runner(
        'zenity',
        <String>[
          '--file-selection',
          '--directory',
          '--title=Choose a build destination folder',
          '--filename=${initialPath.endsWith('/') ? initialPath : '$initialPath/'}',
        ],
        environment: _environment,
        timeout: _dialogTimeout,
      );
    } on ProcessException catch (error) {
      if (error.errorCode != 2) rethrow;
    }
    try {
      return await _runner(
        'kdialog',
        <String>[
          '--title',
          'Choose a build destination folder',
          '--getexistingdirectory',
          initialPath,
        ],
        environment: _environment,
        timeout: _dialogTimeout,
      );
    } on ProcessException catch (error) {
      if (error.errorCode != 2) rethrow;
      throw const NativeDirectoryPickerException(
        'No desktop folder picker is available (zenity or kdialog). $_manualPath',
      );
    }
  }

  static bool _exists(String directory) => Directory(directory).existsSync();

  static Future<ProcessResult> _runProcess(
    String executable,
    List<String> arguments, {
    required Map<String, String> environment,
    required Duration timeout,
  }) async {
    Process process = await Process.start(
      executable,
      arguments,
      environment: environment,
      includeParentEnvironment: false,
      runInShell: false,
    );
    await process.stdin.close();
    try {
      List<Object> output = await Future.wait<Object>(<Future<Object>>[
        process.exitCode,
        process.stdout
            .transform(const Utf8Decoder(allowMalformed: true))
            .join(),
        process.stderr
            .transform(const Utf8Decoder(allowMalformed: true))
            .join(),
      ]).timeout(timeout);
      return ProcessResult(process.pid, output[0] as int, output[1], output[2]);
    } on TimeoutException {
      process.kill();
      await process.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      rethrow;
    }
  }
}
