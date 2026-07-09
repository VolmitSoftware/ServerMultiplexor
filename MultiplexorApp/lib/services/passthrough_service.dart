import '../models/consumer_profile.dart';
import '../utils/process_runner.dart';
import 'consumer_service.dart';
import 'manager_context.dart';
import 'native_command_service.dart';

class PassthroughService {
  PassthroughService(
    this.context,
    this.consumerService, {
    NativeCommandService? native,
  }) : _native =
           native ??
           NativeCommandService(
             context: context,
             consumerService: consumerService,
           );

  final ManagerContext context;
  final ConsumerService consumerService;
  final NativeCommandService _native;

  bool get hasLegacyBackend => context.hasLegacyBackend;

  void setConsumerOverride(ConsumerProfile? profile) {
    _native.setConsumerOverride(profile);
  }

  /// Closes pooled RCON connections held for live dashboard metrics.
  void disposeRcon() {
    _native.disposeRcon();
  }

  Future<int> run(List<String> args) async {
    final native = await _native.execute(args, stream: true);
    return native.exitCode;
  }

  Future<CapturedResult> capture(List<String> args) async {
    return _native.execute(args, stream: false);
  }

  Future<String?> captureStdoutLine(List<String> args) async {
    final result = await capture(args);
    if (!result.success) {
      return null;
    }

    final lines = result.stdout
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);

    if (lines.isEmpty) {
      return null;
    }

    return lines.last;
  }
}
