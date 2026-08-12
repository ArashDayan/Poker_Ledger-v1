import 'dart:io';
import 'package:csv/csv.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import '../models/enums.dart';
import '../models/financial_event.dart';
import '../models/session.dart';
import 'financial_ledger_service.dart';
import 'rebate_service.dart';
import 'report_service.dart';
import 'session_service.dart';
import 'session_settlement_view.dart';
import 'tournament_service.dart';
import '../core/utils/currency_formatter.dart';

class ExportService {
  /// NOTE: exports deliberately use formatRaw() so Privacy Mode never
/// masks a generated PDF/CSV. Privacy Mode hides amounts on SCREEN so a
/// player looking over the banker's shoulder can't read them; a report
/// the banker explicitly exports must always contain the real figures.
///
/// Farsi/Persian names and text won't render in the exported PDF with
  /// the `pdf` package's default fonts (Latin-only) — a real gap for a
  /// product that advertises Farsi support. If a Farsi-capable TTF has
  /// been bundled at these paths (see assets/fonts/README.md — e.g.
  /// Vazirmatn, the same font the app's own UI can optionally use), this
  /// registers it as the PDF's theme so Persian text renders correctly.
  /// If the font isn't present, this fails silently and the PDF falls
  /// back to the default font exactly as before — never a crash, just
  /// the pre-existing limitation until the font file is added.
  static Future<pw.ThemeData?> _tryLoadFarsiTheme() async {
    try {
      final regularBytes = await rootBundle.load('assets/fonts/Vazirmatn-Regular.ttf');
      final boldBytes = await rootBundle.load('assets/fonts/Vazirmatn-Bold.ttf');
      return pw.ThemeData.withFont(
        base: pw.Font.ttf(regularBytes),
        bold: pw.Font.ttf(boldBytes),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<File> exportSessionPdf(PokerSession session) async {
    final theme = await _tryLoadFarsiTheme();
    final doc = pw.Document(theme: theme);
    final players = SessionService.playersFor(session.id);
    final txs = SessionService.transactionsFor(session.id);
    final balance = SessionService.checkBalance(session.id);
    final fin = FinancialLedgerService.snapshotForSession(
      session.id,
      currency: session.currency,
    );
    final settlement =
        SessionSettlementView.load(session.id, session.currency);
    final fmt = CurrencyFormatter(session.currency);

    final overlay = RebateService.overlayFor(
      sessionId: session.id,
      currency: session.currency,
      rawDiscrepancy: balance.discrepancy,
      moneyStillInPlay: SessionService.moneyStillInPlay(session.id),
    );
    final extremes = ReportService.sessionExtremes(session);

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: pw.EdgeInsets.zero,
        build: (context) => [
          _reportHeader(
            session.name,
            '${session.location}  |  Table ${session.tableNumber}  |  '
            '${session.dateTime.toString().substring(0, 16)}',
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.fromLTRB(18, 6, 18, 0),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.SizedBox(height: 6),
                pw.Text(
                  session.isTournament
                      ? 'Tournament'
                      : 'Cash game  |  Blinds '
                          '${fmt.formatRaw(session.smallBlind)}/'
                          '${fmt.formatRaw(session.bigBlind)}  |  '
                          'Rake ${session.rakePercentage}%',
                  style: const pw.TextStyle(fontSize: 10, color: _muted),
                ),
                if (extremes.winner != null || extremes.loser != null) ...[
                  pw.SizedBox(height: 8),
                  pw.Row(children: [
                    if (extremes.winner != null)
                      pw.Expanded(
                        child: pw.Text(
                          'Biggest winner: ${extremes.winner} '
                          '(+${fmt.formatRaw(extremes.winAmount)})',
                          style: const pw.TextStyle(
                              fontSize: 10, color: _emerald),
                        ),
                      ),
                    if (extremes.loser != null)
                      pw.Expanded(
                        child: pw.Text(
                          'Biggest loser: ${extremes.loser} '
                          '(${fmt.formatRaw(extremes.lossAmount)})',
                          style: const pw.TextStyle(
                              fontSize: 10, color: _muted),
                        ),
                      ),
                  ]),
                ],
                _sectionTitle('Summary'),
              ],
            ),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 18),
            child: _table(
            align: const {1: pw.Alignment.centerRight},
            headers: ['Metric', 'Amount'],
            data: [
              ['Total Buy-in', fmt.formatRaw(SessionService.totalBuyIn(session.id))],
              ['Total Rebuy', fmt.formatRaw(SessionService.totalRebuy(session.id))],
              ['Money In (Buy-in + Rebuy)', fmt.formatRaw(balance.moneyIn)],
              ['Total Cash-out', fmt.formatRaw(SessionService.totalCashOut(session.id))],
              ['Rake Collected', fmt.formatRaw(SessionService.totalRake(session.id))],
              ['Dealer Tips (in Money Out, not Host Profit)',
                  fmt.formatRaw(SessionService.totalDealerTips(session.id))],
              ['Money Out (Cash-out + Rake + Dealer Tips)', fmt.formatRaw(balance.moneyOut)],
              ['Cash Drops (tracked, not part of settlement)',
                  fmt.formatRaw(SessionService.totalCashDrop(session.id))],
              ['Host Profit (rake only)', fmt.formatRaw(SessionService.hostProfit(session.id))],
              [
                'Balance Status',
                overlay != null && overlay.explainsGap
                    ? 'EXPLAINED BY DISCOUNT CHIPS: '
                        '${fmt.formatRaw(balance.discrepancy.abs())}'
                    : balance.isBalanced
                        ? (overlay != null
                            ? 'BALANCED (Discount chips still in play)'
                            : 'BALANCED')
                        : 'DISCREPANCY: ${fmt.formatRaw(balance.discrepancy.abs())}'
              ],
              if (overlay != null) ...[
                [
                  'Discount chips issued (not Money In)',
                  fmt.formatRaw(overlay.issuedMajor),
                ],
                [
                  'Poker-book residual after Discount chips',
                  fmt.formatRaw(overlay.residualAfterDiscount),
                ],
                [
                  'Still in play including Discount chips',
                  fmt.formatRaw(overlay.impliedStillInPlay),
                ],
              ],
            ],
          ),
          ),
          if (balance.playersNeverCashedOut.isNotEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.fromLTRB(18, 8, 18, 0),
              child: pw.Text(
                'Note: no cash-out recorded for '
                '${balance.playersNeverCashedOut.map((p) => p.name).join(', ')}.',
                style: const pw.TextStyle(fontSize: 9, color: _muted),
              ),
            ),
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 18),
            child: _sectionTitle('Financial account (this session)'),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 18),
            child: _table(
              align: const {1: pw.Alignment.centerRight},
              headers: ['Metric', 'Amount'],
              data: [
                ['Credit issued', fmt.formatRaw(fin.creditIssued)],
                ['Credit repaid', fmt.formatRaw(fin.creditRepaid)],
                ['Unbacked cash-out', fmt.formatRaw(fin.cashOutUnbacked)],
                ['Cash paid for chips', fmt.formatRaw(fin.cashInForChips)],
                ['Cash received for returned chips',
                    fmt.formatRaw(fin.cashOutForChips)],
              ],
            ),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 18),
            child: _sectionTitle('Deposit (this session)'),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 18),
            child: _table(
              align: const {1: pw.Alignment.centerRight},
              headers: ['Metric', 'Amount'],
              data: [
                ['Deposit received', fmt.formatRaw(fin.depositIn)],
                ['Deposit used for chips', fmt.formatRaw(fin.depositUsedForChips)],
                ['Deposit returned', fmt.formatRaw(fin.depositReturned)],
                ['Deposit remaining', fmt.formatRaw(fin.depositRemaining)],
              ],
            ),
          ),
          ..._rebatePdfSection(session, settlement, fmt),
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 18),
            child: _sectionTitle('Players'),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 18),
            child: _table(
            align: const {
              0: pw.Alignment.center,
              2: pw.Alignment.centerRight,
              3: pw.Alignment.centerRight,
              4: pw.Alignment.centerRight,
            },
            headers: [
              'Seat', 'Name', 'Buy-in+Rebuy', 'Cash-out', 'P/L',
              'Cashed out', 'Deposit remaining',
            ],
            data: settlement.players.map((row) {
              return [
                row.player.seatNumber.toString(),
                row.player.name,
                fmt.formatRaw(row.buyIn + row.rebuy),
                fmt.formatRaw(row.cashOut),
                fmt.formatRaw(row.chipProfitLoss),
                row.hasCashedOut ? 'Yes' : 'No',
                fmt.formatRaw(row.financial.depositRemaining),
              ];
            }).toList(),
          ),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 18),
            child: _sectionTitle('Transaction log'),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.fromLTRB(18, 0, 18, 18),
            child: _table(
            align: const {3: pw.Alignment.centerRight, 4: pw.Alignment.center},
            headers: ['Time', 'Type', 'Player', 'Amount', 'Signed'],
            data: txs.map((t) {
              final player = t.playerId == null
                  ? '-'
                  : players
                      .firstWhere((p) => p.id == t.playerId,
                          orElse: () => players.first)
                      .name;
              return [
                t.timestamp.toString().substring(0, 16),
                t.type.label,
                player,
                fmt.formatRaw(t.amount),
                t.hostSignatureBase64 != null ? 'Yes' : '-',
              ];
            }).toList(),
          ),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 18),
            child: _footerNote(),
          ),
        ],
      ),
    );

    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/session_${session.id}.pdf');
    await file.writeAsBytes(await doc.save());
    return file;
  }

  static Future<File> exportSessionCsv(PokerSession session) async {
    final txs = SessionService.transactionsFor(session.id);
    final players = SessionService.playersFor(session.id);
    final books = SessionService.checkBalance(session.id);
    final overlay = RebateService.overlayFor(
      sessionId: session.id,
      currency: session.currency,
      rawDiscrepancy: books.discrepancy,
      moneyStillInPlay: SessionService.moneyStillInPlay(session.id),
    );
    final rows = <List<dynamic>>[
      ['Timestamp', 'Type', 'Player', 'Amount', 'Note', 'Signed'],
      for (final t in txs)
        [
          t.timestamp.toIso8601String(),
          t.type.label,
          t.playerId == null
              ? ''
              : players
                  .firstWhere((p) => p.id == t.playerId, orElse: () => players.first)
                  .name,
          t.amount,
          t.note ?? '',
          t.hostSignatureBase64 != null ? 'Yes' : 'No',
        ],
      if (overlay != null) ...[
        <dynamic>[],
        ['Discount chips issued (not Money In)', overlay.issuedMajor],
        [
          'Poker-book residual after Discount chips',
          overlay.residualAfterDiscount,
        ],
        [
          'Still in play including Discount chips',
          overlay.impliedStillInPlay,
        ],
      ],
    ];
    final csv = const ListToCsvConverter().convert(rows);
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/session_${session.id}.csv');
    await file.writeAsString(csv);
    return file;
  }

  static Future<void> shareFile(File file) async {
    await Share.shareXFiles([XFile(file.path)]);
  }

  // ------------------------------------------------------------------
  // Shared report styling.
  //
  // Every generated document uses the same emerald/gold identity as the
  // app, so a report a banker hands to a player looks like it came from
  // the same product rather than a raw data dump.
  // ------------------------------------------------------------------

  static const _emerald = PdfColor.fromInt(0xFF1B7A4C);
  static const _deepFelt = PdfColor.fromInt(0xFF0F3D28);
  static const _gold = PdfColor.fromInt(0xFFB8922C);
  static const _ink = PdfColor.fromInt(0xFF12100E);
  static const _muted = PdfColor.fromInt(0xFF6B7975);
  static const _rowTint = PdfColor.fromInt(0xFFF2F6F4);

  /// Branded header band used at the top of every report.
  static pw.Widget _reportHeader(String title, String subtitle) {
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: const pw.BoxDecoration(color: _deepFelt),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text('POKER LEDGER',
                    style: pw.TextStyle(
                      fontSize: 9,
                      letterSpacing: 2.5,
                      color: _gold,
                      fontWeight: pw.FontWeight.bold,
                    )),
                pw.SizedBox(height: 5),
                pw.Text(title,
                    style: pw.TextStyle(
                      fontSize: 19,
                      color: PdfColors.white,
                      fontWeight: pw.FontWeight.bold,
                    )),
                if (subtitle.isNotEmpty) ...[
                  pw.SizedBox(height: 3),
                  pw.Text(subtitle,
                      style: const pw.TextStyle(
                          fontSize: 10, color: PdfColors.white)),
                ],
              ],
            ),
          ),
          pw.Container(
            width: 40,
            height: 40,
            decoration: pw.BoxDecoration(
              shape: pw.BoxShape.circle,
              border: pw.Border.all(color: _gold, width: 2.5),
            ),
            child: pw.Center(
              child: pw.Text('PL',
                  style: pw.TextStyle(
                      fontSize: 14,
                      color: _gold,
                      fontWeight: pw.FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  static List<pw.Widget> _rebatePdfSection(
    PokerSession session,
    SessionSettlementView settlement,
    CurrencyFormatter fmt,
  ) {
    var granted = 0;
    var lostInPlay = 0;
    var clawback = 0;
    var paid = 0;
    var cashIn = 0;
    var actual = 0;
    var retained = 0;
    final rows = <List<String>>[];
    for (final row in settlement.players) {
      final personId = row.player.personId;
      if (personId == null || personId.isEmpty) continue;
      final snap = RebateService.snapshot(
        sessionId: session.id,
        personId: personId,
        currency: session.currency,
      );
      if (!snap.hasActivity) continue;
      granted += snap.grantedMinor;
      lostInPlay += snap.lostInPlayMinor;
      clawback += snap.clawbackMinor;
      paid += snap.paidOutMinor;
      cashIn += snap.playerCashInMinor;
      actual += snap.actualCashPaidMinor;
      retained += snap.houseRetainedMinor;
      rows.add([
        row.player.name,
        fmt.formatRaw(snap.grossLoss),
        fmt.formatRaw(snap.granted),
        fmt.formatRaw(snap.lostInPlay),
        fmt.formatRaw(snap.clawback),
        fmt.formatRaw(snap.actualCashPaid),
        fmt.formatRaw(snap.houseRetained),
      ]);
    }
    if (granted == 0 && cashIn == 0) return const [];
    final overlay = RebateService.overlayFor(
      sessionId: session.id,
      currency: session.currency,
      rawDiscrepancy: SessionService.checkBalance(session.id).discrepancy,
      moneyStillInPlay: SessionService.moneyStillInPlay(session.id),
    );
    return [
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 18),
        child: _sectionTitle('Loss rebate / Discount (this session)'),
      ),
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 18),
        child: _table(
          align: const {1: pw.Alignment.centerRight},
          headers: ['Metric', 'Amount'],
          data: [
            ['Player own cash in', fmt.formatRaw(MoneyUnits.toMajor(session.currency, cashIn))],
            ['Discount granted', fmt.formatRaw(MoneyUnits.toMajor(session.currency, granted))],
            ['Discount consumed / lost in play', fmt.formatRaw(MoneyUnits.toMajor(session.currency, lostInPlay))],
            ['Discount cash recovered / clawed back', fmt.formatRaw(MoneyUnits.toMajor(session.currency, clawback))],
            ['Discount paid to player', fmt.formatRaw(MoneyUnits.toMajor(session.currency, paid))],
            ['Cash out paid', fmt.formatRaw(MoneyUnits.toMajor(session.currency, actual))],
            ['House retained from own cash', fmt.formatRaw(MoneyUnits.toMajor(session.currency, retained))],
            if (overlay != null) ...[
              ['Discount chips issued (not Money In)', fmt.formatRaw(overlay.issuedMajor)],
              ['Poker-book residual after Discount chips', fmt.formatRaw(overlay.residualAfterDiscount)],
              ['Still in play including Discount chips', fmt.formatRaw(overlay.impliedStillInPlay)],
            ],
          ],
        ),
      ),
      if (rows.isNotEmpty)
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 18),
          child: _table(
            headers: [
              'Player',
              'Eligible loss',
              'Granted',
              'Lost in play',
              'Cash recovered',
              'Cash out paid',
              'House retained',
            ],
            data: rows,
          ),
        ),
    ];
  }

  static pw.Widget _sectionTitle(String text) => pw.Container(
        margin: const pw.EdgeInsets.only(top: 18, bottom: 8),
        child: pw.Row(
          children: [
            pw.Container(width: 3, height: 13, color: _gold),
            pw.SizedBox(width: 7),
            pw.Text(text.toUpperCase(),
                style: pw.TextStyle(
                  fontSize: 10,
                  letterSpacing: 1.1,
                  fontWeight: pw.FontWeight.bold,
                  color: _emerald,
                )),
          ],
        ),
      );

  /// Consistent table styling for every report.
  static pw.Widget _table({
    required List<String> headers,
    required List<List<String>> data,
    Map<int, pw.Alignment>? align,
  }) {
    return pw.TableHelper.fromTextArray(
      headers: headers,
      data: data,
      border: null,
      headerStyle: pw.TextStyle(
        fontSize: 9,
        color: PdfColors.white,
        fontWeight: pw.FontWeight.bold,
      ),
      headerDecoration: const pw.BoxDecoration(color: _emerald),
      cellStyle: const pw.TextStyle(fontSize: 9.5, color: _ink),
      rowDecoration: const pw.BoxDecoration(color: _rowTint),
      oddRowDecoration: const pw.BoxDecoration(color: PdfColors.white),
      cellHeight: 20,
      headerAlignment: pw.Alignment.centerLeft,
      cellAlignments: align ?? const {},
    );
  }

  static pw.Widget _footerNote() => pw.Container(
        margin: const pw.EdgeInsets.only(top: 20),
        child: pw.Text(
          'Generated by Poker Ledger on '
          '${DateTime.now().toString().substring(0, 16)}. '
          'Figures are taken directly from the recorded ledger.',
          style: const pw.TextStyle(fontSize: 8, color: _muted),
        ),
      );

  static Future<File> _write(pw.Document doc, String name) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(await doc.save());
    return file;
  }

  // ------------------------------------------------------------------
  // Player performance across sessions
  // ------------------------------------------------------------------

  static Future<File> exportPlayerPerformancePdf(AppCurrency currency) async {
    final theme = await _tryLoadFarsiTheme();
    final doc = pw.Document(theme: theme);
    final fmt = CurrencyFormatter(currency);
    final rows = ReportService.playerPerformance(currency);
    final stats = ReportService.lifetime(currency);

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: pw.EdgeInsets.zero,
        build: (context) => [
          _reportHeader('Player Performance',
              '${rows.length} players across ${stats.sessions} sessions'),
          pw.Padding(
            padding: const pw.EdgeInsets.fromLTRB(18, 6, 18, 18),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                _sectionTitle('Results by player'),
                _table(
                  headers: [
                    'Player', 'Sessions', 'Total In', 'Cashed Out',
                    'Rebuys', 'Net', 'Last Played',
                  ],
                  align: const {
                    1: pw.Alignment.center,
                    2: pw.Alignment.centerRight,
                    3: pw.Alignment.centerRight,
                    4: pw.Alignment.center,
                    5: pw.Alignment.centerRight,
                  },
                  data: [
                    for (final r in rows)
                      [
                        r.name,
                        '${r.sessions}',
                        fmt.formatRaw(r.totalIn),
                        fmt.formatRaw(r.totalOut),
                        '${r.rebuys}',
                        '${r.net >= 0 ? '+' : ''}${fmt.formatRaw(r.net)}',
                        r.lastPlayed?.toString().substring(0, 10) ?? '-',
                      ],
                  ],
                ),
                if (rows.isEmpty)
                  pw.Text('No player data for this currency yet.',
                      style: const pw.TextStyle(fontSize: 10, color: _muted)),
                _sectionTitle('Note'),
                pw.Text(
                  'Net is cash-out minus everything the player put in '
                  '(buy-ins plus rebuys). A positive figure means the '
                  'player finished ahead across the period.',
                  style: const pw.TextStyle(fontSize: 9, color: _muted),
                ),
                _footerNote(),
              ],
            ),
          ),
        ],
      ),
    );
    return _write(doc, 'player_performance_${currency.name}.pdf');
  }

  static Future<File> exportPlayerPerformanceCsv(AppCurrency currency) async {
    final rows = ReportService.playerPerformance(currency);
    final data = <List<dynamic>>[
      ['Player', 'Sessions', 'Total In', 'Cashed Out', 'Rebuys', 'Net',
       'Last Played'],
      for (final r in rows)
        [
          r.name,
          r.sessions,
          r.totalIn,
          r.totalOut,
          r.rebuys,
          r.net,
          r.lastPlayed?.toIso8601String() ?? '',
        ],
    ];
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/player_performance_${currency.name}.csv');
    await file.writeAsString(const ListToCsvConverter().convert(data));
    return file;
  }

  // ------------------------------------------------------------------
  // Banker profit / lifetime / monthly
  // ------------------------------------------------------------------

  static Future<File> exportBankerReportPdf(AppCurrency currency) async {
    final theme = await _tryLoadFarsiTheme();
    final doc = pw.Document(theme: theme);
    final fmt = CurrencyFormatter(currency);
    final lifetime = ReportService.lifetime(currency);
    final months = ReportService.monthly(currency);
    final sessions = ReportService.sessionsIn(currency);

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: pw.EdgeInsets.zero,
        build: (context) => [
          _reportHeader('Banker Report',
              'Lifetime and monthly performance'),
          pw.Padding(
            padding: const pw.EdgeInsets.fromLTRB(18, 6, 18, 18),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                _sectionTitle('Lifetime'),
                _table(
                  headers: ['Metric', 'Value'],
                  align: const {1: pw.Alignment.centerRight},
                  data: [
                    ['Sessions hosted', '${lifetime.sessions}'],
                    ['Player entries', '${lifetime.players}'],
                    ['Money in (buy-ins + rebuys)',
                        fmt.formatRaw(lifetime.moneyIn)],
                    ['Cashed out to players', fmt.formatRaw(lifetime.cashedOut)],
                    ['Rake collected', fmt.formatRaw(lifetime.rake)],
                    ['Banker profit', fmt.formatRaw(lifetime.bankerProfit)],
                    ['Average profit per session',
                        fmt.formatRaw(lifetime.averagePerSession)],
                    ['Average buy-in per entry',
                        fmt.formatRaw(lifetime.averageBuyIn)],
                  ],
                ),
                _sectionTitle('By month'),
                _table(
                  headers: ['Month', 'Sessions', 'Money In', 'Rake', 'Profit'],
                  align: const {
                    1: pw.Alignment.center,
                    2: pw.Alignment.centerRight,
                    3: pw.Alignment.centerRight,
                    4: pw.Alignment.centerRight,
                  },
                  data: [
                    for (final m in months)
                      [
                        m.label,
                        '${m.sessions}',
                        fmt.formatRaw(m.moneyIn),
                        fmt.formatRaw(m.rake),
                        fmt.formatRaw(m.bankerProfit),
                      ],
                  ],
                ),
                _sectionTitle('Sessions'),
                _table(
                  headers: ['Date', 'Session', 'Mode', 'Players', 'Profit'],
                  align: const {
                    3: pw.Alignment.center,
                    4: pw.Alignment.centerRight,
                  },
                  data: [
                    for (final s in sessions.take(40))
                      [
                        s.dateTime.toString().substring(0, 10),
                        s.name,
                        s.isTournament ? 'Tournament' : 'Cash',
                        '${SessionService.playersFor(s.id).length}',
                        fmt.formatRaw(s.isTournament
                            ? TournamentService.houseFee(s)
                            : SessionService.hostProfit(s.id)),
                      ],
                  ],
                ),
                _footerNote(),
              ],
            ),
          ),
        ],
      ),
    );
    return _write(doc, 'banker_report_${currency.name}.pdf');
  }

  static Future<File> exportBankerReportCsv(AppCurrency currency) async {
    final months = ReportService.monthly(currency);
    final lifetime = ReportService.lifetime(currency);
    final data = <List<dynamic>>[
      ['Period', 'Sessions', 'Player Entries', 'Money In', 'Cashed Out',
       'Rake', 'Banker Profit'],
      [
        'Lifetime',
        lifetime.sessions,
        lifetime.players,
        lifetime.moneyIn,
        lifetime.cashedOut,
        lifetime.rake,
        lifetime.bankerProfit,
      ],
      for (final m in months)
        [
          m.label,
          m.sessions,
          m.players,
          m.moneyIn,
          m.cashedOut,
          m.rake,
          m.bankerProfit,
        ],
    ];
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/banker_report_${currency.name}.csv');
    await file.writeAsString(const ListToCsvConverter().convert(data));
    return file;
  }

  // ------------------------------------------------------------------
  // Tournament result sheet
  // ------------------------------------------------------------------

  static Future<File> exportTournamentPdf(PokerSession session) async {
    final theme = await _tryLoadFarsiTheme();
    final doc = pw.Document(theme: theme);
    final fmt = CurrencyFormatter(session.currency);
    final payouts = TournamentService.payoutTable(session);
    final finished = TournamentService.eliminatedPlayers(session.id);

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: pw.EdgeInsets.zero,
        build: (context) => [
          _reportHeader(session.name,
              'Tournament results  |  ${session.dateTime.toString().substring(0, 16)}'),
          pw.Padding(
            padding: const pw.EdgeInsets.fromLTRB(18, 6, 18, 18),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                _sectionTitle('Prize pool'),
                _table(
                  headers: ['Metric', 'Amount'],
                  align: const {1: pw.Alignment.centerRight},
                  data: [
                    ['Entries', '${TournamentService.entryCount(session)}'],
                    ['Rebuys', '${TournamentService.rebuyCount(session)}'],
                    ['Total collected',
                        fmt.formatRaw(TournamentService.totalCollected(session.id))],
                    ['House fee', fmt.formatRaw(TournamentService.houseFee(session))],
                    ['Prize pool',
                        fmt.formatRaw(TournamentService.prizePool(session))],
                    ['Paid out',
                        fmt.formatRaw(TournamentService.totalPaidOut(session.id))],
                  ],
                ),
                _sectionTitle('Payouts'),
                _table(
                  headers: ['Place', 'Player', 'Share', 'Prize'],
                  align: const {
                    0: pw.Alignment.center,
                    2: pw.Alignment.centerRight,
                    3: pw.Alignment.centerRight,
                  },
                  data: [
                    for (final p in payouts)
                      [
                        '${p.position}',
                        p.player?.name ?? '-',
                        '${p.percentage.toStringAsFixed(1)}%',
                        fmt.formatRaw(p.amount),
                      ],
                  ],
                ),
                _sectionTitle('Final standings'),
                _table(
                  headers: ['Place', 'Player', 'Eliminated'],
                  align: const {0: pw.Alignment.center},
                  data: [
                    for (final p in finished)
                      [
                        '${p.finishPosition}',
                        p.name,
                        p.eliminatedAt?.toString().substring(0, 16) ?? '-',
                      ],
                  ],
                ),
                _footerNote(),
              ],
            ),
          ),
        ],
      ),
    );
    return _write(doc, 'tournament_${session.id}.pdf');
  }
}
