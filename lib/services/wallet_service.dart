import '../models/chip_movement.dart';
import '../models/enums.dart';
import '../models/financial_event.dart';
import '../models/table_participation.dart';
import 'chip_tracking_service.dart';
import 'financial_ledger_service.dart';
import 'hive_service.dart';
import 'participation_service.dart';
import 'player_identity_service.dart';

/// One currency's slice of the person's wallet.
///
/// Every figure is DERIVED on read from the Financial Ledger — never
/// stored (invariant W-1). The money formulas are the Financial
/// Ledger's own; this type only assembles them into one view.
class WalletCurrencyPosition {
  final AppCurrency currency;

  /// The player's own cash the banker holds (front money / deposit
  /// remaining): `Σ frontMoneyIn − Σ frontMoneyOut`, active events.
  final int depositHeldMinor;

  /// Credit the player owes: `Σ creditIssued + Σ cashOutUnbacked −
  /// Σ creditRepaid`, active events. Front money is not credit.
  final int creditOutstandingMinor;

  /// Net outstanding position (the existing outstanding-balance
  /// formula): positive = player owes the banker, negative = banker
  /// holds the player's money.
  final int outstandingNetMinor;

  /// Whether this currency has any financial history at all
  /// (the "Not recorded" rule — an empty currency is not a zero).
  final bool recorded;

  const WalletCurrencyPosition({
    required this.currency,
    required this.depositHeldMinor,
    required this.creditOutstandingMinor,
    required this.outstandingNetMinor,
    required this.recorded,
  });

  /// W-2 (approved E2): a marker is a DRAW on the deposit, and the draw
  /// reduces the deposit — so the amount available to a marker is the
  /// deposit remaining after all draws. Enforced where markers are
  /// issued (later phase); defined here so the whole app reads the same
  /// rule from one place.
  int get availableMarkerBalanceMinor => depositHeldMinor;

  double get depositHeld => MoneyUnits.toMajor(currency, depositHeldMinor);
  double get creditOutstanding =>
      MoneyUnits.toMajor(currency, creditOutstandingMinor);
  double get outstandingNet =>
      MoneyUnits.toMajor(currency, outstandingNetMinor);
  double get availableMarkerBalance =>
      MoneyUnits.toMajor(currency, availableMarkerBalanceMinor);
}

/// The person's position with the casino, all derived, never stored.
///
/// SCOPE (Phase 3): this is the single wallet view — deposit, credit,
/// net position, the person-scoped chip holding, and where the person
/// is currently seated (informational). It is the LIFETIME source of
/// truth for the remaining deposit (E8): session-scoped deposit
/// figures are projections, shown as such in session reports.
class WalletPosition {
  final String personId;
  final String displayName;

  /// One entry per currency with financial activity (currency
  /// isolation — never netted across currencies).
  final List<WalletCurrencyPosition> currencies;

  /// Total value of the person's chip holding (Phase 2a person-scoped
  /// chip ledger). 0 when the person holds no chips.
  final double chipsInHand;

  /// Informational seating reference: the ACTIVE session this person
  /// is currently seated in (null when not seated in any active
  /// session). Not money — the wallet never depends on it.
  final String? seatedSessionId;
  final String? seatedTableId;

  /// Phase 6: the person's OPEN table commitments (derived from the
  /// participations box; lifecycle + identity only, no money — P-1).
  final List<TableParticipation> openParticipations;

  const WalletPosition({
    required this.personId,
    required this.displayName,
    required this.currencies,
    required this.chipsInHand,
    this.seatedSessionId,
    this.seatedTableId,
    this.openParticipations = const [],
  });

  bool get hasActivity => currencies.isNotEmpty || chipsInHand > 0;

  bool get seatedNow => seatedSessionId != null;

  int get openParticipationCount => openParticipations.length;

  WalletCurrencyPosition? positionFor(AppCurrency currency) {
    for (final p in currencies) {
      if (p.currency == currency) return p;
    }
    return null;
  }
}

/// Read-only wallet derivations.
///
/// HARD RULES
///   * NEVER writes — the wallet is a fold over the Financial Ledger,
///     the person-scoped Chip Ledger and the seating rows.
///   * Reuses the Financial Ledger's formulas and active/reversed
///     rules; never re-implements or alters them.
///   * Currency isolation: one position per currency, never netted.
///   * "Not recorded" stays distinct from zero (the recorded flag).
class WalletService {
  WalletService._();

  static WalletPosition walletFor(String personId) {
    final identity = PlayerIdentityService.byId(personId);

    final events = FinancialLedgerService.eventsFor(personId);
    final currencySet = <AppCurrency>{
      for (final e in events) e.currency,
    };
    final positions = currencySet
        .map((c) => WalletCurrencyPosition(
              currency: c,
              depositHeldMinor:
                  FinancialLedgerService.depositHeldMinor(personId, c),
              creditOutstandingMinor:
                  FinancialLedgerService.creditOutstandingMinor(personId, c),
              outstandingNetMinor:
                  FinancialLedgerService.balance(personId, c).amountMinor,
              recorded: FinancialLedgerService
                      .balance(personId, c)
                      .recorded,
            ))
        .toList()
      ..sort((a, b) => a.currency.index.compareTo(b.currency.index));

    // Chips in hand: the person-scoped holding (Phase 2a). A person
    // with no chip movements simply holds zero — the fold handles it.
    double chips = 0;
    try {
      chips = ChipTrackingService
              .holdingAt(ChipLocation.player(personId))
              .totalValue;
    } catch (_) {
      // Chip boxes not open (degraded mode): the wallet's money
      // figures still stand; chips read as none.
    }

    // Informational seating reference only.
    String? seatedSession;
    String? seatedTable;
    try {
      for (final p in HiveService.players.values) {
        if (p.personId != personId || !p.seated) continue;
        final s = HiveService.sessions.get(p.sessionId);
        if (s == null || s.status != SessionStatus.active) continue;
        seatedSession = s.id;
        seatedTable = p.tableId;
        break;
      }
    } catch (_) {}

    // Phase 6: open table commitments (derived; degraded to none when
    // the participations box is unavailable — the wallet must never
    // break because of the tracking overlay).
    List<TableParticipation> openParts;
    try {
      openParts = ParticipationService.openForPerson(personId);
    } catch (_) {
      openParts = const [];
    }

    return WalletPosition(
      personId: personId,
      displayName:
          identity?.displayName.isNotEmpty == true
              ? identity!.displayName
              : (personId.isNotEmpty ? personId : ''),
      currencies: positions,
      chipsInHand: chips,
      seatedSessionId: seatedSession,
      seatedTableId: seatedTable,
      openParticipations: openParts,
    );
  }
}
