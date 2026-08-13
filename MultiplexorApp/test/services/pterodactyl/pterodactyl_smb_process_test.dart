import 'package:multiplexor/services/pterodactyl/pterodactyl_smb_process.dart';
import 'package:test/test.dart';

void main() {
  test(
    'command diagnostics remove terminal control sequences and truncate',
    () {
      final PterodactylSmbCommandResult result = PterodactylSmbCommandResult(
        exitCode: 1,
        stdout: '',
        stderr: '\x1b[2Jdanger\x00${'x' * 1200}',
      );

      expect(result.diagnostic, startsWith('danger'));
      expect(result.diagnostic, isNot(contains('\x1b')));
      expect(result.diagnostic, isNot(contains('\x00')));
      expect(result.diagnostic.length, 1003);
    },
  );
}
