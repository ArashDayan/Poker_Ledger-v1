import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:signature/signature.dart';

import '../core/localization/app_localizations.dart';
import '../core/theme/app_theme.dart';

/// Signature capture used for host confirmation and for the player's
/// reference specimen.
///
/// MULTI-STROKE BEHAVIOUR (the V2 fix):
/// A real signature is almost never one continuous line — crossing a "t",
/// dotting an "i", or any name with separate initials means the pen lifts
/// several times. The previous implementation exported on `onDrawEnd`,
/// i.e. the moment the pen left the glass, and the Add Player sheet then
/// immediately swapped the live pad for a static "sample on file"
/// preview. The practical result was that the signature was frozen after
/// the very first stroke and there was no way to continue it.
///
/// Now the pad keeps accepting strokes indefinitely and NOTHING is
/// committed until the banker presses Confirm ([requireConfirm] = true).
/// While drawing, [onChanged] reports only whether the pad currently has
/// ink, so callers can enable/disable their own buttons without treating
/// a half-finished signature as final.
class SignaturePad extends StatefulWidget {
  /// Called with the base64 PNG when the signature is committed, and with
  /// an empty string when it is cleared.
  final void Function(String base64Png) onChanged;

  /// When true (the default) the drawing is only committed once the user
  /// presses Confirm, so multi-stroke signatures are never cut short.
  /// When false the pad auto-commits after each stroke — kept only for
  /// the inline host-confirmation sheets, where the surrounding sheet has
  /// its own Confirm button doing the same job.
  final bool requireConfirm;

  /// Optional caption override (defaults to the localized "sign here").
  final String? caption;

  final double height;

  const SignaturePad({
    super.key,
    required this.onChanged,
    this.requireConfirm = false,
    this.caption,
    this.height = 170,
  });

  @override
  State<SignaturePad> createState() => _SignaturePadState();
}

class _SignaturePadState extends State<SignaturePad> {
  late final SignatureController _controller;

  /// True once the current drawing has been committed via Confirm, so the
  /// UI can show that it is saved without destroying the strokes (the
  /// banker can still Redraw).
  bool _confirmed = false;

  /// Tracks ink presence so the buttons enable/disable correctly. Updated
  /// on every stroke end — but crucially this does NOT commit anything.
  bool _hasInk = false;

  @override
  void initState() {
    super.initState();
    _controller = SignatureController(
      penStrokeWidth: 3,
      penColor: AppColors.textPrimary,
      exportBackgroundColor: AppColors.surface,
    );

    _controller.onDrawEnd = () async {
      // A pen lift is just a pen lift — the signature stays editable and
      // more strokes are welcome. Any previous confirmation is invalidated
      // because the drawing has changed since it was committed.
      if (!mounted) return;
      setState(() {
        _hasInk = _controller.isNotEmpty;
        _confirmed = false;
      });
      if (!widget.requireConfirm) {
        await _commit();
      }
    };
  }

  Future<void> _commit() async {
    if (_controller.isEmpty) return;
    final bytes = await _controller.toPngBytes();
    if (bytes == null || !mounted) return;
    widget.onChanged(base64Encode(bytes));
    if (widget.requireConfirm) {
      setState(() => _confirmed = true);
    }
  }

  void _clear() {
    _controller.clear();
    setState(() {
      _hasInk = false;
      _confirmed = false;
    });
    widget.onChanged('');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                widget.caption ?? tr('sign_here'),
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
            ),
            if (_confirmed)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.check_circle, size: 15, color: AppColors.accentGreen),
                  const SizedBox(width: 4),
                  Text(tr('saved'),
                      style: const TextStyle(
                          fontSize: 11.5,
                          color: AppColors.accentGreen,
                          fontWeight: FontWeight.bold)),
                ],
              ),
          ],
        ),
        const SizedBox(height: 6),
        if (widget.requireConfirm)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              tr('signature_multi_stroke_hint'),
              style: TextStyle(
                  fontSize: 10.5, color: AppColors.textSecondary.withValues(alpha: 0.85)),
            ),
          ),
        Container(
          height: widget.height,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _confirmed ? AppColors.accentGreen.withValues(alpha: 0.6) : AppColors.divider,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Signature(
              controller: _controller,
              backgroundColor: AppColors.surface,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            TextButton.icon(
              onPressed: _hasInk ? _clear : null,
              icon: const Icon(Icons.refresh, size: 17),
              label: Text(widget.requireConfirm ? tr('redraw') : tr('clear')),
              style: TextButton.styleFrom(foregroundColor: AppColors.textSecondary),
            ),
            const Spacer(),
            if (widget.requireConfirm)
              ElevatedButton.icon(
                onPressed: (_hasInk && !_confirmed) ? _commit : null,
                icon: const Icon(Icons.check, size: 17),
                label: Text(tr('confirm_signature')),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
