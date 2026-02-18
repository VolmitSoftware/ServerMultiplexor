import '../models/consumer_profile.dart';
import 'consumer_service.dart';
import 'environment_service.dart';
import 'manager_context.dart';
import 'passthrough_service.dart';

late final ManagerContext appContext;
late final ConsumerService consumerService;
late final EnvironmentService environmentService;
late final PassthroughService passthroughService;

void initializeAppContext({
  String? requestedConsumer,
  bool verbose = false,
  String? rootOverride,
}) {
  final rootDir = ManagerContext.detectRoot(explicitRoot: rootOverride);
  final profile = ConsumerProfile.parse(requestedConsumer);

  appContext = ManagerContext(
    rootDir: rootDir,
    verbose: verbose,
    requestedConsumer: profile,
  );

  consumerService = ConsumerService(appContext);
  environmentService = EnvironmentService(
    context: appContext,
    consumerService: consumerService,
  );
  environmentService.bootstrap();
  passthroughService = PassthroughService(appContext, consumerService);
}
