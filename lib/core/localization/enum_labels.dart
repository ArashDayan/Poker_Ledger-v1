import '../../models/enums.dart';
import 'app_localizations.dart';

/// Localized display names for the enums that appear in the UI.
///
/// Deliberately kept OUT of `lib/models/enums.dart`: the `label` getters
/// there are also consumed by CSV/PDF export and by error messages, and
/// those must stay stable, so the enums, their Hive adapters and their
/// byte mapping are untouched. This is a display-only layer that maps
/// each case onto the translation key that already exists in
/// [AppLocalizations], adding new keys only for the cases that had none.
extension PlayerTagL10n on PlayerTag {
  String get localizedLabel {
    switch (this) {
      case PlayerTag.vip:
        return tr('vip');
      case PlayerTag.regular:
        return tr('regular');
      case PlayerTag.problemPlayer:
        return tr('problem_player');
      case PlayerTag.tilt:
        return tr('tilt');
    }
  }

  /// Very short form for cramped places such as a poker-table seat plate.
  String get localizedShortLabel {
    switch (this) {
      case PlayerTag.vip:
        return tr('tag_short_vip');
      case PlayerTag.regular:
        return tr('tag_short_regular');
      case PlayerTag.problemPlayer:
        return tr('tag_short_problem');
      case PlayerTag.tilt:
        return tr('tag_short_tilt');
    }
  }
}

extension TransactionTypeL10n on TransactionType {
  String get localizedLabel {
    switch (this) {
      case TransactionType.buyIn:
        return tr('buy_in');
      case TransactionType.rebuy:
        return tr('rebuy');
      case TransactionType.cashOut:
        return tr('cash_out');
      case TransactionType.rakeCollection:
        return tr('rake_collected');
      case TransactionType.cashDrop:
        return tr('cash_drop');
      case TransactionType.transferOut:
        return tr('transfer_out');
      case TransactionType.transferIn:
        return tr('transfer_in');
      case TransactionType.dealerTips:
        return tr('dealer_tips');
    }
  }
}
