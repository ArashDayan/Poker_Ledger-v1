import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/localization/app_localizations.dart';
import '../core/theme/app_theme.dart';
import '../models/player_identity.dart';
import '../services/backup_service.dart';
import '../services/player_identity_service.dart';

/// Confirm-on-suggest prompt shown when seating a player whose name
/// matches an existing identity.
///
/// A name match is NEVER enough on its own. Cancel (or dismissing the
/// dialog) aborts the add. "Different person" creates a new identity.
/// Linking requires an explicit tap on the matching identity.
Future<IdentityLinkResult> confirmIdentityLink(
  BuildContext context, {
  required String typedName,
  required List<PlayerIdentity> suggestions,
}) async {
  if (suggestions.isEmpty) {
    return const IdentityLinkResult.createNew();
  }

  final result = await showDialog<IdentityLinkResult>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('identity_same_person_title'),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr('identity_same_person_body').replaceAll('{name}', typedName),
              style: const TextStyle(fontSize: 13.5),
            ),
            const SizedBox(height: 12),
            ...suggestions.map((identity) {
              final lastSeen =
                  PlayerIdentityService.lastSeenFor(identity.id);
              final seenLabel = lastSeen == null
                  ? tr('identity_no_previous_seat')
                  : '${tr('identity_last_seen')} ${DateFormat.yMMMd().format(lastSeen)}';
              final shortId = _tail(identity.id);
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => Navigator.pop(
                      ctx,
                      IdentityLinkResult.link(identity.id),
                    ),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.divider),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            identity.displayName,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '$seenLabel  ·  …$shortId',
                            style: const TextStyle(
                                fontSize: 11, color: AppColors.textSecondary),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }),
            const SizedBox(height: 4),
            Text(
              tr('identity_confirm_hint'),
              style: const TextStyle(
                  fontSize: 11.5, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(ctx, const IdentityLinkResult.cancel()),
          child: Text(tr('cancel')),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(ctx, const IdentityLinkResult.createNew()),
          child: Text(tr('identity_different_person')),
        ),
      ],
    ),
  );

  // Dismissing the dialog must never link and never create — it aborts.
  return result ?? const IdentityLinkResult.cancel();
}

/// One restore conflict the banker has to resolve before that identity
/// is written. A dismissed dialog is treated as "keep local".
Future<IdentityResolutionAction> confirmIdentityRestoreConflict(
  BuildContext context, {
  required IdentityConflict conflict,
}) async {
  final sameId = conflict.kind == IdentityConflictKind.sameIdDifferentName;
  final action = await showDialog<IdentityResolutionAction>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('identity_restore_conflict_title'),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            sameId
                ? tr('identity_restore_conflict_same_id')
                : tr('identity_restore_conflict_same_name'),
            style: const TextStyle(fontSize: 13.5),
          ),
          const SizedBox(height: 12),
          _ConflictRow(
            label: tr('identity_keep_local'),
            name: conflict.local.displayName,
            idTail: _tail(conflict.local.id),
          ),
          const SizedBox(height: 8),
          _ConflictRow(
            label: tr('identity_take_backup'),
            name: conflict.incoming.displayName,
            idTail: _tail(conflict.incoming.id),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(ctx, IdentityResolutionAction.keepLocal),
          child: Text(tr('identity_keep_local')),
        ),
        if (!sameId)
          TextButton(
            onPressed: () =>
                Navigator.pop(ctx, IdentityResolutionAction.keepBoth),
            child: Text(tr('identity_keep_both')),
          ),
        ElevatedButton(
          onPressed: () =>
              Navigator.pop(ctx, IdentityResolutionAction.takeBackup),
          child: Text(tr('identity_take_backup')),
        ),
      ],
    ),
  );
  return action ?? IdentityResolutionAction.keepLocal;
}

String _tail(String id) => id.length >= 4 ? id.substring(id.length - 4) : id;

class _ConflictRow extends StatelessWidget {
  final String label;
  final String name;
  final String idTail;

  const _ConflictRow({
    required this.label,
    required this.name,
    required this.idTail,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 11, color: AppColors.textSecondary)),
          const SizedBox(height: 2),
          Text('$name  ·  …$idTail',
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
