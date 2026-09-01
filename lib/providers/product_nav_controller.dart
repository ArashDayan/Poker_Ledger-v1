import 'package:flutter/foundation.dart';

/// Which product destination the shell is showing.
///
/// The shell is the PRODUCT (Floor | Players | House), not a session:
/// this controller deliberately holds no session state. Session data
/// stays in [SessionProvider]; this only decides which of the three
/// destinations is on screen, so workflows ending in "show the live
/// table" (create session, resume a night, tap a live session in a
/// player's history) can land on Floor without pushing routes on top
/// of the shell.
class ProductNavController extends ChangeNotifier {
  static const int floorIndex = 0;
  static const int playersIndex = 1;
  static const int houseIndex = 2;

  int _index = floorIndex;
  int get index => _index;

  bool get isOnFloor => _index == floorIndex;

  void goTo(int index) {
    if (index == _index) return;
    if (index < floorIndex || index > houseIndex) return;
    _index = index;
    notifyListeners();
  }

  void goToFloor() => goTo(floorIndex);
  void goToPlayers() => goTo(playersIndex);
  void goToHouse() => goTo(houseIndex);
}
