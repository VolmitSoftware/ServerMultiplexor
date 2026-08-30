import 'package:multiplexor/services/minecraft_console_completion.dart';
import 'package:test/test.dart';

void main() {
  group('MinecraftConsoleCompletion planning', () {
    test('completes command roots and preserves an optional slash', () {
      final MinecraftConsoleCompletion completion =
          MinecraftConsoleCompletion();

      final ConsoleCompletionPlan plain = completion.plan('he', 2);
      final ConsoleCompletionPlan slash = completion.plan('/ver', 4);

      expect(plain.matches, <String>['help']);
      expect(plain.apply('help', appendSpace: true).input, 'help ');
      expect(slash.matches, <String>['/version']);
      expect(slash.apply('/version').input, '/version');
    });

    test('returns a deterministic common prefix for ambiguous commands', () {
      final MinecraftConsoleCompletion completion = MinecraftConsoleCompletion(
        commands: const <String>['teleport', 'tell', 'tellraw'],
      );

      final ConsoleCompletionPlan plan = completion.plan('t', 1);

      expect(plan.matches, <String>['teleport', 'tell', 'tellraw']);
      expect(plan.commonPrefix, 'tel');
      expect(plan.apply(plan.commonPrefix).input, 'tel');
    });

    test('replaces only the token under a mid-line cursor', () {
      final MinecraftConsoleCompletion completion =
          MinecraftConsoleCompletion();
      completion.observeOutputLine(
        'There are 2 of a max of 20 players online: Alice, Bob',
      );

      final ConsoleCompletionPlan plan = completion.plan('kick Al now', 7);
      final ConsoleCompletionEdit edit = plan.apply('Alice');

      expect(plan.matches, <String>['Alice']);
      expect(edit.input, 'kick Alice now');
      expect(edit.cursor, 10);
    });

    test('learns only the command root from successful session history', () {
      final MinecraftConsoleCompletion completion = MinecraftConsoleCompletion(
        commands: const <String>[],
      );

      completion.rememberCommand('/spark profiler --password secret');
      completion.rememberCommand('not! valid argument');

      expect(completion.plan('/sp', 3).matches, <String>['/spark']);
      expect(completion.plan('not', 3).matches, isEmpty);
    });

    test('returns no match without changing the input', () {
      final MinecraftConsoleCompletion completion = MinecraftConsoleCompletion(
        commands: const <String>['help'],
      );

      final ConsoleCompletionPlan plan = completion.plan('xyz', 3);

      expect(plan.matches, isEmpty);
      expect(plan.commonPrefix, isEmpty);
    });
  });

  group('MinecraftConsoleCompletion roster', () {
    test('tracks joins, logins, UUID lines, leaves, and list snapshots', () {
      final MinecraftConsoleCompletion completion =
          MinecraftConsoleCompletion();

      expect(completion.observeOutputLine('Alice joined the game'), isTrue);
      expect(
        completion.observeOutputLine(
          'Bob[/127.0.0.1:25565] logged in with entity id 2',
        ),
        isTrue,
      );
      expect(
        completion.observeOutputLine(
          'UUID of player Carol is 00000000-0000-0000-0000-000000000000',
        ),
        isTrue,
      );
      expect(completion.players, <String>['Alice', 'Bob', 'Carol']);

      expect(completion.observeOutputLine('Bob left the game'), isTrue);
      expect(completion.players, <String>['Alice', 'Carol']);

      expect(
        completion.observeOutputLine(
          'There are 1 of a max of 20 players online: Delta',
        ),
        isTrue,
      );
      expect(completion.players, <String>['Delta']);
      expect(completion.plan('kick d', 6).matches, <String>['Delta']);
    });

    test('empty list output clears stale names', () {
      final MinecraftConsoleCompletion completion =
          MinecraftConsoleCompletion();
      completion.observeOutputLine('Alice joined the game');

      completion.observeOutputLine(
        'There are 0 of a max of 20 players online:',
      );

      expect(completion.players, isEmpty);
      expect(completion.plan('kick A', 6).matches, isEmpty);
    });

    test('ignores malformed and hostile player-looking text', () {
      final MinecraftConsoleCompletion completion =
          MinecraftConsoleCompletion();

      expect(
        completion.observeOutputLine(
          'There are 1 of a max of 20 players online: ../../escape',
        ),
        isFalse,
      );
      expect(
        completion.observeOutputLine('player-with-dashes joined the game'),
        isFalse,
      );
      expect(completion.players, isEmpty);
    });
  });
}
