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
  ConsumerProfile? _consumerOverride;

  bool get hasLegacyBackend => context.hasLegacyBackend;

  ConsumerProfile get effectiveConsumer =>
      _consumerOverride ??
      context.requestedConsumer ??
      consumerService.readActive();

  void setConsumerOverride(ConsumerProfile? profile) {
    _consumerOverride = profile;
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

  Future<CapturedResult> createIsolatedTransferInstance(
    String name, {
    required String creationToken,
  }) => _native.createIsolatedTransferInstance(
    name,
    creationToken: creationToken,
  );

  bool cleanupPartialTransferInstance(
    String name, {
    required String creationToken,
  }) => _native.cleanupPartialTransferInstance(
    name,
    creationToken: creationToken,
  );

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
