import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/playback_queue.dart';

void main() {
  test('queue snapshot cannot change under an active file selection', () {
    final items = <PlaybackQueueItem>[
      const PlaybackQueueItem(key: 'file-02', title: '第02集.mp4'),
    ];
    final snapshot = PlaybackQueueSnapshot(items: items, hasMore: true);
    items.clear();
    expect(snapshot.items.map((item) => item.key), ['file-02']);
    expect(
      () => snapshot.items.add(
        const PlaybackQueueItem(key: 'file-03', title: '第03集.mp4'),
      ),
      throwsUnsupportedError,
    );
  });
}
