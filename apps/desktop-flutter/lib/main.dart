/// WebHTV PC desktop entrypoints.
library;

import 'ui/app.dart' as app;
import 'ui/player_menu_popup.dart';

Future<void> main(List<String> args) {
  PlayerMenuPopup.enable();
  return app.main(args);
}

@pragma('vm:entry-point')
void playerMenuPopupMain() => runPlayerMenuPopup();
