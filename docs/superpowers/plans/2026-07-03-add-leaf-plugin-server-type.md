# Add Leaf Plugin-Family Server Type — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add [Leaf](https://github.com/Winds-Studio/Leaf) (a high-performance Paper fork) as a first-class server-software type owned by the `plugin` consumer, downloadable from Leaf's Paper-v2-style API, with full Paper-family parity (build, version discovery, repo sync, wizard, help, docs).

**Architecture:** Leaf reuses `ConsumerProfile.plugin` — no new consumer. A new `_buildDownloadLeaf` fetches jars from `api.leafmc.one/v2`, and two new resolvers (`_resolveLeafMcVersions`, `_resolveLatestLeafMcVersion`) discover versions. Everywhere the codebase enumerates the plugin-family server types (`paper|purpur|folia|canvas|spigot`), `leaf` is added. Downstream jar/launch/metadata plumbing is already type-parameterized and needs no change.

**Tech Stack:** Dart (^3.10.0), `package:test`, existing `_httpGetJsonObject` / `_downloadToFile` HTTP helpers, tmux runtime (unaffected).

## Global Constraints

- **Do NOT run any git write command** (`git add`/`commit`/`push`). Repo policy: the user commits manually. End each task at green verification — no commit steps.
- **Strongly type** all new Dart; match the style of the adjacent `_buildDownloadPaperLike` / `_buildDownloadPurpur` methods.
- **No backwards-compat shims.** Direct edits only.
- **README stays in lockstep** with the CLI (project CLAUDE.md hard rule) — docs task is required, not optional.
- **Validation path:** `dart analyze` → `dart test` → CLI smoke test via `./start.sh`, all from `MultiplexorApp/`.
- Leaf's stable channel string is `"default"` (not Paper's `"STABLE"`); its download entry is `downloads.primary.name` (not Paper's `downloads.application`). These are baked into Task 1's code — do not "fix" them to match Paper.
- Leaf platform color code: `'2'` (dark green). Leaf label: `Leaf`.

---

### Task 1: Core service wiring + Leaf download/version logic

All edits in `MultiplexorApp/lib/services/native_command_service.dart`. One hermetic test drives the enumeration/ownership wiring; the network download is verified by smoke test in Task 5 (mirrors the codebase's existing practice — no downloader is unit-tested).

**Files:**
- Modify: `MultiplexorApp/lib/services/native_command_service.dart`
- Test: `MultiplexorApp/test/native_command_service_test.dart`

**Interfaces:**
- Produces (used by later tasks + dispatch): server type string `'leaf'` accepted by `_isKnownServerType`, mapped to `ConsumerProfile.plugin` by `_consumerForServerType`, built by `_buildDownloadLeaf(ConsumerProfile, String mc, _NativeIoBuffer) → Future<String>`, versions via `_resolveLeafMcVersions() → Future<List<String>>` and `_resolveLatestLeafMcVersion() → Future<String?>`.
- Consumes: existing `_httpGetJsonObject(String) → Future<Map<String,dynamic>>`, `_downloadToFile(String url, String out, {required _NativeIoBuffer io})`, `_buildDir`, `_registerBuiltJar`, `_stableSortedMcVersions(Iterable)`, `setConsumerOverride(ConsumerProfile?)`.

- [ ] **Step 1: Write the failing test**

Add to `MultiplexorApp/test/native_command_service_test.dart`. First add the import near the top (after line 5):

```dart
import 'package:multiplexor/models/consumer_profile.dart';
```

Then add this test inside the existing `group('NativeCommandService consumer ownership', ...)` block (after the `build refuses modded types` test, before the closing `});` of the group):

```dart
    test('build refuses leaf (a plugin type) in a modded consumer', () async {
      service.setConsumerOverride(ConsumerProfile.forge);

      final result = await service.execute(<String>[
        'build',
        'leaf',
      ], stream: false);

      expect(result.exitCode, 2);
      expect(
        result.stderr,
        contains('Server type "leaf" belongs to the plugin consumer'),
      );
      expect(result.stderr, contains('--consumer plugin build leaf'));
    });
```

Why this proves the wiring: under a non-plugin consumer, reaching the ownership error requires (a) the `build` dispatcher to have a `case 'leaf':` (else it hits the usage `default`), (b) `_isKnownServerType('leaf') == true` (else `_ensureConsumerOwnsServerType` no-ops and falls through to a network build), and (c) `_consumerForServerType('leaf') == plugin` (else a "Unknown server type for routing" error). It is fully hermetic — the ownership check throws before any network call.

- [ ] **Step 2: Run the test — verify it FAILS**

Run: `cd MultiplexorApp && dart test test/native_command_service_test.dart --plain-name "build refuses leaf"`
Expected: FAIL — stderr is `Usage: build <...>` (the dispatcher's default), so `contains('belongs to the plugin consumer')` does not match.

- [ ] **Step 3: Implement all `native_command_service.dart` changes**

Apply each edit below (exact strings). They must all land together for `dart analyze` to pass.

**3a — `_buildTarget` dispatch (add case near the `paper`/`folia` case, ~line 3769):**

```dart
      case 'purpur':
        return _buildDownloadPurpur(profile, mc, io);
      case 'leaf':
        return _buildDownloadLeaf(profile, mc, io);
      case 'canvas':
        return _buildDownloadCanvas(profile, mc, io);
```

**3b — New `_buildDownloadLeaf` method (insert immediately after `_buildDownloadPurpur`, ~line 3898):**

```dart
  Future<String> _buildDownloadLeaf(
    ConsumerProfile profile,
    String mc,
    _NativeIoBuffer io,
  ) async {
    final payload = await _httpGetJsonObject(
      'https://api.leafmc.one/v2/projects/leaf/versions/$mc/builds',
    );
    final builds = payload['builds'];
    if (builds is! List || builds.isEmpty) {
      throw _NativeCommandException('No Leaf builds available for mc=$mc', 1);
    }

    // Prefer the highest stable ("default" channel) build, falling back to the
    // highest build of any channel when a version only has experimental builds.
    // Leaf's v2 API exposes the jar name under downloads.primary.name (Paper
    // uses downloads.application), so the URL is assembled explicitly.
    var bestStableBuild = -1;
    String? stableJarName;
    var bestAnyBuild = -1;
    String? anyJarName;
    for (final raw in builds) {
      if (raw is! Map) {
        continue;
      }
      final build = raw['build'];
      final downloads = raw['downloads'];
      if (build is! num || downloads is! Map) {
        continue;
      }
      final primary = downloads['primary'];
      if (primary is! Map) {
        continue;
      }
      final jarName = primary['name'];
      if (jarName is! String || jarName.trim().isEmpty) {
        continue;
      }
      final buildNumber = build.toInt();
      if (buildNumber > bestAnyBuild) {
        bestAnyBuild = buildNumber;
        anyJarName = jarName.trim();
      }
      final isStable =
          raw['channel']?.toString().trim().toLowerCase() == 'default';
      if (isStable && buildNumber > bestStableBuild) {
        bestStableBuild = buildNumber;
        stableJarName = jarName.trim();
      }
    }

    final bestBuild = bestStableBuild > 0 ? bestStableBuild : bestAnyBuild;
    final jarName = bestStableBuild > 0 ? stableJarName : anyJarName;
    if (bestBuild <= 0 || jarName == null) {
      throw _NativeCommandException(
        'No downloadable Leaf build found for mc=$mc',
        1,
      );
    }

    final downloadUrl =
        'https://api.leafmc.one/v2/projects/leaf/versions/$mc/builds/$bestBuild/downloads/$jarName';
    final output = p.join(_buildDir(profile, 'leaf'), 'leaf-$mc-$bestBuild.jar');
    await _downloadToFile(downloadUrl, output, io: io);
    _registerBuiltJar(profile, 'leaf', output);
    io.write('[OK] Cached leaf build $bestBuild for mc=$mc');
    io.write('[INFO] Jar: $output');
    return output;
  }
```

**3c — New version resolvers (insert after `_resolvePurpurMcVersions`, ~line 4669):**

```dart
  Future<List<String>> _resolveLeafMcVersions() async {
    final payload = await _httpGetJsonObject(
      'https://api.leafmc.one/v2/projects/leaf',
    );
    final versionsRaw = payload['versions'];
    if (versionsRaw is! List) {
      return const <String>[];
    }
    return _stableSortedMcVersions(versionsRaw);
  }

  Future<String?> _resolveLatestLeafMcVersion() async {
    final versions = await _resolveLeafMcVersions();
    return versions.isEmpty ? null : versions.last;
  }
```

**3d — `_resolveSupportedMcVersions` switch (~line 4552):**

```dart
      case 'purpur':
        return _resolvePurpurMcVersions();
      case 'leaf':
        return _resolveLeafMcVersions();
      case 'canvas':
        return _resolveCanvasMcVersions();
```

**3e — `_resolveLatestSupportedMcVersion` switch (~line 4608):**

```dart
        case 'purpur':
          return _resolveLatestPurpurMcVersion();
        case 'leaf':
          return _resolveLatestLeafMcVersion();
        case 'canvas':
          return _resolveLatestCanvasMcVersion();
```

**3f — `_isKnownServerType` switch (~line 8319): add `case 'leaf':` to the true group:**

```dart
      case 'paper':
      case 'purpur':
      case 'folia':
      case 'canvas':
      case 'leaf':
      case 'spigot':
```

**3g — `_consumerForServerType` plugin block (~line 8305): add `case 'leaf':`:**

```dart
      case 'paper':
      case 'purpur':
      case 'folia':
      case 'canvas':
      case 'leaf':
      case 'spigot':
        return ConsumerProfile.plugin;
```

**3h — `build` sub-command dispatcher (~line 1477): add `case 'leaf':`:**

```dart
      case 'paper':
      case 'purpur':
      case 'folia':
      case 'canvas':
      case 'leaf':
      case 'spigot':
      case 'forge':
      case 'fabric':
      case 'neoforge':
        final buildOptions = _parseOptions(rest);
        _ensureConsumerOwnsServerType(profile, sub, command: 'build $sub');
        await _buildTarget(profile, sub, buildOptions, io);
        return 0;
```

**3i — `_allBuildTypes` list (~line 8705): insert `'leaf'` after `'canvas'`:**

```dart
  static const List<String> _allBuildTypes = <String>[
    'paper',
    'purpur',
    'spigot',
    'folia',
    'canvas',
    'leaf',
    'forge',
    'fabric',
    'neoforge',
  ];
```

**3j — `_instancePlatformLabel` (~line 7164): add Leaf:**

```dart
      'canvas' => 'Canvas',
      'leaf' => 'Leaf',
      'spigot' => 'Spigot',
```

**3k — `_instancePlatformPrimaryColor` (~line 7178): add Leaf (dark green `'2'`):**

```dart
      'canvas' => 'e',
      'leaf' => '2',
      'spigot' => '6',
```

**3l — `_repoUrl` (~line 8355): add Leaf repo:**

```dart
      'canvas' => 'https://github.com/CraftCanvasMC/Canvas.git',
      'leaf' => 'https://github.com/Winds-Studio/Leaf.git',
```

**3m — `_reposSync` target switch (~line 3348): add leaf to `all` + single-target + usage:**

```dart
    final types = switch (target) {
      'all' => const <String>['paper', 'purpur', 'folia', 'canvas', 'leaf'],
      'paper' || 'purpur' || 'folia' || 'canvas' || 'leaf' => <String>[target],
      'forge' || 'fabric' || 'neoforge' => throw _NativeCommandException(
        '$target resolves versions from upstream metadata APIs; there is no repo to sync. Use: build $target [--mc <version>]',
        2,
      ),
      _ => throw _NativeCommandException(
        'Usage: repos sync [all|paper|purpur|folia|canvas|leaf]',
        2,
      ),
    };
```

**3n — `_resolveLatestMcVersion` repo-fallback set (~line 4511):**

```dart
    if (<String>{'paper', 'purpur', 'folia', 'canvas', 'leaf'}.contains(normalized)) {
```

**3o — `_buildSupportedVersions` repo-fallback set (~line 4540):**

```dart
    if (<String>{'paper', 'purpur', 'folia', 'canvas', 'leaf'}.contains(type)) {
```

**3p — `_dispatchRepos` usage string (~line 1509):**

```dart
          'Usage: repos sync [all|paper|purpur|folia|canvas|leaf]',
```

**3q — build usage strings — insert `leaf` after `canvas` in each:**

- ~line 1462: `'Usage: build latest <paper|purpur|folia|canvas|leaf|forge|fabric|neoforge|spigot>'`
- ~line 1491: `'Usage: build <paper|purpur|folia|canvas|leaf|spigot|forge|fabric|neoforge|latest|list|list-all|versions|test-latest>'`
- ~line 4440: `'Usage: build list-all [paper|purpur|spigot|folia|canvas|leaf|forge|fabric|neoforge]'`
- ~line 4486: `'Usage: build versions [paper|purpur|spigot|folia|canvas|leaf|forge|fabric|neoforge]'`

- [ ] **Step 4: Run the test — verify it PASSES, then analyze**

Run: `cd MultiplexorApp && dart test test/native_command_service_test.dart --plain-name "build refuses leaf"`
Expected: PASS.
Run: `cd MultiplexorApp && dart analyze`
Expected: `No issues found!` (or no new issues introduced by these edits).

---

### Task 2: CLI entrypoints

Two parsers separate from the service must also learn `leaf`, or `./start.sh build leaf` never reaches the service.

**Files:**
- Modify: `MultiplexorApp/bin/main.dart:159-168`
- Modify: `MultiplexorApp/lib/cli/runner.dart:113,146-153`

**Interfaces:**
- Consumes: `handleBuildTarget(String type, Map)` (unchanged); the `'leaf'` string from Task 1.

- [ ] **Step 1: Add `leaf` to the build-targets set in `bin/main.dart` (~line 159)**

```dart
      const targets = <String>{
        'paper',
        'purpur',
        'folia',
        'canvas',
        'leaf',
        'spigot',
        'forge',
        'fabric',
        'neoforge',
      };
```

- [ ] **Step 2: Add `case 'leaf':` to `_runBuild` in `runner.dart` (~line 146)**

```dart
    case 'paper':
    case 'purpur':
    case 'folia':
    case 'canvas':
    case 'leaf':
    case 'spigot':
    case 'forge':
    case 'fabric':
    case 'neoforge':
      await handleBuildTarget(sub, <String, dynamic>{
        'mc': parsed.option('mc') ?? parsed.positionalOrNull(0),
        'loader': parsed.option('loader'),
        'installer': parsed.option('installer'),
      });
      return 0;
```

- [ ] **Step 3: Update the `repos sync` usage string in `runner.dart` (~line 113)**

```dart
      stderr.writeln('Usage: repos sync [all|paper|purpur|folia|canvas|leaf]');
```

- [ ] **Step 4: Analyze + smoke-check the parser routes leaf**

Run: `cd MultiplexorApp && dart analyze`
Expected: `No issues found!`
Run: `cd "/Users/brianfopiano/Developer/RemoteGit/[Minecraft Server]" && ./start.sh build latest leaf`
Expected: prints a version (e.g. `26.2` or `1.21.8`) — confirms the entrypoint routes `leaf` into the service and version discovery works. (Requires network.)

---

### Task 3: Interactive wizard

**Files:**
- Modify: `MultiplexorApp/lib/services/interactive_wizard.dart:28-37,1403-1409,1416-1428`

**Interfaces:**
- Consumes: the `'leaf'` type string. Produces: Leaf visible in the plugin-consumer server-type menus with a `Leaf` label.

- [ ] **Step 1: Add `leaf` to `_serverTypes` (~line 28)**

```dart
  static const List<String> _serverTypes = <String>[
    'paper',
    'purpur',
    'folia',
    'canvas',
    'leaf',
    'spigot',
    'forge',
    'fabric',
    'neoforge',
  ];
```

- [ ] **Step 2: Add `leaf` to the plugin list in `_serverTypesForActiveConsumer` (~line 1403)**

```dart
      ConsumerProfile.plugin => const <String>[
        'paper',
        'purpur',
        'folia',
        'canvas',
        'leaf',
        'spigot',
      ],
```

- [ ] **Step 3: Add `leaf` to `_serverTypeLabel` (~line 1416)**

```dart
      'canvas' => 'Canvas',
      'leaf' => 'Leaf',
      'spigot' => 'Spigot',
```

- [ ] **Step 4: Analyze**

Run: `cd MultiplexorApp && dart analyze`
Expected: `No issues found!`
(The wizard is a raw-mode TTY dashboard; visual confirmation happens in Task 5 by launching `./start.sh` and opening the plugin-consumer server-type menu.)

---

### Task 4: Help text + README

**Files:**
- Modify: `MultiplexorApp/lib/cli/command_help.dart:59,66`
- Modify: `README.md:90,189,200-208`

**Interfaces:**
- Consumes: nothing new. Produces: user-facing docs listing `leaf`.

- [ ] **Step 1: `command_help.dart` — build group (~line 59) and repos group (~line 66)**

Build group first entry:

```dart
    '<paper|purpur|folia|canvas|leaf|spigot|forge|fabric|neoforge> [--mc <version>] [--loader <version>] [--installer <version>]',
```

Repos group:

```dart
  CommandHelpGroup('repos', <String>['sync [all|paper|purpur|folia|canvas|leaf]']),
```

- [ ] **Step 2: `README.md` — `<type>` enumeration (line 90)**

```markdown
`<type>` is one of: `paper`, `purpur`, `folia`, `canvas`, `leaf`, `spigot`, `forge`, `fabric`, `neoforge`. `leaf` is a high-performance Paper fork and behaves like any other plugin-family type. For `forge` / `neoforge`, an installer jar triggers args-file launch mode automatically.
```

- [ ] **Step 3: `README.md` — repos table (line 189)**

```markdown
| `repos sync [all\|paper\|purpur\|folia\|canvas\|leaf]` | Clone or pull upstream repos used for version discovery. Build commands resolve metadata over HTTP, so this is mostly used for Spigot/BuildTools. |
```

- [ ] **Step 4: `README.md` — add a Leaf workflow example (after line 205, the `--isolated` example)**

```markdown

# Create a Leaf server (high-performance Paper fork) on the latest stable build
./start.sh server create leaf --type leaf --auto-build
```

- [ ] **Step 5: Verify help output lists leaf**

Run: `cd "/Users/brianfopiano/Developer/RemoteGit/[Minecraft Server]" && ./start.sh build --help`
Expected: the build usage line includes `leaf`.
Run: `grep -n "leaf" "/Users/brianfopiano/Developer/RemoteGit/[Minecraft Server]/README.md"`
Expected: matches on the `<type>` line, the repos line, and the new workflow example.

---

### Task 5: Full verification (analyze + suite + real execution)

Per repo verification rules, prove the feature actually works end-to-end — not just that tests/typecheck pass.

**Files:** none (verification only).

- [ ] **Step 1: Static + full test suite**

Run: `cd MultiplexorApp && dart analyze && dart test`
Expected: `No issues found!` and all tests pass (0 failures), including the new `build refuses leaf` test.

- [ ] **Step 2: Real build download (default plugin consumer)**

Run: `cd "/Users/brianfopiano/Developer/RemoteGit/[Minecraft Server]" && ./start.sh build leaf --mc 1.21.8`
Expected: `[OK] Cached leaf build <n> for mc=1.21.8` and `[INFO] Jar: .../builds/leaf/leaf-1.21.8-<n>.jar`.
Then: `./start.sh build list-all leaf` — expected to list the cached jar. Confirm `latest.jar` symlink exists in `builds/leaf/`.

- [ ] **Step 3: Version discovery**

Run: `./start.sh build latest leaf` (expect a version string) and `./start.sh build versions leaf` (expect the Leaf version list including `1.21.8` and `26.x`).

- [ ] **Step 4: Repo sync**

Run: `./start.sh repos sync leaf`
Expected: `[INFO] Cloning repo: leaf` (or `Updating repo: leaf`) then `[OK] Repo ready: leaf -> .../repos/leaf`.

- [ ] **Step 5: Server create + ownership guard**

Run (plugin consumer): `./start.sh server create leaf-smoke --type leaf --auto-build` — expect an instance created and wired to `server.jar`; confirm its `.server-source` records `type=leaf` and `launch=jar`.
Run (guard): `./start.sh --consumer forge build leaf` — expect the ownership error naming the `plugin` consumer.
Clean up the smoke instance afterward if the user wants (`./start.sh instance delete leaf-smoke`), or leave it and note it.

- [ ] **Step 6: Wizard visual check**

Launch `./start.sh` (no args) → open the plugin-consumer server-type menu → confirm `Leaf` appears alongside Paper/Purpur/Folia/Canvas/Spigot and renders correctly. Report what was seen.

---

## Self-Review

**Spec coverage** (each spec section → task):
- `_buildDownloadLeaf` + channel/`primary` handling → Task 1 (3a,3b). ✓
- Version resolvers + switches → Task 1 (3c,3d,3e). ✓
- Repo parity (`_repoUrl`, `_reposSync`, fallback sets, usage) → Task 1 (3l–3p) + Task 2 (step 3). ✓
- Core enumerations/validation (`_allBuildTypes`, `_isKnownServerType`, `_consumerForServerType`, build switch) → Task 1 (3f,3g,3h,3i,3q). ✓
- CLI entrypoints (`bin/main.dart`, `runner.dart`) → Task 2. ✓
- Labels/colors → Task 1 (3j,3k). ✓
- Wizard → Task 3. ✓
- Modrinth `_contentLoader` NO-CHANGE → intentionally absent (verified correct; Leaf falls through to `paper`). ✓
- `.server-source` / `_buildDir` / `_registerBuiltJar` NO-CHANGE → automatic; nothing to do. ✓
- Docs (README + command_help) → Task 4. ✓
- Test → Task 1 (Steps 1–4). ✓
- Execution verification → Task 5. ✓

**Placeholder scan:** none — every edit shows exact old/new strings and complete code.

**Type consistency:** `_buildDownloadLeaf(ConsumerProfile, String, _NativeIoBuffer) → Future<String>` matches the `_buildTarget` call site (3a) and mirrors `_buildDownloadPurpur`. `_resolveLeafMcVersions() → Future<List<String>>` and `_resolveLatestLeafMcVersion() → Future<String?>` match their switch call sites (3d/3e) and the `_resolveSupportedMcVersions`/`_resolveLatestSupportedMcVersion` return types. Test uses `service.setConsumerOverride(ConsumerProfile.forge)` — a real public method — requiring the added `consumer_profile.dart` import.

**Note on line numbers:** approximate — they shift as edits land. Each edit includes enough surrounding context (adjacent case labels / method names) to anchor it unambiguously.
