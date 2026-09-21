import '../self_update_release.dart';
import '../self_update_service.dart';

enum MonitorUpdateState {
  unchecked,
  checking,
  current,
  available,
  failed,
  development,
  unsupported,
}

class MonitorUpdate {
  MonitorUpdate(this.service)
    : state = !service.releaseBuild
          ? MonitorUpdateState.development
          : service.platform == null
          ? MonitorUpdateState.unsupported
          : MonitorUpdateState.unchecked;

  final SelfUpdateService service;
  MonitorUpdateState state;
  SelfUpdateRelease? release;
  String? error;

  String get label => switch (state) {
    MonitorUpdateState.unchecked => 'u CHECK FOR UPDATE',
    MonitorUpdateState.checking => 'CHECKING UPDATE',
    MonitorUpdateState.current => 'u UP TO DATE',
    MonitorUpdateState.available => 'u UPDATE v${release!.version.text}',
    MonitorUpdateState.failed => 'u RETRY UPDATE',
    MonitorUpdateState.development => 'u DEVELOPMENT BUILD',
    MonitorUpdateState.unsupported => 'u UPDATE UNAVAILABLE',
  };

  Future<void> check() async {
    if (state == MonitorUpdateState.checking ||
        state == MonitorUpdateState.development ||
        state == MonitorUpdateState.unsupported) {
      return;
    }
    state = MonitorUpdateState.checking;
    error = null;
    try {
      release = await service.check();
      state = release == null
          ? MonitorUpdateState.current
          : MonitorUpdateState.available;
    } catch (failure) {
      release = null;
      error = failure.toString();
      state = MonitorUpdateState.failed;
    }
  }
}
