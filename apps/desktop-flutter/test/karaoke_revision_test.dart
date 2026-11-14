import 'package:flutter_test/flutter_test.dart';

import 'karaoke_revision_probe.dart' as revision;

void main() {
  test(
    'R7-01 generated result rejects new media, selection and seek intent',
    () async {
      await revision.generatedGate();
      await revision.generatedIntentGates();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
  test(
    'R7-02 single media-clock scorer preserves combo and real reverse semantics',
    revision.comboGate,
    timeout: const Timeout(Duration(seconds: 30)),
  );
  test(
    'R7-03 MIDI rejects SMPTE and selects human melody with tempo/running status',
    revision.midiContracts,
    timeout: const Timeout(Duration(seconds: 30)),
  );
  test(
    'R7-04 every trailing invalid number rejects complete restore without changing bytes',
    revision.strictNumbers,
    timeout: const Timeout(Duration(seconds: 30)),
  );
  test(
    'R7-05 structural GitHub JSON and escaped paths obey response boundaries',
    revision.githubValidation,
    timeout: const Timeout(Duration(seconds: 30)),
  );
  test(
    'R7-06 source list/RSS/ES and scoped Cookie/blob branches consume fixtures',
    () async {
      await revision.sourceBranches();
      await revision.redirectAuthentication();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
  test(
    'R7-07 backend packets reach bounded worker full windows without real recording',
    revision.micPackets,
    timeout: const Timeout(Duration(seconds: 30)),
  );
  test('R7-08 repository commit epochs and actual AbortableRequest cancellation prevent resurrection', () async {
    await revision.repositoryGates();
    await revision.productionAbort();
  }, timeout: const Timeout(Duration(seconds: 30)));
  test(
    'R7-09 adjacent sidecar, legacy and matching metadata migrate safely',
    revision.localMigration,
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
