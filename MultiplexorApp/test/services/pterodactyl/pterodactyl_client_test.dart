import 'dart:convert';
import 'dart:io';

import 'package:multiplexor/services/pterodactyl/pterodactyl_client.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_errors.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_models.dart';
import 'package:test/test.dart';

void main() {
  test('lists typed Client servers and public allocations', () async {
    final _FakeTransport transport = _FakeTransport(<_Reply>[
      _Reply(
        200,
        File(
          'test/services/pterodactyl/fixtures/client_servers.json',
        ).readAsStringSync(),
      ),
    ]);

    final List<PterodactylClientServer> servers = await _client(
      transport,
    ).listAllClientServers();

    expect(servers.single.name, 'Survival');
    expect(servers.single.primaryAllocation?.endpoint, 'mc.example.test:25565');
    expect(transport.requests.single.uri.path, '/control/api/client');
    expect(transport.requests.single.uri.queryParameters['per_page'], '100');
    expect(
      transport.requests.single.headers[HttpHeaders.authorizationHeader],
      'Bearer client-secret',
    );
  });

  test('requests whole-panel inventory with the admin-all scope', () async {
    final _FakeTransport transport = _FakeTransport(<_Reply>[
      _Reply(
        200,
        File(
          'test/services/pterodactyl/fixtures/client_servers.json',
        ).readAsStringSync(),
      ),
    ]);

    await _client(
      transport,
    ).listAllClientServers(scope: PterodactylClientServerScope.adminAll);

    expect(transport.requests.single.uri.queryParameters['type'], 'admin-all');
  });

  test('parses nullable Client server feature limits', () async {
    final Map<String, Object?> fixture =
        jsonDecode(
              File(
                'test/services/pterodactyl/fixtures/client_servers.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    final List<Object?> data = fixture['data']! as List<Object?>;
    final Map<String, Object?> resource = data.single! as Map<String, Object?>;
    final Map<String, Object?> attributes =
        resource['attributes']! as Map<String, Object?>;
    attributes['feature_limits'] = <String, Object?>{
      'databases': null,
      'allocations': null,
      'backups': null,
    };
    final _FakeTransport transport = _FakeTransport(<_Reply>[
      _Reply(200, jsonEncode(fixture)),
    ]);

    final PterodactylFeatureLimits limits = (await _client(
      transport,
    ).listAllClientServers()).single.featureLimits;

    expect(limits.databases, isNull);
    expect(limits.allocations, isNull);
    expect(limits.backups, isNull);
  });

  test('parses resources and sends power and console actions', () async {
    final _FakeTransport transport = _FakeTransport(<_Reply>[
      _Reply(200, _resourceResponse()),
      const _Reply(204, ''),
      const _Reply(204, ''),
    ]);
    final PterodactylClient client = _client(transport);

    final PterodactylResourceUsage usage = await client.getServerResources(
      'abc123',
    );
    await client.sendPowerSignal('abc123', PterodactylPowerSignal.restart);
    await client.sendConsoleCommand('abc123', 'say hello');

    expect(usage.uptime, const Duration(seconds: 4));
    expect(jsonDecode(transport.requests[1].body!), <String, Object?>{
      'signal': 'restart',
    });
    expect(jsonDecode(transport.requests[2].body!), <String, Object?>{
      'command': 'say hello',
    });
  });

  test('gets redacted secure WebSocket credentials', () async {
    final _FakeTransport transport = _FakeTransport(<_Reply>[
      _Reply(
        200,
        File(
          'test/services/pterodactyl/fixtures/websocket.json',
        ).readAsStringSync(),
      ),
    ]);

    final PterodactylWebsocketCredentials credentials = await _client(
      transport,
    ).getServerWebsocketCredentials('abc123');

    expect(
      credentials.socketUri,
      Uri.parse(
        'wss://node.example.test:8080/api/servers/00000000-0000-0000-0000-000000000042/ws',
      ),
    );
    expect(credentials.token, 'eyJhbGciOiJIUzI1NiJ9.fixture.signature');
    expect(credentials.toString(), contains('[REDACTED]'));
    expect(credentials.toString(), isNot(contains(credentials.token)));
    expect(
      transport.requests.single.uri.path,
      '/control/api/client/servers/abc123/websocket',
    );
    expect(
      transport.requests.single.headers[HttpHeaders.authorizationHeader],
      'Bearer client-secret',
    );
  });

  test('rejects insecure WebSocket responses without leaking their token', () {
    const String responseToken = 'one-time-token-do-not-leak';
    final _FakeTransport transport = _FakeTransport(<_Reply>[
      _Reply(
        200,
        jsonEncode(<String, Object?>{
          'data': <String, Object?>{
            'token': responseToken,
            'socket': 'ws://127.0.0.1:8080/api/servers/server/ws',
          },
        }),
      ),
    ]);

    expect(
      () => _client(transport).getServerWebsocketCredentials('abc123'),
      throwsA(
        isA<PterodactylProtocolException>().having(
          (PterodactylProtocolException error) => error.toString(),
          'text',
          isNot(contains(responseToken)),
        ),
      ),
    );
  });

  test(
    'gets the Client account and manages canonical SSH public keys',
    () async {
      final String canonicalKey = PterodactylAccountSshKey.normalizePublicKey(
        _ed25519PublicKey,
      );
      final String sshKeyResponse = jsonEncode(<String, Object?>{
        'object': 'ssh_key',
        'attributes': _sshKeyAttributes(canonicalKey),
      });
      final _FakeTransport transport = _FakeTransport(<_Reply>[
        _Reply(
          200,
          jsonEncode(<String, Object?>{
            'object': 'user',
            'attributes': <String, Object?>{'username': 'panel-user'},
          }),
        ),
        _Reply(
          200,
          jsonEncode(<String, Object?>{
            'object': 'list',
            'data': <Object?>[
              jsonDecode(sshKeyResponse) as Map<String, Object?>,
            ],
          }),
        ),
        _Reply(200, sshKeyResponse),
      ]);
      final PterodactylClient client = _client(transport);

      final PterodactylAccount account = await client.getAccount();
      final List<PterodactylAccountSshKey> keys = await client
          .listAccountSshKeys();
      final PterodactylAccountSshKey created = await client.createAccountSshKey(
        name: '  Multiplexor SMB  ',
        publicKey: _ed25519PublicKey,
      );

      expect(account.username, 'panel-user');
      expect(keys.single.publicKey, canonicalKey);
      expect(created.fingerprint, 'SHA256:fixture');
      expect(transport.requests.map((request) => request.uri.path), <String>[
        '/control/api/client/account',
        '/control/api/client/account/ssh-keys',
        '/control/api/client/account/ssh-keys',
      ]);
      expect(jsonDecode(transport.requests[2].body!), <String, Object?>{
        'name': 'Multiplexor SMB',
        'public_key': canonicalKey,
      });
      expect(
        transport.requests.every(
          (PterodactylTransportRequest request) =>
              request.headers[HttpHeaders.authorizationHeader] ==
              'Bearer client-secret',
        ),
        isTrue,
      );
    },
  );

  test('gets template fields and creates an Application server', () async {
    final String response = jsonEncode(<String, Object?>{
      'object': 'server',
      'attributes': _applicationServerAttributes(),
    });
    final _FakeTransport transport = _FakeTransport(<_Reply>[
      _Reply(200, response),
      _Reply(201, response),
    ]);
    final PterodactylClient client = _client(transport);

    final PterodactylApplicationServer template = await client
        .getApplicationServer(9);
    await client.createApplicationServer(
      PterodactylCreateServerRequest(
        name: 'Clone',
        ownerId: template.ownerId,
        eggId: template.eggId,
        dockerImage: template.image,
        startup: template.startup,
        environment: template.environment,
        limits: template.limits,
        featureLimits: template.featureLimits,
        defaultAllocationId: 77,
      ),
    );

    expect(template.startup, 'java -jar server.jar');
    expect(template.environment['SERVER_JARFILE'], 'server.jar');
    expect(template.environment['P_SERVER_ALLOCATION_LIMIT'], '2');
    expect(template.featureLimits.databases, isNull);
    expect(template.featureLimits.allocations, isNull);
    expect(template.featureLimits.backups, isNull);
    final Map<String, Object?> payload =
        jsonDecode(transport.requests[1].body!) as Map<String, Object?>;
    expect(payload['allocation'], <String, Object?>{'default': 77});
    expect(payload['environment'], template.environment);
    expect(payload['feature_limits'], <String, Object?>{
      'databases': null,
      'allocations': null,
      'backups': null,
    });
    expect(
      transport.requests[1].headers[HttpHeaders.authorizationHeader],
      'Bearer application-secret',
    );
  });

  test('reads server permissions and gates Client settings metadata', () async {
    final Map<String, Object?> attributes = _clientServerAttributes();
    final _FakeTransport transport = _FakeTransport(<_Reply>[
      _Reply(
        200,
        jsonEncode(<String, Object?>{
          'object': 'server',
          'attributes': attributes,
          'meta': <String, Object?>{
            'is_server_owner': false,
            'user_permissions': <String>['settings.rename', 'startup.update'],
          },
        }),
      ),
    ]);

    final PterodactylClientServerAccess access = await _client(
      transport,
    ).getClientServerAccess('abc123');

    expect(access.isOwner, isFalse);
    expect(access.allows(PterodactylServerPermission.settingsRename), isTrue);
    expect(
      access.allows(PterodactylServerPermission.settingsReinstall),
      isFalse,
    );
  });

  test('reads paginated server activity newest first', () async {
    final _FakeTransport transport = _FakeTransport(<_Reply>[
      _Reply(
        200,
        jsonEncode(<String, Object?>{
          'object': 'list',
          'data': <Object?>[
            <String, Object?>{
              'object': 'activity_log',
              'attributes': <String, Object?>{
                'id': 'event-id',
                'batch': null,
                'event': 'server:settings.rename',
                'is_api': true,
                'ip': null,
                'description': null,
                'properties': null,
                'has_additional_metadata': false,
                'timestamp': '2026-08-12T16:30:00+00:00',
              },
            },
          ],
          'meta': <String, Object?>{
            'pagination': <String, Object?>{
              'total': 1,
              'count': 1,
              'per_page': 10,
              'current_page': 2,
              'total_pages': 2,
            },
          },
        }),
      ),
    ]);

    final PterodactylPage<PterodactylActivity> page = await _client(
      transport,
    ).listServerActivity('abc123', page: 2, perPage: 10);

    expect(page.items.single.event, 'server:settings.rename');
    expect(page.items.single.description, isEmpty);
    expect(page.items.single.properties, isEmpty);
    expect(transport.requests.single.uri.queryParameters, <String, String>{
      'page': '2',
      'per_page': '10',
      'sort': '-timestamp',
    });
  });

  test('parses startup variables and Docker image metadata', () async {
    final _FakeTransport transport = _FakeTransport(<_Reply>[
      _Reply(
        200,
        jsonEncode(<String, Object?>{
          'object': 'list',
          'data': <Object?>[
            <String, Object?>{
              'object': 'egg_variable',
              'attributes': _startupVariableAttributes(),
            },
          ],
          'meta': <String, Object?>{
            'startup_command': 'java -jar paper.jar',
            'raw_startup_command': 'java -jar {{SERVER_JARFILE}}',
            'docker_images': <String, Object?>{
              'Java 21': 'ghcr.io/pterodactyl/yolks:java_21',
              'Java 17': 'ghcr.io/pterodactyl/yolks:java_17',
            },
          },
        }),
      ),
    ]);

    final PterodactylServerStartup startup = await _client(
      transport,
    ).getServerStartup('abc123');

    expect(startup.startupCommand, 'java -jar paper.jar');
    expect(startup.rawStartupCommand, 'java -jar {{SERVER_JARFILE}}');
    expect(
      startup.dockerImages['Java 21'],
      'ghcr.io/pterodactyl/yolks:java_21',
    );
    expect(startup.variables.single.environmentVariable, 'SERVER_JARFILE');
  });

  test('sends Client lifecycle and editable startup operations', () async {
    final _FakeTransport transport = _FakeTransport(<_Reply>[
      const _Reply(204, ''),
      const _Reply(202, ''),
      const _Reply(204, ''),
      _Reply(
        200,
        jsonEncode(<String, Object?>{
          'object': 'egg_variable',
          'attributes': _startupVariableAttributes(),
          'meta': <String, Object?>{
            'startup_command': 'java -jar paper.jar',
            'raw_startup_command': 'java -jar {{SERVER_JARFILE}}',
          },
        }),
      ),
    ]);
    final PterodactylClient client = _client(transport);

    await client.renameServer(
      'abc123',
      name: 'Renamed',
      description: 'New description',
    );
    await client.reinstallServer('abc123');
    await client.setServerDockerImage('abc123', 'java:21');
    final PterodactylStartupVariable variable = await client
        .updateServerStartupVariable(
          'abc123',
          key: 'SERVER_JARFILE',
          value: 'paper.jar',
        );

    expect(variable.serverValue, 'paper.jar');
    expect(transport.requests.map((request) => request.method), <String>[
      'POST',
      'POST',
      'PUT',
      'PUT',
    ]);
    expect(jsonDecode(transport.requests[0].body!), <String, Object?>{
      'name': 'Renamed',
      'description': 'New description',
    });
    expect(jsonDecode(transport.requests[3].body!), <String, Object?>{
      'key': 'SERVER_JARFILE',
      'value': 'paper.jar',
    });
  });

  test('sends complete Application lifecycle update payloads', () async {
    final String response = jsonEncode(<String, Object?>{
      'object': 'server',
      'attributes': _applicationServerAttributes(),
    });
    final _FakeTransport transport = _FakeTransport(<_Reply>[
      _Reply(200, response),
      _Reply(200, response),
      _Reply(200, response),
      const _Reply(204, ''),
      const _Reply(204, ''),
    ]);
    final PterodactylClient client = _client(transport);
    final PterodactylApplicationServer current =
        PterodactylApplicationServer.fromJson(_applicationServerAttributes());

    await client.updateApplicationServerDetails(
      current.id,
      PterodactylUpdateServerDetailsRequest.fromServer(
        current,
        name: 'Renamed',
      ),
    );
    await client.updateApplicationServerBuild(
      current.id,
      PterodactylUpdateServerBuildRequest(
        defaultAllocationId: current.allocationId,
        limits: current.limits,
        featureLimits: current.featureLimits,
        oomDisabled: current.limits.oomDisabled,
      ),
    );
    await client.updateApplicationServerStartup(
      current.id,
      PterodactylUpdateServerStartupRequest(
        startup: current.startup,
        environment: current.environment,
        eggId: current.eggId,
        dockerImage: current.image,
        skipScripts: current.skipScripts,
      ),
    );
    await client.reinstallApplicationServer(current.id);
    await client.deleteApplicationServer(current.id, force: true);

    final Map<String, Object?> build =
        jsonDecode(transport.requests[1].body!) as Map<String, Object?>;
    expect(jsonDecode(transport.requests[0].body!), <String, Object?>{
      'external_id': null,
      'name': 'Renamed',
      'user': 5,
      'description': '',
    });
    expect(build['limits'], <String, Object?>{
      ...current.limits.toJson(),
      'threads': null,
    });
    expect(build['feature_limits'], current.featureLimits.toJson());
    expect(jsonDecode(transport.requests[2].body!), <String, Object?>{
      'startup': 'java -jar server.jar',
      'environment': <String, Object?>{
        'SERVER_JARFILE': 'server.jar',
        'P_SERVER_ALLOCATION_LIMIT': '2',
      },
      'egg': 2,
      'image': 'ghcr.io/pterodactyl/yolks:java_21',
      'skip_scripts': false,
    });
    expect(transport.requests.map((request) => request.uri.path), <String>[
      '/control/api/application/servers/9/details',
      '/control/api/application/servers/9/build',
      '/control/api/application/servers/9/startup',
      '/control/api/application/servers/9/reinstall',
      '/control/api/application/servers/9/force',
    ]);
  });

  test('marks free allocations and formats IPv6 endpoints', () async {
    final _FakeTransport transport = _FakeTransport(<_Reply>[
      _Reply(200, _allocationResponse()),
    ]);

    final PterodactylAllocation allocation = (await _client(
      transport,
    ).listNodeAllocations(3)).items.single;

    expect(allocation.isFree, isTrue);
    expect(allocation.endpoint, '[2001:db8::1]:25565');
  });

  test('requires HTTPS and does not expose response bodies', () async {
    expect(
      () => PterodactylClient(
        baseUri: Uri.parse('http://panel.example.test'),
        clientKey: 'secret',
      ),
      throwsA(isA<PterodactylConfigurationException>()),
    );
    final _FakeTransport transport = _FakeTransport(<_Reply>[
      const _Reply(500, 'environment PASSWORD=do-not-leak'),
    ]);

    expect(
      () => _client(transport).getServerResources('abc123'),
      throwsA(
        isA<PterodactylApiException>()
            .having(
              (PterodactylApiException error) => error.toString(),
              'text',
              isNot(contains('do-not-leak')),
            )
            .having(
              (PterodactylApiException error) => error.toString(),
              'text',
              isNot(contains('client-secret')),
            ),
      ),
    );
  });

  test('SSH key failures never expose request or response key material', () {
    const String responseKey = 'ssh-ed25519 response-key-do-not-leak';
    final _FakeTransport transport = _FakeTransport(<_Reply>[
      const _Reply(422, 'public_key=ssh-ed25519 response-key-do-not-leak'),
    ]);

    expect(
      () => _client(
        transport,
      ).createAccountSshKey(name: 'Multiplexor', publicKey: _ed25519PublicKey),
      throwsA(
        isA<PterodactylApiException>()
            .having(
              (PterodactylApiException error) => error.toString(),
              'text',
              isNot(contains(responseKey)),
            )
            .having(
              (PterodactylApiException error) => error.toString(),
              'text',
              isNot(contains(_ed25519PublicKey)),
            ),
      ),
    );
  });

  test('Dart IO transport does not follow redirects', () async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    int destinationHits = 0;
    server.listen((HttpRequest request) async {
      if (request.uri.path == '/redirect') {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          '/destination',
        );
      } else {
        destinationHits++;
      }
      await request.response.close();
    });
    final DartIoPterodactylTransport transport = DartIoPterodactylTransport();
    addTearDown(() async {
      transport.close();
      await server.close(force: true);
    });

    final PterodactylTransportResponse response = await transport.send(
      PterodactylTransportRequest(
        method: 'GET',
        uri: Uri.parse(
          'http://${server.address.address}:${server.port}/redirect',
        ),
        headers: const <String, String>{},
      ),
    );

    expect(response.statusCode, HttpStatus.found);
    expect(destinationHits, 0);
  });
}

PterodactylClient _client(_FakeTransport transport) => PterodactylClient(
  baseUri: Uri.parse('https://panel.example.test/control/'),
  clientKey: 'client-secret',
  applicationKey: 'application-secret',
  transport: transport,
);

String _resourceResponse() => jsonEncode(<String, Object?>{
  'object': 'stats',
  'attributes': <String, Object?>{
    'current_state': 'running',
    'is_suspended': false,
    'resources': <String, Object?>{
      'memory_bytes': 1024,
      'cpu_absolute': 12.5,
      'disk_bytes': 2048,
      'network_rx_bytes': 20,
      'network_tx_bytes': 30,
      'uptime': 4000,
    },
  },
});

String _allocationResponse() => jsonEncode(<String, Object?>{
  'object': 'list',
  'data': <Object?>[
    <String, Object?>{
      'attributes': <String, Object?>{
        'id': 77,
        'ip': '2001:db8::1',
        'alias': null,
        'port': 25565,
        'notes': null,
        'assigned': false,
      },
    },
  ],
  'meta': <String, Object?>{
    'pagination': <String, Object?>{
      'total': 1,
      'count': 1,
      'per_page': 100,
      'current_page': 1,
      'total_pages': 1,
    },
  },
});

Map<String, Object?> _applicationServerAttributes() => <String, Object?>{
  'id': 9,
  'external_id': null,
  'uuid': '00000000-0000-0000-0000-000000000009',
  'identifier': 'server09',
  'name': 'Template',
  'description': '',
  'status': null,
  'user': 5,
  'node': 3,
  'allocation': 77,
  'nest': 1,
  'egg': 2,
  'limits': <String, Object?>{
    'memory': 4096,
    'swap': 0,
    'disk': 10000,
    'io': 500,
    'cpu': 200,
    'threads': null,
    'oom_disabled': false,
  },
  'feature_limits': <String, Object?>{
    'databases': null,
    'allocations': null,
    'backups': null,
  },
  'container': <String, Object?>{
    'image': 'ghcr.io/pterodactyl/yolks:java_21',
    'startup_command': 'java -jar server.jar',
    'environment': <String, Object?>{
      'SERVER_JARFILE': 'server.jar',
      'P_SERVER_ALLOCATION_LIMIT': 2,
    },
    'skip_scripts': false,
  },
};

Map<String, Object?> _clientServerAttributes() => <String, Object?>{
  'identifier': 'abc123',
  'internal_id': 42,
  'uuid': '00000000-0000-0000-0000-000000000042',
  'name': 'Survival',
  'node': 'node-a',
  'description': 'Primary server',
  'server_owner': false,
  'is_node_under_maintenance': false,
  'status': null,
  'sftp_details': <String, Object?>{'ip': 'panel.example.test', 'port': 2022},
  'limits': <String, Object?>{
    'memory': 4096,
    'swap': 0,
    'disk': 12000,
    'io': 500,
    'cpu': 200,
    'threads': null,
    'oom_disabled': false,
  },
  'feature_limits': <String, Object?>{
    'databases': 2,
    'allocations': 2,
    'backups': 3,
  },
  'relationships': <String, Object?>{
    'allocations': <String, Object?>{'data': <Object?>[]},
    'variables': <String, Object?>{'data': <Object?>[]},
  },
};

Map<String, Object?> _startupVariableAttributes() => <String, Object?>{
  'name': 'Server Jar File',
  'description': 'Jar launched by the server',
  'env_variable': 'SERVER_JARFILE',
  'default_value': 'server.jar',
  'server_value': 'paper.jar',
  'is_editable': true,
  'rules': 'required|string|max:64',
};

Map<String, Object?> _sshKeyAttributes(String publicKey) => <String, Object?>{
  'name': 'Multiplexor SMB',
  'fingerprint': 'SHA256:fixture',
  'public_key': publicKey,
  'created_at': '2026-08-12T12:00:00+00:00',
};

const String _ed25519PublicKey =
    'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOaXIq09NH4a93EVdrvHYiZ67Wj+'
    'GBEBQ9ou4W0qSYm2 multiplexor@test';

final class _Reply {
  const _Reply(this.statusCode, this.body);
  final int statusCode;
  final String body;
}

final class _FakeTransport implements PterodactylTransport {
  _FakeTransport(this._replies);
  final List<_Reply> _replies;
  final List<PterodactylTransportRequest> requests =
      <PterodactylTransportRequest>[];

  @override
  Future<PterodactylTransportResponse> send(
    PterodactylTransportRequest request,
  ) async {
    requests.add(request);
    final _Reply reply = _replies.removeAt(0);
    return PterodactylTransportResponse(
      statusCode: reply.statusCode,
      body: reply.body,
    );
  }

  @override
  void close() {}
}
