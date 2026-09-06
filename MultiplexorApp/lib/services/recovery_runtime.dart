import '../models/consumer_profile.dart';
import 'server_ping.dart';

/// Runtime operations needed by recovery transactions, independent of the
/// tmux or Windows host transport.
abstract interface class RecoveryRuntime {
  Future<bool> isRunning(ConsumerProfile profile, String instance);
  Future<void> stopGracefully(ConsumerProfile profile, String instance);
  Future<void> start(ConsumerProfile profile, String instance);
  Future<MinecraftPingResult?> waitUntilReady(
    ConsumerProfile profile,
    String instance,
    Duration timeout,
  );
}
