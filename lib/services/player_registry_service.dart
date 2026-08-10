import '../models/enums.dart';
import '../models/player.dart';
import 'hive_service.dart';
import 'player_history_service.dart';

/// Whether a person is welcome at the game.
///
/// DELIBERATELY SEPARATE FROM [PlayerTag].
/// A classification says what KIND of player someone is; access status
/// says whether they may sit down. They are orthogonal — a VIP can be
/// blacklisted, and a problem player can be perfectly welcome — so
/// folding "blacklisted" into the tag enum would make those states
/// unrepresentable and would silently overwrite a player's real
/// classification the moment they were barred.
enum PlayerAccessStatus {
  active,
  blacklisted;

  bool get isBlacklisted => this == PlayerAccessStatus.blacklisted;
}

/// Person-level player attributes that outlive any single session.
///
/// WHY THIS IS NOT A FIELD ON [Player]
/// A `Player` row is one seat in one session — the same human has a
/// separate row for every night they play. Storing "blacklisted" there
/// would mean the flag applied to one historical appearance rather than
/// to the person, so barring someone would not carry to the next
/// session, and un-barring them would have to rewrite past rows.
///
/// Instead these attributes are keyed by the same normalised name that
/// [PlayerHistoryService] already uses to group a career, and stored in
/// the settings box. That gives three properties the spec requires:
///
///   * one status per PERSON, applying to every future session;
///   * historical `Player` rows, transactions and sessions are never
///     touched, so profit, accounting and settlement cannot change;
///   * no Hive adapter change and no new typeId, so existing data keeps
///     loading exactly as before.
///
/// Nothing in this file is read by any financial calculation. It is
/// consulted only by the UI and by the pre-seat warning.
class PlayerRegistryService {
  PlayerRegistryService._();

  /// Settings-box key prefixes. Plain string maps rather than a typed
  /// box so no adapter/typeId is introduced.
  static const _blacklistKey = 'player_blacklist';
  static const _tagKey = 'player_tag_override';
  static const _noteKey = 'player_blacklist_note';

  static String keyFor(String name) => PlayerHistoryService.normaliseName(name);

  static Map<String, dynamic> _map(String bucket) {
    try {
      final raw = HiveService.settings.get(bucket);
      if (raw is Map) return Map<String, dynamic>.from(raw);
    } catch (_) {
      // Settings box not open (unit tests touching only models) — behave
      // as an empty registry rather than throwing into the UI.
    }
    return <String, dynamic>{};
  }

  static Future<void> _write(String bucket, Map<String, dynamic> value) async {
    try {
      await HiveService.settings.put(bucket, value);
    } catch (_) {
      // Same degraded-but-safe mode as above.
    }
  }

  // ---------------------------------------------------------------- access

  static PlayerAccessStatus statusForName(String name) =>
      _map(_blacklistKey)[keyFor(name)] == true
          ? PlayerAccessStatus.blacklisted
          : PlayerAccessStatus.active;

  static PlayerAccessStatus statusFor(Player player) =>
      statusForName(player.name);

  static bool isBlacklistedName(String name) =>
      statusForName(name).isBlacklisted;

  static bool isBlacklisted(Player player) => isBlacklistedName(player.name);

  /// Bars a person from future seating.
  ///
  /// Writes ONE boolean against their name. No `Player` row, session,
  /// transaction or total is read or modified, which is what guarantees
  /// requirement 8: history is preserved exactly.
  static Future<void> blacklist(String name, {String? note}) async {
    final k = keyFor(name);
    if (k.isEmpty) return;
    final m = _map(_blacklistKey)..[k] = true;
    await _write(_blacklistKey, m);
    if (note != null && note.trim().isNotEmpty) {
      final n = _map(_noteKey)..[k] = note.trim();
      await _write(_noteKey, n);
    }
  }

  /// Returns a person to [PlayerAccessStatus.active].
  ///
  /// Removes the flag rather than storing `false`, so an un-blacklisted
  /// person leaves no residue in storage. History is untouched.
  static Future<void> unblacklist(String name) async {
    final k = keyFor(name);
    if (k.isEmpty) return;
    final m = _map(_blacklistKey)..remove(k);
    await _write(_blacklistKey, m);
    final n = _map(_noteKey)..remove(k);
    await _write(_noteKey, n);
  }

  static Future<void> setBlacklisted(String name, bool value,
          {String? note}) async =>
      value ? blacklist(name, note: note) : unblacklist(name);

  /// Optional reason the banker recorded when barring someone.
  static String? blacklistNote(String name) {
    final v = _map(_noteKey)[keyFor(name)];
    return v is String && v.trim().isNotEmpty ? v.trim() : null;
  }

  /// Every blacklisted person, by normalised key.
  static Set<String> blacklistedKeys() => _map(_blacklistKey)
      .entries
      .where((e) => e.value == true)
      .map((e) => e.key)
      .toSet();

  // ------------------------------------------------------------ classification

  /// The person-level classification for a name.
  ///
  /// Resolution order, most authoritative first:
  ///   1. an explicit override set from the Player Bank;
  ///   2. the tag on their most recent `Player` row, so a classification
  ///      chosen while seating someone shows up in the directory without
  ///      the banker having to re-enter it;
  ///   3. null — unclassified, which is a valid state and is NOT
  ///      silently coerced to Regular.
  static PlayerTag? tagForName(String name) {
    final k = keyFor(name);
    if (k.isEmpty) return null;

    final override = _map(_tagKey)[k];
    if (override is int && override >= 0 && override < PlayerTag.values.length) {
      return PlayerTag.values[override];
    }

    Player? latest;
    for (final p in HiveService.players.values) {
      if (keyFor(p.name) != k) continue;
      if (p.tags.isEmpty) continue;
      if (latest == null || p.joinedAt.isAfter(latest.joinedAt)) latest = p;
    }
    return latest?.tags.isNotEmpty == true ? latest!.tags.first : null;
  }

  static PlayerTag? tagFor(Player player) =>
      player.tags.isNotEmpty ? player.tags.first : tagForName(player.name);

  /// Sets (or with null, clears) the person-level classification.
  ///
  /// Historical `Player` rows keep whatever tag they were saved with —
  /// this only changes what the directory and future seatings show.
  static Future<void> setTagForName(String name, PlayerTag? tag) async {
    final k = keyFor(name);
    if (k.isEmpty) return;
    final m = _map(_tagKey);
    if (tag == null) {
      m.remove(k);
    } else {
      m[k] = tag.index;
    }
    await _write(_tagKey, m);
  }
}
