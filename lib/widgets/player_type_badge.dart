import 'package:flutter/material.dart';

import '../core/localization/app_localizations.dart';
import '../core/localization/enum_labels.dart';
import '../core/theme/app_theme.dart';
import '../models/enums.dart';
import '../services/player_registry_service.dart';

/// Icon + colour for each classification, in one place.
///
/// Centralised so the Player Bank, the profile and the poker table can
/// never drift into showing the same player three different ways. The
/// palette is the existing Poker Ledger one — gold for premium, amber
/// for caution, red for trouble — rather than a new colour language.
extension PlayerTagVisuals on PlayerTag {
  IconData get icon {
    switch (this) {
      case PlayerTag.vip:
        return Icons.workspace_premium; // crown-style premium mark
      case PlayerTag.regular:
        return Icons.person_outline;
      case PlayerTag.problemPlayer:
        return Icons.report_problem_outlined;
      case PlayerTag.tilt:
        return Icons.local_fire_department_outlined;
    }
  }

  Color get color {
    switch (this) {
      case PlayerTag.vip:
        return AppColors.gold;
      case PlayerTag.regular:
        return AppColors.textSecondary;
      case PlayerTag.problemPlayer:
        return AppColors.danger;
      case PlayerTag.tilt:
        return AppColors.warning;
    }
  }

  /// Very short form for cramped places like a poker-table seat plate,
  /// where the full "Problem Player" would not fit. Localized.
  String get shortLabel => localizedShortLabel;
}

/// A compact classification chip: icon plus label.
///
/// Sized to sit beside a player's name without becoming the loudest
/// thing in the row — the name stays the primary element, per the brief.
class PlayerTypeBadge extends StatelessWidget {
  final PlayerTag tag;

  /// Drops the text and shows only the icon, for very tight rows.
  final bool iconOnly;

  /// Uses [PlayerTagVisuals.shortLabel] instead of the full name.
  final bool compact;

  final double scale;

  const PlayerTypeBadge({
    super.key,
    required this.tag,
    this.iconOnly = false,
    this.compact = false,
    this.scale = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final c = tag.color;
    final text = compact ? tag.shortLabel : tag.localizedLabel;

    if (iconOnly) {
      return Tooltip(
        message: tag.localizedLabel,
        child: Icon(tag.icon, size: 14 * scale, color: c),
      );
    }

    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: 5 * scale, vertical: 1.5 * scale),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(5 * scale),
        border: Border.all(color: c.withValues(alpha: 0.55), width: 0.9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(tag.icon, size: 10.5 * scale, color: c),
          SizedBox(width: 3 * scale),
          Text(
            text,
            style: TextStyle(
              fontSize: 9.5 * scale,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.3,
              color: c,
            ),
          ),
        ],
      ),
    );
  }
}

/// A blocked/blacklisted marker.
///
/// Deliberately a different SHAPE and colour from [PlayerTypeBadge] so
/// the two read as different kinds of information at a glance: one says
/// what a player is, the other says they should not be seated.
class BlacklistBadge extends StatelessWidget {
  final bool iconOnly;
  final double scale;

  const BlacklistBadge({super.key, this.iconOnly = false, this.scale = 1.0});

  @override
  Widget build(BuildContext context) {
    const c = AppColors.danger;

    if (iconOnly) {
      return Tooltip(
        message: tr('blacklisted'),
        child: Icon(Icons.block, size: 14 * scale, color: c),
      );
    }

    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: 5 * scale, vertical: 1.5 * scale),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(5 * scale),
        border: Border.all(color: c, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.block, size: 10.5 * scale, color: c),
          SizedBox(width: 3 * scale),
          Text(
            tr('blacklisted_caps'),
            style: TextStyle(
              fontSize: 9.5 * scale,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.4,
              color: c,
            ),
          ),
        ],
      ),
    );
  }
}

/// Confirmation shown before seating someone who is on the blacklist.
///
/// A STRONG WARNING, NOT A LOCK — the brief is explicit that the banker
/// keeps the final say, so this returns true on Continue rather than
/// refusing outright. Cancel is the default action (it is the plain
/// button, and dismissing the dialog also returns false), so the unsafe
/// path always requires a deliberate tap.
Future<bool> confirmBlacklistedPlayer(
  BuildContext context, {
  required String playerName,
}) async {
  final note = PlayerRegistryService.blacklistNote(playerName);

  final proceed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.warning_amber_rounded,
              color: AppColors.danger, size: 22),
          const SizedBox(width: 8),
          Expanded(
            child: Text(tr('blacklisted_player'),
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppColors.danger)),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$playerName ${tr('is_currently_blacklisted')}',
              style: const TextStyle(fontSize: 13.5)),
          if (note != null) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: AppColors.danger.withValues(alpha: 0.4)),
              ),
              child: Text(note,
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textSecondary)),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            tr('blacklist_seat_anyway'),
            style: const TextStyle(fontSize: 11.5, color: AppColors.textSecondary),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(tr('cancel')),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: ElevatedButton.styleFrom(backgroundColor: AppColors.danger),
          child: Text(tr('continue_action')),
        ),
      ],
    ),
  );
  // A dismissed dialog (tap outside / back) must never seat the player.
  return proceed == true;
}
