import 'dart:convert';
import '../core/localization/app_localizations.dart';

import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../core/utils/currency_formatter.dart';
import '../models/player.dart';
import '../models/transaction.dart';
import '../services/signature_analysis.dart';

/// Renders a stored base64-PNG signature, with a graceful placeholder
/// when there isn't one (or when the stored bytes are unreadable — a
/// corrupted blob must never crash the screen a banker is using to
/// settle a dispute).
class SignatureImage extends StatelessWidget {
  final String? base64Png;
  final double height;
  final String emptyLabel;

  /// When true, tapping opens a full-screen pinch/double-tap zoom view.
  /// Essential during a dispute: comparing two signatures at thumbnail
  /// size is not a real comparison.
  final bool zoomable;

  /// Caption shown above the zoomed image, so a banker flicking between
  /// the two never loses track of which one they are looking at.
  final String zoomTitle;

  const SignatureImage({
    super.key,
    required this.base64Png,
    this.height = 130,
    this.emptyLabel = 'No signature on file',
    this.zoomable = false,
    this.zoomTitle = '',
  });

  void _openZoom(BuildContext context) {
    if (base64Png == null || base64Png!.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _SignatureZoomScreen(
          base64Png: base64Png!,
          title: zoomTitle,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget child;
    if (base64Png == null || base64Png!.isEmpty) {
      child = Center(
        child: Text(emptyLabel,
            style: const TextStyle(fontSize: 11.5, color: AppColors.textSecondary)),
      );
    } else {
      try {
        child = Image.memory(
          base64Decode(base64Png!),
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => Center(
            child: Text(tr('signature_unavailable'),
                style: TextStyle(fontSize: 11.5, color: AppColors.textSecondary)),
          ),
        );
      } catch (_) {
        child = Center(
          child: Text(tr('signature_unavailable'),
              style: TextStyle(fontSize: 11.5, color: AppColors.textSecondary)),
        );
      }
    }

    final hasImage = base64Png != null && base64Png!.isNotEmpty;

    return Stack(
      children: [
        Container(
          height: height,
          width: double.infinity,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.divider),
          ),
          clipBehavior: Clip.antiAlias,
          padding: const EdgeInsets.all(6),
          child: child,
        ),
        if (zoomable && hasImage)
          Positioned.fill(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => _openZoom(context),
                child: Align(
                  alignment: AlignmentDirectional.bottomEnd,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.background.withValues(alpha: 0.75),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: AppColors.gold.withValues(alpha: 0.5)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.zoom_in, size: 13, color: AppColors.gold),
                          SizedBox(width: 4),
                          Text(tr('zoom'),
                              style: TextStyle(fontSize: 10, color: AppColors.gold)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Full-screen pinch-zoom / double-tap view of a single signature.
class _SignatureZoomScreen extends StatefulWidget {
  final String base64Png;
  final String title;
  const _SignatureZoomScreen({required this.base64Png, required this.title});

  @override
  State<_SignatureZoomScreen> createState() => _SignatureZoomScreenState();
}

class _SignatureZoomScreenState extends State<_SignatureZoomScreen>
    with SingleTickerProviderStateMixin {
  final _controller = TransformationController();
  TapDownDetails? _doubleTapAt;

  void _handleDoubleTap() {
    // Toggle between fit and 2.5x centred on wherever they tapped.
    if (_controller.value != Matrix4.identity()) {
      _controller.value = Matrix4.identity();
      return;
    }
    final pos = _doubleTapAt?.localPosition;
    if (pos == null) return;
    const scale = 2.5;
    _controller.value = Matrix4.identity()
      ..translate(-pos.dx * (scale - 1), -pos.dy * (scale - 1))
      ..scale(scale);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(widget.title.isEmpty ? tr('signature') : widget.title,
            style: const TextStyle(fontSize: 15)),
        actions: [
          IconButton(
            tooltip: tr('reset_zoom'),
            icon: const Icon(Icons.zoom_out_map),
            onPressed: () => _controller.value = Matrix4.identity(),
          ),
        ],
      ),
      body: Center(
        child: GestureDetector(
          onDoubleTapDown: (d) => _doubleTapAt = d,
          onDoubleTap: _handleDoubleTap,
          child: InteractiveViewer(
            transformationController: _controller,
            minScale: 0.8,
            maxScale: 8,
            child: Container(
              // White backing: signatures are dark ink and must be judged
              // on a neutral field, not on dark felt.
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: Image.memory(base64Decode(widget.base64Png), fit: BoxFit.contain),
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text(tr('pinch_to_zoom'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
        ),
      ),
    );
  }
}

/// Side-by-side comparison of a player's reference (specimen) signature
/// against the signature captured on a specific transaction.
///
/// This is a **host judgement tool, not an authentication mechanism**.
/// The app deliberately does not score or "match" the two — automated
/// signature matching would give a false sense of certainty about
/// someone's money. It simply puts both marks in front of the banker at
/// the same size and lets a human decide, which is exactly what happens
/// in a real card room.
Future<void> showSignatureComparison(
  BuildContext context, {
  required Player player,
  required LedgerTransaction transaction,
  required CurrencyFormatter formatter,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.fact_check_outlined, color: AppColors.gold, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('${tr('verify_signature')} · ${player.name}',
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${transaction.type.label} · ${formatter.format(transaction.amount)} · '
                '${transaction.timestamp.toString().substring(0, 16)}',
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 18),

              // Similarity result, computed asynchronously so decoding
              // two PNGs never blocks the sheet from opening.
              FutureBuilder<SignatureComparison>(
                future: SignatureAnalysis.compare(
                  candidate: transaction.hostSignatureBase64,
                  samples: player.signatureSamples,
                ),
                builder: (ctx, snap) {
                  if (!snap.hasData) {
                    return const Padding(
                      padding: EdgeInsets.only(bottom: 14),
                      child: LinearProgressIndicator(minHeight: 2),
                    );
                  }
                  return _ScoreCard(result: snap.data!);
                },
              ),
              const SizedBox(height: 16),

              _label('Sample 1'
                  '${player.sampleSignatureAt != null ? ' · ${player.sampleSignatureAt.toString().substring(0, 10)}' : ''}'),
              const SizedBox(height: 6),
              SignatureImage(
                base64Png: player.sampleSignatureBase64,
                height: 110,
                emptyLabel: 'No sample signature was captured for this player.',
                zoomable: true,
                zoomTitle: '${player.name} · sample 1',
              ),
              const SizedBox(height: 12),

              _label('Sample 2'
                  '${player.sampleSignature2At != null ? ' · ${player.sampleSignature2At.toString().substring(0, 10)}' : ''}'),
              const SizedBox(height: 6),
              SignatureImage(
                base64Png: player.sampleSignature2Base64,
                height: 110,
                emptyLabel:
                    'No second sample. Capture one from Edit player to make '
                    'the similarity score meaningful.',
                zoomable: true,
                zoomTitle: '${player.name} · sample 2',
              ),
              const SizedBox(height: 16),

              _label('Signature on this transaction'),
              const SizedBox(height: 6),
              SignatureImage(
                base64Png: transaction.hostSignatureBase64,
                height: 130,
                emptyLabel: 'No signature stored on this transaction.',
                zoomable: true,
                zoomTitle:
                    '${transaction.type.label} · ${formatter.format(transaction.amount)}',
              ),

              if (transaction.signedWhileAbsent) ...[
                const SizedBox(height: 14),
                _warning(
                  'This was signed while the player was marked as settled / away '
                  'from the table, so the signature cannot have been theirs at '
                  'the moment it was captured.',
                ),
              ],
              if (transaction.isEdited) ...[
                const SizedBox(height: 10),
                _warning(
                  'This transaction was edited after it was first recorded'
                  '${transaction.editedAt != null ? ' (${transaction.editedAt.toString().substring(0, 16)})' : ''}.',
                ),
              ],
              if (!player.hasSampleSignature) ...[
                const SizedBox(height: 14),
                _warning(
                  'There is no sample to compare against. Capture one from the '
                  "player's card (Edit player → Sample signature) so future "
                  'disputes have a reference.',
                ),
              ],

              const SizedBox(height: 18),
              Text(
                tr('comparison_note'),
                style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr('close')),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Similarity readout. Deliberately states its own limits: the banker
/// must never read a number here as proof either way.
class _ScoreCard extends StatelessWidget {
  final SignatureComparison result;
  const _ScoreCard({required this.result});

  @override
  Widget build(BuildContext context) {
    if (result.confidence == SignatureConfidence.unknown) {
      return _warning(result.explanation);
    }

    final Color colour;
    final String label;
    final IconData icon;
    switch (result.confidence) {
      case SignatureConfidence.strong:
        colour = AppColors.accentGreen;
        label = 'Consistent with samples';
        icon = Icons.check_circle_outline;
        break;
      case SignatureConfidence.moderate:
        colour = AppColors.warning;
        label = 'Some differences';
        icon = Icons.help_outline;
        break;
      default:
        colour = AppColors.danger;
        label = 'Looks different — check';
        icon = Icons.error_outline;
    }

    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: colour.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 19, color: colour),
              const SizedBox(width: 9),
              Expanded(
                child: Text(label,
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.bold,
                        color: colour)),
              ),
              Text('${result.score.toStringAsFixed(0)}%',
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: colour)),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (result.score / 100).clamp(0.0, 1.0),
              minHeight: 5,
              backgroundColor: AppColors.background.withValues(alpha: 0.5),
              valueColor: AlwaysStoppedAnimation(colour),
            ),
          ),
          const SizedBox(height: 9),
          Text(
            result.explanation,
            style: const TextStyle(
                fontSize: 10.5, height: 1.35, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.gavel_outlined,
                  size: 12, color: AppColors.gold),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  tr('signature_score_disclaimer'),
                  style: TextStyle(
                      fontSize: 10,
                      fontStyle: FontStyle.italic,
                      color: AppColors.gold.withValues(alpha: 0.9)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

Widget _label(String text) => Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.0,
        color: AppColors.textSecondary,
      ),
    );

Widget _warning(String text) => Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.55)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 15, color: AppColors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: const TextStyle(fontSize: 11.5, color: AppColors.textPrimary)),
          ),
        ],
      ),
    );
