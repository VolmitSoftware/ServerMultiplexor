# Design: Add Leaf as a plugin-family server software type

Date: 2026-07-03
Status: Approved (framing + scope confirmed by user)

## Goal

Add [Leaf](https://github.com/Winds-Studio/Leaf) — a high-performance Paper fork — as a
first-class **server software type** in the multiplexor manager, selectable under the existing
`plugin` consumer alongside `paper`, `purpur`, `folia`, `canvas`, and `spigot`. After this change
a user can run `server create --type leaf`, `build leaf [--mc <version>]`, `repos sync leaf`, and
see Leaf instances rendered correctly in the wizard and dashboards.

## Framing decision (confirmed)

Leaf is **not** a new `ConsumerProfile`. In this codebase a "consumer" is one of four isolated
profiles (`plugin`, `forge`, `fabric`, `neoforge`) that model the plugin-vs-modloader split. Leaf
is fully Bukkit/Spigot/Paper-plugin compatible, so it is a **server-software type owned by the
`plugin` consumer** — exactly like Paper/Purpur/Folia/Canvas. It reuses the plugin consumer's
`shared-plugin-data` (Iris packs + merged `ops.json`) with no new isolation surface.

## Scope decision (confirmed): full parity

Leaf gets the complete Paper-family plumbing, including the `repos sync leaf` git target and the
git-repo version-discovery fallback — matching Paper/Purpur/Folia/Canvas exactly. This was verified
to be a clean fit: Leaf's GitHub repo uses the **identical `ver/<mcversion>` branch convention**
(`ver/1.21.8`, `ver/1.21.11`, …) that the generic `_repoStableVersions` parser already reads, so no
Leaf-specific branch handling is needed.

## Verified facts about Leaf's distribution

Confirmed live against the API on 2026-07-03:

- **Downloads API** is Paper-**v2**-shaped (not the newer fill/v3 shape Paper itself now uses):
  - Project: `GET https://api.leafmc.one/v2/projects/leaf`
    -> `{ "project_id":"leaf", "versions":[ "1.21.4", ..., "1.21.11", "26.1.2", "26.2" ], ... }`
    (`versions` is a flat `List<String>`, mixing classic `1.x.y` and new CalVer `26.x`.)
  - Builds: `GET https://api.leafmc.one/v2/projects/leaf/versions/{mc}/builds`
    -> `{ "builds":[ { "build":175, "channel":"default"|"experimental",
    "downloads":{ "primary":{ "name":"leaf-1.21.8-175.jar", "sha256":"..." } } }, ... ] }`
  - Download: `https://api.leafmc.one/v2/projects/leaf/versions/{mc}/builds/{build}/downloads/{name}`
    (verified HTTP 200, `application/java-archive`, ~85 MB).
- **Channels** are `default` (stable) and `experimental`. Policy: **prefer the highest
  `default`-channel build, fall back to the highest any-channel build** — mirrors
  `_buildDownloadPaperLike`'s stable-preferred logic.
- **Key difference from Paper's v2**: the download entry is under `downloads.primary`, not
  `downloads.application`. Leaf therefore needs its own small download function; it cannot blindly
  reuse Paper's parser.

All file paths below are under `MultiplexorApp/` unless noted.

## Design

### 1. Build / download — new `_buildDownloadLeaf`

Add to `lib/services/native_command_service.dart`, modeled on `_buildDownloadPurpur`
(single meta call) + `_buildDownloadPaperLike` (stable-preferred channel selection):

```
Future<String> _buildDownloadLeaf(ConsumerProfile profile, String mc, _NativeIoBuffer io) async {
  final payload = await _httpGetJsonObject(
    'https://api.leafmc.one/v2/projects/leaf/versions/$mc/builds',
  );
  final builds = payload['builds'];
  if (builds is! List || builds.isEmpty) {
    throw _NativeCommandException('No Leaf builds available for mc=$mc', 1);
  }

  var bestStableBuild = -1;   String? stableName;
  var bestAnyBuild = -1;      String? anyName;
  for (final raw in builds) {
    if (raw is! Map) continue;
    final build = raw['build'];
    final name = (raw['downloads'] is Map ? (raw['downloads']['primary']) : null);
    final jarName = name is Map ? name['name'] : null;
    if (build is! num || jarName is! String || jarName.trim().isEmpty) continue;
    final n = build.toInt();
    if (n > bestAnyBuild) { bestAnyBuild = n; anyName = jarName.trim(); }
    final isStable = raw['channel']?.toString().trim().toLowerCase() == 'default';
    if (isStable && n > bestStableBuild) { bestStableBuild = n; stableName = jarName.trim(); }
  }

  final bestBuild = bestStableBuild > 0 ? bestStableBuild : bestAnyBuild;
  final jarName   = bestStableBuild > 0 ? stableName : anyName;
  if (bestBuild <= 0 || jarName == null) {
    throw _NativeCommandException('No downloadable Leaf build found for mc=$mc', 1);
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

Wire it into the `_buildTarget` dispatch switch (`native_command_service.dart:3769`):
`case 'leaf': return _buildDownloadLeaf(profile, mc, io);`

### 2. Version discovery — two new resolvers

Modeled on `_resolvePurpurMcVersions` / `_resolveLatestPurpurMcVersion`:

```
Future<List<String>> _resolveLeafMcVersions() async {
  final payload = await _httpGetJsonObject('https://api.leafmc.one/v2/projects/leaf');
  final versionsRaw = payload['versions'];
  if (versionsRaw is! List) return const <String>[];
  return _stableSortedMcVersions(versionsRaw);
}

Future<String?> _resolveLatestLeafMcVersion() async {
  final versions = await _resolveLeafMcVersions();
  return versions.isEmpty ? null : versions.last;
}
```

`_stableSortedMcVersions` is the same shared helper Paper's resolver feeds the identical
`1.x`/`26.x` mix through, so CalVer versions need no special handling.

Register both:
- `_resolveSupportedMcVersions` switch (`native_command_service.dart:4547`): `case 'leaf': return _resolveLeafMcVersions();`
- `_resolveLatestSupportedMcVersion` switch (`native_command_service.dart:4602`): `case 'leaf': return _resolveLatestLeafMcVersion();`

### 3. Repo parity (full-parity scope)

- `_repoUrl` (`native_command_service.dart:8355`): add
  `'leaf' => 'https://github.com/Winds-Studio/Leaf.git',`
- `_reposSync` (`native_command_service.dart:3348`): add `'leaf'` to the `'all'` list and to the
  single-target alternation; update the usage string at line 3356 to
  `repos sync [all|paper|purpur|folia|canvas|leaf]`.
- `_resolveLatestMcVersion` fallback set (`native_command_service.dart:4511`): add `'leaf'`.
- `_buildSupportedVersions` fallback set (`native_command_service.dart:4540`): add `'leaf'`.
- `_repoStableVersions` / `_repoLatestStableVersion` / `_repoDir` are already type-parameterized
  and read `origin/ver/*` generically — **no change**, works for Leaf as verified.

### 4. Type enumerations & validation (core wiring)

`lib/services/native_command_service.dart`:
- `_allBuildTypes` const list (`8705`): add `'leaf'`.
- `_isKnownServerType` switch (`8319`): add `case 'leaf':`.
- `_consumerForServerType` plugin block (`8305`): add `case 'leaf':` -> `ConsumerProfile.plugin`.
- `build <type>` sub-command switch (`1477`) + its usage strings (`1462`, `1491`): add Leaf to the
  plugin-family list.

CLI entrypoints:
- `bin/main.dart` build-targets set (`159`): add `'leaf'`.
- `lib/cli/runner.dart` `_runBuild` switch (`146`) + usage strings (`113`, `204`): add `case 'leaf':`.

Wizard (`lib/services/interactive_wizard.dart`):
- `_serverTypes` list (`28`): add `'leaf'`.
- `_serverTypesForActiveConsumer` plugin list (`1403`): add `'leaf'`.
- `_serverTypeLabel` switch (`1416`): add `'leaf' => 'Leaf'`.

### 5. Presentation labels/colors

`lib/services/native_command_service.dart`:
- `_instancePlatformLabel` (`7164`): add `'leaf' => 'Leaf'`.
- `_instancePlatformPrimaryColor` (`7178`): add `'leaf' => '2'` (dark green; distinct from
  Folia's `'a'`).

### 6. Modrinth loader mapping — NO CHANGE (deliberate)

`_contentLoader` (`native_command_service.dart:3122-3125`) maps only `paper|purpur|folia|spigot`
to themselves and otherwise falls through to `return 'paper'`. Leaf must **not** be added here:
Modrinth has no `leaf` loader, and Leaf is a Paper fork, so falling through to the `paper` loader is
correct — identical to how Canvas is already (correctly) omitted. This corrects an over-eager
suggestion from the initial code inventory.

### 7. `.server-source` metadata — NO CHANGE (automatic)

Leaf is a jar server, so `_serverCreateFromJar` records `type=leaf`, `launch=jar`, `jar=<path>`
automatically. Runtime launch resolution (`_runtimeLaunchTarget`, `_LaunchKind.jar`), `_buildDir`,
`_findCachedJar`, and `_registerBuiltJar` are all type-string-parameterized and need no change.

## Documentation (required — CLAUDE.md mandates README stays in lockstep)

- `README.md:90` — add `leaf` to the `<type>` enumeration.
- `README.md` build/repos command tables (`178-183`, `189`) — add `leaf`.
- `lib/cli/command_help.dart:59` (build group type list) and `:66` (repos group) — add `leaf`.
- Add one Leaf workflow example (`build leaf --mc 1.21.8` -> `server create --type leaf`) to
  README and, optionally, `command_help.dart:180-181`.

Consistency sweep — update any remaining hardcoded type-list strings for parity: `command_help`,
`native_command_service.dart:4440`, `4486`, `runner.dart` and `bin/main.dart` repos usage,
`_dispatchRepos` usage (`1509`).

## Testing

Follow the existing test style in `test/native_command_service_test.dart` (which exercises
`_ensureConsumerOwnsServerType` via the public command surface, no network):

1. **RED**: add a test asserting the plugin consumer **accepts** `--type leaf` routing (i.e.
   `_consumerForServerType('leaf') == ConsumerProfile.plugin` / a plugin-consumer `server create
   --type leaf` does not throw the ownership error), and that a modded consumer (e.g. `fabric`)
   **refuses** `--type leaf` with the ownership message. Verify it fails before the enum edits.
2. **GREEN**: apply the enumeration changes; test passes.
3. Network-bound download (`_buildDownloadLeaf`) and version resolvers follow the codebase's
   existing convention of not being unit-tested (no HttpClient mocking exists for the other
   downloaders); they are covered by execution verification instead.

Validation path (per CLAUDE.md): `dart analyze` -> `dart test` -> CLI smoke test:
- `./start.sh build leaf --mc 1.21.8` (expect a cached `leaf-1.21.8-<build>.jar` + `latest.jar`)
- `./start.sh server create --type leaf ...` under the plugin consumer
- `./start.sh repos sync leaf` (expect a clone/update of the Leaf repo)
- Wizard: confirm Leaf appears in the plugin-consumer server-type menu and renders label/color.

## Out of scope (YAGNI)

- No new `ConsumerProfile`.
- No experimental-channel opt-in flag (stable-preferred default matches Paper; can be added later
  if requested).
- No changes to shared-plugin-data, Iris linking, runtime/tmux, or drop-in watcher — Leaf inherits
  all Paper-family behavior unchanged.

## Consolidated touchpoint checklist

Required — `native_command_service.dart`: `_buildDownloadLeaf` (new), `_resolveLeafMcVersions` +
`_resolveLatestLeafMcVersion` (new), `_buildTarget` (3769), `_resolveSupportedMcVersions` (4547),
`_resolveLatestSupportedMcVersion` (4602), `_allBuildTypes` (8705), `_isKnownServerType` (8319),
`_consumerForServerType` (8305), `build`-subcommand switch + usage (1477/1462/1491),
`_instancePlatformLabel` (7164), `_instancePlatformPrimaryColor` (7178), `_repoUrl` (8355),
`_reposSync` + usage (3348/3356), `_resolveLatestMcVersion` set (4511), `_buildSupportedVersions`
set (4540), `_dispatchRepos` usage (1509).

Required — CLI entrypoints: `bin/main.dart` targets set (159), `runner.dart` `_runBuild` switch +
usage (146/113/204).

Required — wizard: `_serverTypes` (28), `_serverTypesForActiveConsumer` (1403), `_serverTypeLabel`
(1416).

Required — docs: `README.md` (90 + tables), `command_help.dart` (59/66 + example).

Required — tests: Leaf acceptance test in `test/native_command_service_test.dart`.

Explicitly NO change: `_contentLoader` (falls through to `paper`), `.server-source` read/write,
`_buildDir`, `_findCachedJar`, `_registerBuiltJar`, `_repoStableVersions`/`_repoDir`,
`ConsumerProfile` enum.
