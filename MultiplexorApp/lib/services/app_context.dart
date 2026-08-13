import '../models/consumer_profile.dart';
import 'consumer_service.dart';
import 'environment_service.dart';
import 'manager_context.dart';
import 'passthrough_service.dart';
import 'pterodactyl/pterodactyl_credential_store.dart';
import 'pterodactyl/pterodactyl_history_service.dart';
import 'pterodactyl/pterodactyl_profile_store.dart';
import 'pterodactyl/pterodactyl_service.dart';
import 'pterodactyl/pterodactyl_smb_service.dart';

late final ManagerContext appContext;
late final ConsumerService consumerService;
late final EnvironmentService environmentService;
late final PassthroughService passthroughService;
late final PterodactylService pterodactylService;
late final PterodactylHistoryService pterodactylHistoryService;
late final PterodactylSmbService pterodactylSmbService;

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
  pterodactylService = PterodactylService(
    profileStore: PterodactylProfileStore(appContext.metadataDir),
    credentialStore: PterodactylCredentialStore(appContext.metadataDir),
  );
  pterodactylHistoryService = PterodactylHistoryService(
    appContext.globalStateDir,
  );
  pterodactylSmbService = PterodactylSmbService(
    metadataDirectoryPath: appContext.metadataDir,
    loadProfile: pterodactylService.profile,
    loadServers: pterodactylService.listServers,
    loadPanelUsername: pterodactylService.accountUsername,
    ensureSshPublicKey: pterodactylService.ensureAccountSshPublicKey,
  );
}
