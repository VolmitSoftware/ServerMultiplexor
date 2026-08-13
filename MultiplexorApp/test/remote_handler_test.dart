import 'package:multiplexor/cli/handlers/remote_handler.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_models.dart';
import 'package:test/test.dart';

void main() {
  group('remote creation catalog output', () {
    test('exposes exact image and environment choices for headless create', () {
      final List<String> lines = pterodactylCreationCatalogLines(
        _catalog(
          egg: _egg(
            images: const <String, String>{
              'Java 21': 'ghcr.io/pterodactyl/yolks:java_21',
            },
            variables: const <PterodactylEggVariable>[
              PterodactylEggVariable(
                name: 'Server Jar',
                environmentVariable: 'SERVER_JARFILE',
                defaultValue: 'server.jar',
                rules: 'required|string',
                userEditable: true,
                userViewable: true,
              ),
              PterodactylEggVariable(
                name: 'Secret Token',
                environmentVariable: 'TOKEN',
                defaultValue: '',
                rules: 'required|string',
                userEditable: false,
                userViewable: false,
              ),
            ],
          ),
        ),
      );

      expect(
        lines,
        contains('image\t20\tJava 21\tghcr.io/pterodactyl/yolks:java_21'),
      );
      expect(
        lines,
        contains(
          'variable\t20\tSERVER_JARFILE\trequired-default\teditable\t'
          'default=server.jar\trules=required|string',
        ),
      );
      expect(
        lines,
        contains(
          'variable\t20\tTOKEN\trequired-blank\tfixed\t'
          'default=<blank>\trules=required|string',
        ),
      );
      expect(
        lines.where((String line) => line.startsWith('egg\t')).single,
        endsWith('\tready'),
      );
    });

    test('does not label eggs without an allowed image ready', () {
      final List<String> lines = pterodactylCreationCatalogLines(
        _catalog(egg: _egg(images: const <String, String>{})),
      );

      expect(
        lines.where((String line) => line.startsWith('egg\t')).single,
        endsWith('\tno image'),
      );
    });

    test('sanitizes provider text before writing tab-separated rows', () {
      final List<String> lines = pterodactylCreationCatalogLines(
        _catalog(
          egg: _egg(
            name: 'Paper\nInjected\tColumn',
            images: const <String, String>{'Java\t21': 'image\nvalue'},
          ),
        ),
      );

      expect(lines.any((String line) => line.contains('\n')), isFalse);
      final String imageLine = lines
          .where((String line) => line.startsWith('image\t20\t'))
          .single;
      expect(imageLine, isNot(contains('\n')));
      expect(imageLine, isNot(contains('\tJava\t21\t')));
      expect(imageLine, endsWith('\timage value'));
    });
  });
}

PterodactylCreationCatalog _catalog({required PterodactylEgg egg}) =>
    PterodactylCreationCatalog(
      templates: const <PterodactylApplicationServer>[],
      users: const <PterodactylUser>[
        PterodactylUser(
          id: 1,
          uuid: '00000000-0000-0000-0000-000000000001',
          username: 'operator',
          email: 'operator@example.test',
          firstName: 'Panel',
          lastName: 'Operator',
          isRootAdmin: true,
        ),
      ],
      nodes: const <PterodactylNode>[
        PterodactylNode(
          id: 5,
          uuid: '00000000-0000-0000-0000-000000000005',
          name: 'node-a',
          fqdn: 'node-a.example.test',
          scheme: 'https',
          public: true,
          behindProxy: false,
          maintenanceMode: false,
          memoryMiB: 16384,
          diskMiB: 65536,
          allocatedMemoryMiB: 4096,
          allocatedDiskMiB: 8192,
          daemonPort: 8080,
          sftpPort: 2022,
        ),
      ],
      nests: const <PterodactylNest>[
        PterodactylNest(
          id: 10,
          uuid: '00000000-0000-0000-0000-000000000010',
          name: 'Minecraft',
          author: 'support@example.test',
        ),
      ],
      eggs: <PterodactylEgg>[egg],
      freeAllocationsByNode: const <int, List<PterodactylAllocation>>{
        5: <PterodactylAllocation>[
          PterodactylAllocation(
            id: 50,
            ip: '127.0.0.1',
            port: 25565,
            isAssigned: false,
          ),
        ],
      },
      recommendedOwnerId: 1,
    );

PterodactylEgg _egg({
  String name = 'Paper',
  required Map<String, String> images,
  List<PterodactylEggVariable> variables = const <PterodactylEggVariable>[],
}) => PterodactylEgg(
  id: 20,
  uuid: '00000000-0000-0000-0000-000000000020',
  name: name,
  nestId: 10,
  author: 'support@example.test',
  startup: 'java -jar {{SERVER_JARFILE}}',
  dockerImages: images,
  variables: variables,
);
