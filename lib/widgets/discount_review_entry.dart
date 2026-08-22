import 'package:flutter/material.dart';

import '../core/localization/app_localizations.dart';
import '../core/theme/app_theme.dart';
import '../models/enums.dart';
import '../models/player.dart';
import '../services/discount_workflow.dart';
import '../services/session_service.dart';
import 'rebate_grant_sheet.dart';

/// Opens the existing grant/review sheet. Never writes until Confirm
/// inside that sheet. Always reachable so the Banker can read *why*
/// Discount is or is not available.
Future<void> openDiscountReview(
  BuildContext context, {
  required String sessionId,
  required AppCurrency currency,
  required Player player,
}) async {
  final personId = player.personId;
  if (personId == null || personId.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('discount_status_no_identity'))),
      );
    }
    return;
  }

  await askRebateGrant(
    context,
    sessionId: sessionId,
    personId: personId,
    currency: currency,
    playerId: player.id,
    bustRealized: SessionService.hasZeroBustOut(sessionId, player.id),
  );
}

/// Compact status + action used on Players / Player Action.
class DiscountReviewTile extends StatelessWidget {
  final String sessionId;
  final AppCurrency currency;
  final Player player;

  const DiscountReviewTile({
    super.key,
    required this.sessionId,
    required this.currency,
    required this.player,
  });

  @override
  Widget build(BuildContext context) {
    final view = DiscountWorkflowView.inspect(
      sessionId: sessionId,
      currency: currency,
      personId: player.personId,
      playerId: player.id,
    );
    final eligible = view.kind == DiscountWorkflowKind.eligible;
    return Material(
      color: AppColors.surfaceElevated,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => openDiscountReview(
          context,
          sessionId: sessionId,
          currency: currency,
          player: player,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(
                Icons.percent,
                size: 18,
                color: eligible ? AppColors.gold : AppColors.textSecondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('review_discount'),
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 13.5),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tr(view.statusKey()),
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.3,
                        color: eligible
                            ? AppColors.gold
                            : AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right,
                  size: 18, color: AppColors.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}
