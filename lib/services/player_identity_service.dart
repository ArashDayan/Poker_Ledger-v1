import 'package:uuid/uuid.dart';

import '../models/player.dart';
import '../models/player_identity.dart';
import 'hive_service.dart';
import 'player_history_service.dart';

const _uuid = Uuid();

/// How the banker answered an identity suggestion.
enum IdentityLinkChoice {
  /// Link this seat to an existing [PlayerIdentity].
  link,

  /// The suggestion is a different human — create a new identity.
  createNew,

  /// Abandon the add-player flow. Nothing is written.
  cancel,
}

/// Explicit result of a confirm-on-suggest prompt.
///
/// The service never invents one of these. The UI (or a test double)
/// produces it after the banker has chosen.
class IdentityLinkResult {
  final IdentityLinkChoice choice;
  final String? personId;

  const IdentityLinkResult._(this.choice, this.personId);

  const IdentityLinkResult.link(String personId)
      : this._(IdentityLinkChoice.link, personId);

  const IdentityLinkResult.createNew()
      : this._(IdentityLinkChoice.createNew, null);

  const IdentityLinkResult.cancel() : this._(IdentityLinkChoice.cancel, null);

  bool get isCancel => choice == IdentityLinkChoice.cancel;
  bool get isLink => choice == IdentityLinkChoice.link;
  bool get isCreateNew => choice == IdentityLinkChoice.createNew;
}

/// Owns [PlayerIdentity] records and the confirm-on-suggest rule.
///
/// HARD RULES
///   * Never auto-link a seat to an existing identity. A name match is
///     only a suggestion.
///   * Never merge two identities. Two people may share a name.
///   * Never infer identity from buy-in, rebuy, cash-out or any chip
///     event. Those prove chips moved, not who the human is.
///   * A missing identity box (unit tests that only open the chip
///     ledger) degrades to "no identities" rather than crashing.
///
/// This file holds no money. It does not read [SessionService] totals.
class PlayerIdentityService {
  PlayerIdentityService._();

  static String normaliseName(String name) =>
      PlayerHistoryService.normaliseName(name);

  static bool get _boxOpen {
    try {
      HiveService.playerIdentities;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Every stored identity, most recently updated first.
  static List<PlayerIdentity> all() {
    if (!_boxOpen) return const [];
    final list = HiveService.playerIdentities.values.toList();
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  static PlayerIdentity? byId(String? personId) {
    if (personId == null || personId.isEmpty || !_boxOpen) return null;
    return HiveService.playerIdentities.get(personId);
  }

  /// Identities that *might* be the same human as [name].
  ///
  /// Matching is exact on the normalised display name (and on any seat
  /// already linked to an identity whose current seat-name matches).
  /// Fuzzy / partial matches are deliberately not used — a close name
  /// is how two different people's money gets mixed.
  ///
  /// An empty list means there is no exact match on file. It is still
  /// the caller's job to ask the operator explicitly (ICR-03): an empty
  /// list must never silently auto-create a person.
  static List<PlayerIdentity> suggest(String name) {
    if (!_boxOpen) return const [];
    final key = normaliseName(name);
    if (key.isEmpty) return const [];

    final matches = <String, PlayerIdentity>{};
    for (final identity in HiveService.playerIdentities.values) {
      if (normaliseName(identity.displayName) == key) {
        matches[identity.id] = identity;
      }
    }

    try {
      for (final player in HiveService.players.values) {
        if (player.personId == null || player.personId!.isEmpty) continue;
        if (normaliseName(player.name) != key) continue;
        final identity = HiveService.playerIdentities.get(player.personId);
        if (identity != null) matches[identity.id] = identity;
      }
    } catch (_) {
      // Players box not open — suggestions from identities alone still
      // stand.
    }

    final list = matches.values.toList();
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  /// Next membership number to hand out: one above the highest in
  /// use, floored at [PlayerIdentity.firstPlayerNumber].
  ///
  /// Deliberately *not* "count of identities + 101": numbers are never
  /// recycled (a deleted-for-testing or restored identity must not
  /// shift anyone else's number), so gaps are left unfilled.
  static int nextPlayerNumber() {
    if (!_boxOpen) return PlayerIdentity.firstPlayerNumber;
    var max = PlayerIdentity.firstPlayerNumber - 1;
    for (final identity in HiveService.playerIdentities.values) {
      if (identity.playerNumber > max) max = identity.playerNumber;
    }
    return max + 1;
  }

  /// Display form of a Player Number.
  ///
  /// `0` or any value below [PlayerIdentity.firstPlayerNumber] is
  /// "not assigned yet" and must NEVER look like a real membership
  /// number. The UI shows the em dash here; callers prepend `#` only
  /// when the number is assigned.
  static String numberLabel(int number) =>
      number >= PlayerIdentity.firstPlayerNumber ? '$number' : '—';

  /// Searchable Player Master directory used by explicit seating.
  ///
  /// Matches (case/spacing-insensitive, partial allowed) Player Number,
  /// first name, last name or display name. A number query also accepts
  /// the optional `#` prefix. Results are ordered by assigned number
  /// (unassigned identities last), then display name, so the operator
  /// can scan a familiar membership register rather than a random list.
  ///
  /// Search is a decision aid for a human. It is NOT identity linking
  /// on its own: a match still requires the operator to select the
  /// person in the confirmation step.
  static List<PlayerIdentity> search(String query) {
    if (!_boxOpen) return const [];
    final list = HiveService.playerIdentities.values.toList();
    final q = normaliseName(query);
    final numeric = int.tryParse(query.trim().replaceFirst('#', '').trim());

    list.retainWhere((identity) {
      if (numeric != null &&
          numeric >= PlayerIdentity.firstPlayerNumber &&
          identity.playerNumber.toString().contains(numeric.toString())) {
        return true;
      }
      if (q.isEmpty) return true;
      if (identity.firstName.isNotEmpty &&
          normaliseName(identity.firstName).contains(q)) {
        return true;
      }
      if (identity.lastName.isNotEmpty &&
          normaliseName(identity.lastName).contains(q)) {
        return true;
      }
      if (normaliseName(identity.displayName).contains(q)) return true;
      return false;
    });

    list.sort((a, b) {
      final aHas = a.hasPlayerNumber;
      final bHas = b.hasPlayerNumber;
      if (aHas != bHas) return aHas ? -1 : 1;
      final byNumber = a.playerNumber.compareTo(b.playerNumber);
      if (byNumber != 0 && aHas && bHas) return byNumber;
      return normaliseName(a.displayName)
          .compareTo(normaliseName(b.displayName));
    });
    return list;
  }

  /// Creates a brand-new identity. Never reuses an existing id, even
  /// when the display name already exists — two people named Ali are
  /// two identities.
  ///
  /// Every new identity is born with its permanent [PlayerIdentity.playerNumber]
  /// (the next free one from 101) and a best-effort first/last split of
  /// the typed name; both can be corrected on the master record later.
  /// [displayName] is preserved verbatim — screens keep showing what
  /// the banker typed.
  ///
  /// [firstName] / [lastName] override the automatic split when the
  /// registration form collects them. [idNumber] is stored as optics /
  /// identity confirmation data only; it is never used to merge people.
  ///
  /// This method writes ONLY the identity row. It never seats the
  /// person, creates a session participation, moves chips or writes a
  /// financial/session event.
  static Future<PlayerIdentity?> createNew(
    String displayName, {
    String? note,
    String? firstName,
    String? lastName,
    String? idNumber,
  }) async {
    if (!_boxOpen) return null;
    final trimmed = displayName.trim();
    if (trimmed.isEmpty) return null;
    final now = DateTime.now();
    final split = PlayerIdentity.splitDisplayName(trimmed);
    final first = (firstName != null && firstName.trim().isNotEmpty)
        ? firstName.trim()
        : split.first;
    final last = (lastName != null && lastName.trim().isNotEmpty)
        ? lastName.trim()
        : split.last;
    final identity = PlayerIdentity(
      id: _uuid.v4(),
      displayName: trimmed,
      createdAt: now,
      updatedAt: now,
      note: note,
      playerNumber: nextPlayerNumber(),
      firstName: first,
      lastName: last,
      idNumber: idNumber,
    );
    await HiveService.playerIdentities.put(identity.id, identity);
    return identity;
  }

  /// ICR-01 backfill for identities stored before the Player Master
  /// fields existed (and for identities restored from a backup that
  /// predates them). Idempotent; safe to run at every startup.
  ///
  /// Per identity, in deterministic order (`createdAt`, then `id`):
  ///   * Assigns a Player Number from 101+ to anyone without one. An
  ///     already-numbered identity keeps its number; a duplicate (two
  ///     devices, one backup) is renumbered deterministically — the
  ///     earlier identity in the sort order keeps the number, the
  ///     later one takes the next free one. Numbers are never shuffled
  ///     wholesale: an identity that already holds a unique number is
  ///     never touched.
  ///   * Splits [PlayerIdentity.displayName] into first/last ONLY when
  ///     both are empty — a banker-corrected name is never overwritten.
  ///   * Copies seat specimen signatures (oldest linked [Player] first)
  ///     into IDENTITY specimen slots that are empty. Seat specimens
  ///     are never deleted or demoted — the per-seat "as signed that
  ///     night" record stays on the [Player] row.
  ///
  ///   * NEVER merges identities, NEVER touches ids, NEVER bumps
  ///     [PlayerIdentity.updatedAt] (a silent backfill must not look
  ///     like a banker edit), and NEVER reads or writes any session,
  ///     transaction, chip or financial data.
  ///
  /// Returns how many identity rows were modified.
  static Future<int> migrateMasterFields() async {
    if (!_boxOpen) return 0;

    final identities = HiveService.playerIdentities.values.toList()
      ..sort((a, b) {
        final byCreated = a.createdAt.compareTo(b.createdAt);
        return byCreated != 0 ? byCreated : a.id.compareTo(b.id);
      });

    final usedNumbers = <int>{};
    var cursor = PlayerIdentity.firstPlayerNumber;
    var changed = 0;

    for (final identity in identities) {
      var dirty = false;

      // 1) Player Number.
      final n = identity.playerNumber;
      if (n >= PlayerIdentity.firstPlayerNumber && !usedNumbers.contains(n)) {
        usedNumbers.add(n);
      } else {
        while (usedNumbers.contains(cursor)) cursor++;
        identity.playerNumber = cursor;
        usedNumbers.add(cursor);
        cursor++;
        dirty = true;
      }

      // 2) First / last name — only into an untouched pair.
      if (identity.firstName.isEmpty && identity.lastName.isEmpty) {
        final split = PlayerIdentity.splitDisplayName(identity.displayName);
        if (split.first.isNotEmpty || split.last.isNotEmpty) {
          identity.firstName = split.first;
          identity.lastName = split.last;
          dirty = true;
        }
      }

      // 3) Specimens — fill empty slots only, oldest seat wins.
      var specimen1Missing = identity.sampleSignatureBase64 == null ||
          identity.sampleSignatureBase64!.isEmpty;
      var specimen2Missing = identity.sampleSignature2Base64 == null ||
          identity.sampleSignature2Base64!.isEmpty;
      if (specimen1Missing || specimen2Missing) {
        for (final seat in _linkedSeatsOldestFirst(identity.id)) {
          if (specimen1Missing && seat.hasSampleSignature) {
            identity.sampleSignatureBase64 = seat.sampleSignatureBase64;
            specimen1Missing = false;
            dirty = true;
          }
          if (specimen2Missing && seat.hasSecondSample) {
            identity.sampleSignature2Base64 = seat.sampleSignature2Base64;
            specimen2Missing = false;
            dirty = true;
          }
          if (!specimen1Missing && !specimen2Missing) break;
        }
      }

      if (dirty) {
        await identity.save();
        changed++;
      }
    }

    return changed;
  }

  /// Seats linked to [personId], oldest first so the earliest captured
  /// specimen becomes the person-level baseline. Empty when the
  /// players box is unavailable (chip-ledger-only tests) — migration
  /// then simply leaves specimen slots untouched rather than failing.
  static List<Player> _linkedSeatsOldestFirst(String personId) {
    try {
      final seats = HiveService.players.values
          .where((p) => p.personId == personId)
          .toList()
        ..sort((a, b) => a.joinedAt.compareTo(b.joinedAt));
      return seats;
    } catch (_) {
      return const [];
    }
  }

  /// Applies an explicit identity decision and returns the personId to
  /// store on the new [Player] row.
  ///
  /// [confirm] is invoked even when there are no suggestions: an exact
  /// silent auto-create is exactly the bug ICR-03 removes. The service
  /// never links without an explicit link result and never creates
  /// without an explicit create result.
  ///
  /// Returns null when the banker cancelled, or when the identity box
  /// is unavailable (degraded mode — the seat is created unlinked).
  static Future<String?> resolveForSeating({
    required String name,
    required Future<IdentityLinkResult> Function(
      List<PlayerIdentity> suggestions,
    ) confirm,
  }) async {
    final suggestions = suggest(name);
    final result = await confirm(suggestions);
    if (result.isCancel) return null;

    if (result.isLink) {
      final id = result.personId;
      if (id == null || byId(id) == null) {
        // A confirm callback handed back an id we do not have. Refuse
        // rather than silently create — that would be an implicit merge
        // of "whatever they typed" into a new account.
        throw StateError(
          'Cannot link seat: confirmed personId is missing.',
        );
      }
      return id;
    }

    if (result.isCreateNew) {
      final created = await createNew(name);
      return created?.id;
    }

    return null;
  }

  /// Writes [personId] onto a seat. Does not create or merge identities.
  static Future<void> attach(Player player, String personId) async {
    if (byId(personId) == null) {
      throw StateError(
          'Cannot attach seat: personId "$personId" does not exist.');
    }
    player.personId = personId;
    await player.save();
    await touchDisplayName(personId, player.name);
  }

  /// Clears the link on a seat. The identity itself is kept.
  static Future<void> detach(Player player) async {
    player.personId = null;
    await player.save();
  }

  /// Updates the display spelling on an identity. Names are display
  /// only, so a rename of a linked seat updates the label, not the id.
  static Future<void> touchDisplayName(String personId, String name) async {
    final identity = byId(personId);
    if (identity == null) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    if (identity.displayName == trimmed) return;
    identity.displayName = trimmed;
    identity.updatedAt = DateTime.now();
    await identity.save();
  }

  /// Most recent [Player.joinedAt] among seats linked to [personId].
  static DateTime? lastSeenFor(String personId) {
    DateTime? latest;
    try {
      for (final player in HiveService.players.values) {
        if (player.personId != personId) continue;
        if (latest == null || player.joinedAt.isAfter(latest)) {
          latest = player.joinedAt;
        }
      }
    } catch (_) {
      return null;
    }
    return latest;
  }
}
