import '../../services/app_context.dart';
import '../../services/interactive_wizard.dart';

Future<void> handleWizard() async {
  final wizard = InteractiveWizard(
    consumerService: consumerService,
    passthrough: passthroughService,
    pterodactyl: pterodactylService,
    pterodactylSmb: pterodactylSmbService,
    requestedConsumer: appContext.requestedConsumer,
  );
  await wizard.run();
}
