import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/player_context_menu.dart';
import 'package:webhtv_pc/ui/player_menu_popup.dart';

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized()
          as TestDefaultBinaryMessengerBinding;
  final binary = messenger.defaultBinaryMessenger;
  const channel = MethodChannel('webhtv/player_menu_host');
  const codec = StandardMethodCodec();

  Future<void> event(String method, int session, [String? item]) async {
    await binary.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(
        MethodCall(method, {'session': session, 'item': item}),
      ),
      (_) {},
    );
  }

  tearDown(() => binary.setMockMethodCallHandler(channel, null));

  test(
    'a native selection runs current enabled actions and can update in place',
    () async {
      final calls = <MethodCall>[];
      final opened = Completer<MethodCall>();
      binary.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'open') opened.complete(call);
        return true;
      });
      var selected = false;
      var dismissed = 0;
      var disabledSelected = false;
      List<PlayerMenuSection> sections() => [
        PlayerMenuSection(
          title: '显示',
          items: [
            PlayerMenuItem(
              id: 'osd',
              label: '屏显',
              selected: selected,
              onSelect: () => selected = !selected,
            ),
            PlayerMenuItem(
              id: 'disabled',
              label: '禁用',
              enabled: false,
              onSelect: () => disabledSelected = true,
            ),
          ],
        ),
      ];
      final popup = PlayerMenuPopup(onDismiss: () => dismissed++);
      addTearDown(popup.close);
      final shown = popup.show(
        const Offset(50, 80),
        sections(),
        pixelRatio: 1.5,
      );
      final open = (await opened.future).arguments as Map;
      final session = open['session'] as int;
      expect(open['x'], 75);
      expect(open['y'], 120);
      final items = (open['sections'] as List).single['items'] as List;
      final actionId = items.first['action'] as String;
      expect(items.last['action'], isNull);
      await event('shown', session);
      expect(await shown, isTrue);
      await event('select', session + 1, actionId);
      await event('select', session, '["显示","disabled"]');
      expect(selected, isFalse);
      expect(disabledSelected, isFalse);
      await event('select', session, actionId);
      expect(selected, isTrue);
      expect(dismissed, 0);
      popup.update(sections());
      final update = calls.last;
      expect(update.method, 'update');
      expect(
        (update.arguments['sections'] as List)
            .single['items']
            .first['selected'],
        isTrue,
      );
      await event('dismiss', session);
      await event('select', session, actionId);
      expect(selected, isTrue);
      expect(dismissed, 1);
    },
  );

  testWidgets('the popup keeps its physical anchor when its view DPI changes', (
    tester,
  ) async {
    const viewChannel = MethodChannel('webhtv/player_menu_view');
    List<Object?>? rects;
    binary.setMockMethodCallHandler(viewChannel, (call) async {
      if (call.method == 'layout') {
        rects = call.arguments['rects'] as List<Object?>;
      }
      return null;
    });
    addTearDown(() => binary.setMockMethodCallHandler(viewChannel, null));
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.5;
    addTearDown(tester.view.reset);
    runPlayerMenuPopup();
    await tester.pumpAndSettle();
    await binary.handlePlatformMessage(
      viewChannel.name,
      codec.encodeMethodCall(
        const MethodCall('snapshot', {
          'session': 1,
          'x': 300.0,
          'y': 150.0,
          'reserveFlyoutSpace': true,
          'sections': [
            {
              'title': '设置',
              'items': [
                {
                  'id': 'example',
                  'label': '示例',
                  'enabled': true,
                  'selected': false,
                },
              ],
            },
          ],
        }),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
    expect(rects, [
      [300, 150, 660, 216],
    ]);
    tester.view.devicePixelRatio = 1;
    await tester.pumpAndSettle();
    expect(rects, [
      [300, 150, 540, 194],
    ]);
  });

  test(
    'a declined native window allows the player to use the in-window menu',
    () async {
      binary.setMockMethodCallHandler(channel, (call) async => false);
      final popup = PlayerMenuPopup(onDismiss: () => fail('not opened'));
      expect(await popup.show(Offset.zero, const []), isFalse);
    },
  );
}
