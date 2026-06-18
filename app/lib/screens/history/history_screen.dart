import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/models/call_record_model.dart';
import '../../core/services/cellular_call_service.dart';
import '../in_call/in_call_screen.dart';

enum _Filter { all, missed, incoming, outgoing }

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late Box _historyBox;
  _Filter _filter = _Filter.all;
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  final Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _historyBox = Hive.box('call_history');
    _searchCtrl.addListener(
        () => setState(() => _query = _searchCtrl.text.trim().toLowerCase()));
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // ── Parsing & filtering ───────────────────────────────────────────────────

  List<CallRecordModel> _parseRecords() {
    final all = <CallRecordModel>[];
    for (final e in _historyBox.values) {
      try {
        all.add(CallRecordModel.fromMap(Map<String, dynamic>.from(e as Map)));
      } catch (_) {/* skip corrupt entry */}
    }
    all.sort((a, b) => b.startTime.compareTo(a.startTime));
    return all;
  }

  List<CallRecordModel> _applyFilters(List<CallRecordModel> all) {
    var records = all;

    // Direction filter
    switch (_filter) {
      case _Filter.missed:
        records =
            records.where((r) => r.direction == CallDirection.missed).toList();
        break;
      case _Filter.incoming:
        records = records
            .where((r) => r.direction == CallDirection.incoming)
            .toList();
        break;
      case _Filter.outgoing:
        records = records
            .where((r) => r.direction == CallDirection.outgoing)
            .toList();
        break;
      case _Filter.all:
        break;
    }

    // Search query
    if (_query.isNotEmpty) {
      records = records
          .where((r) =>
              r.contactName.toLowerCase().contains(_query) ||
              r.contactNumber.toLowerCase().contains(_query))
          .toList();
    }

    return records;
  }

  // ── Delete ────────────────────────────────────────────────────────────────

  Future<void> _deleteRecord(CallRecordModel record) async {
    await _historyBox.delete(record.id);
  }

  Future<void> _deleteSelected() async {
    final count = _selectedIds.length;
    if (count == 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Delete $count selected?',
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold)),
        content: const Text('Selected call history entries will be removed.',
            style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final id in _selectedIds) {
      await _historyBox.delete(id);
    }
    if (mounted) setState(_selectedIds.clear);
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Clear all history?',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: const Text('This cannot be undone.',
            style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _historyBox.clear();
  }

  // ── Call-back ─────────────────────────────────────────────────────────────

  Future<void> _callBack(CallRecordModel record) async {
    if (record.callType == CallType.voip) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          'To call ${record.contactName} back, open the VoIP tab and tap the call button when they are online.',
        ),
        backgroundColor: AppColors.surface,
        duration: const Duration(seconds: 4),
      ));
      return;
    }

    if (record.contactNumber.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No phone number saved for this contact'),
        backgroundColor: AppColors.danger,
      ));
      return;
    }

    final cellular = context.read<CellularCallService>();
    if (cellular.callState != CellularCallState.idle) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('A call is already active'),
        backgroundColor: AppColors.warning,
      ));
      return;
    }

    final isDefault = await cellular.isDefaultDialer();
    if (!mounted) return;
    if (!isDefault) {
      await cellular.requestDefaultDialer();
      return;
    }

    await cellular.makeCall(record.contactNumber);
    if (!mounted) return;

    Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => InCallScreen(
            contactName: record.contactName,
            contactNumber: record.contactNumber,
            isVoIP: false,
            isIncoming: false,
          ),
        ));
  }

  // ── Verdict helpers ───────────────────────────────────────────────────────

  IconData _directionIcon(CallDirection dir) {
    switch (dir) {
      case CallDirection.incoming:
        return Icons.call_received;
      case CallDirection.outgoing:
        return Icons.call_made;
      case CallDirection.missed:
        return Icons.call_missed;
    }
  }

  Color _directionColor(CallDirection dir) {
    switch (dir) {
      case CallDirection.incoming:
        return AppColors.verified;
      case CallDirection.outgoing:
        return AppColors.primary;
      case CallDirection.missed:
        return AppColors.danger;
    }
  }

  Color _verdictColor(String? v) {
    switch (v) {
      case 'verified_high':
      case 'verifiedHigh':
      case 'verified':
        return AppColors.verified;
      case 'spoof_detected':
      case 'spoofDetected':
        return AppColors.danger;
      case 'spoof_suspected':
      case 'spoofSuspected':
      case 'not_verified':
      case 'notVerified':
      case 'secondary_warning':
      case 'secondaryWarning':
        return AppColors.warning;
      default:
        return Colors.white38;
    }
  }

  String _verdictLabel(String? v) {
    switch (v) {
      case 'verified_high':
      case 'verifiedHigh':
        return 'Verified';
      case 'verified':
        return 'Likely verified';
      case 'spoof_detected':
      case 'spoofDetected':
        return 'Cloned voice detected';
      case 'spoof_suspected':
      case 'spoofSuspected':
        return 'Possible cloned voice';
      case 'not_verified':
      case 'notVerified':
        return 'Not verified';
      case 'secondary_warning':
      case 'secondaryWarning':
        return 'Secondary model warning';
      default:
        return '';
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: _historyBox.listenable(),
      builder: (context, Box box, _) {
        final all = _parseRecords();
        final records = _applyFilters(all);

        return Column(
          children: [
            // ── Toolbar: search + clear ──────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Search name or number…',
                      hintStyle:
                          const TextStyle(color: Colors.white38, fontSize: 14),
                      filled: true,
                      fillColor: AppColors.surface,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      prefixIcon: const Icon(Icons.search,
                          color: Colors.white38, size: 18),
                      suffixIcon: _query.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear,
                                  color: Colors.white38, size: 18),
                              onPressed: () {
                                _searchCtrl.clear();
                                setState(() => _query = '');
                              },
                            )
                          : null,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                if (all.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  if (_selectedIds.isNotEmpty) ...[
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54),
                      tooltip: 'Cancel selection',
                      onPressed: () => setState(_selectedIds.clear),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline,
                          color: AppColors.danger),
                      tooltip: 'Delete selected',
                      onPressed: _deleteSelected,
                    ),
                  ] else
                    IconButton(
                      icon: const Icon(Icons.delete_sweep_outlined,
                          color: Colors.white38),
                      tooltip: 'Clear all history',
                      onPressed: _clearAll,
                    ),
                ],
              ]),
            ),

            // ── Filter chips ─────────────────────────────────────────────
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Row(
                children: _Filter.values.map((f) {
                  final count = f == _Filter.all
                      ? all.length
                      : all.where((r) {
                          switch (f) {
                            case _Filter.missed:
                              return r.direction == CallDirection.missed;
                            case _Filter.incoming:
                              return r.direction == CallDirection.incoming;
                            case _Filter.outgoing:
                              return r.direction == CallDirection.outgoing;
                            default:
                              return true;
                          }
                        }).length;

                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(_filterLabel(f, count)),
                      selected: _filter == f,
                      onSelected: (_) => setState(() => _filter = f),
                      selectedColor: AppColors.primary.withValues(alpha: 0.25),
                      backgroundColor: AppColors.surface,
                      checkmarkColor: AppColors.primary,
                      labelStyle: TextStyle(
                        color:
                            _filter == f ? AppColors.primary : Colors.white54,
                        fontSize: 12,
                        fontWeight:
                            _filter == f ? FontWeight.w600 : FontWeight.normal,
                      ),
                      side: BorderSide(
                        color: _filter == f
                            ? AppColors.primary.withValues(alpha: 0.5)
                            : Colors.white12,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),

            // ── List ─────────────────────────────────────────────────────
            Expanded(
              child: records.isEmpty
                  ? _buildEmpty(all.isEmpty)
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                      itemCount: records.length,
                      itemBuilder: (context, i) => _buildTile(records[i]),
                    ),
            ),
          ],
        );
      },
    );
  }

  String _filterLabel(_Filter f, int count) {
    switch (f) {
      case _Filter.all:
        return 'All ($count)';
      case _Filter.missed:
        return 'Missed ($count)';
      case _Filter.incoming:
        return 'Incoming ($count)';
      case _Filter.outgoing:
        return 'Outgoing ($count)';
    }
  }

  Widget _buildEmpty(bool noData) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            noData ? Icons.history : Icons.filter_list_off,
            size: 64,
            color: Colors.white24,
          ),
          const SizedBox(height: 16),
          Text(
            noData ? 'No call history yet' : 'No calls match this filter',
            style: const TextStyle(color: Colors.white38, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text(
            noData
                ? 'Calls appear here after they end'
                : 'Try a different filter or search',
            style: const TextStyle(color: Colors.white24, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildTile(CallRecordModel record) {
    final dirColor = _directionColor(record.direction);
    final verdict = _verdictLabel(record.verificationVerdict);
    final vColor = _verdictColor(record.verificationVerdict);
    final isMissed = record.direction == CallDirection.missed;
    final selected = _selectedIds.contains(record.id);

    return Dismissible(
      key: Key(record.id),
      direction: _selectedIds.isEmpty
          ? DismissDirection.endToStart
          : DismissDirection.none,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: AppColors.danger.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      confirmDismiss: (_) async {
        // Quick confirm via snackbar undo pattern
        await _deleteRecord(record);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: const Text('Call deleted'),
            backgroundColor: AppColors.surface,
            duration: const Duration(seconds: 3),
            action: SnackBarAction(
              label: 'Undo',
              textColor: AppColors.primary,
              onPressed: () => _historyBox.put(record.id, record.toMap()),
            ),
          ));
        }
        return false; // Dismissible handles its own animation; Hive already updated
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.18)
              : AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: selected
              ? Border.all(color: AppColors.primary.withValues(alpha: 0.7))
              : null,
        ),
        child: ListTile(
          onTap: () {
            if (_selectedIds.isNotEmpty) {
              setState(() {
                selected
                    ? _selectedIds.remove(record.id)
                    : _selectedIds.add(record.id);
              });
            } else {
              _showCallDetails(record);
            }
          },
          onLongPress: () => setState(() => _selectedIds.add(record.id)),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          leading: CircleAvatar(
            backgroundColor: selected
                ? AppColors.primary.withValues(alpha: 0.25)
                : dirColor.withValues(alpha: 0.15),
            child: selected
                ? const Icon(Icons.check, color: AppColors.primary, size: 20)
                : Icon(_directionIcon(record.direction),
                    color: dirColor, size: 20),
          ),
          title: Row(children: [
            Flexible(
              child: Text(
                record.contactName,
                style: TextStyle(
                  color: isMissed ? AppColors.danger : Colors.white,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: record.callType == CallType.voip
                    ? AppColors.primary.withValues(alpha: 0.2)
                    : AppColors.secondary.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                record.callType == CallType.voip ? 'VoIP' : 'Cell',
                style: TextStyle(
                  color: record.callType == CallType.voip
                      ? AppColors.primary
                      : AppColors.secondary,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ]),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(record.formattedTime,
                  style: const TextStyle(color: Colors.white38, fontSize: 11)),
              if (isMissed)
                const Text('Missed call',
                    style: TextStyle(
                        color: AppColors.danger,
                        fontSize: 12,
                        fontWeight: FontWeight.w600))
              else if (verdict.isNotEmpty)
                Text(verdict,
                    style: TextStyle(
                        color: vColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
            ],
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(record.formattedDuration,
                      style:
                          const TextStyle(color: Colors.white54, fontSize: 12)),
                  if (record.verificationConfidence != null)
                    Text(
                      '${(record.verificationConfidence! * 100).round()}%',
                      style: TextStyle(
                          color: vColor,
                          fontSize: 12,
                          fontWeight: FontWeight.bold),
                    ),
                ],
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: Icon(
                  record.callType == CallType.voip
                      ? Icons.wifi_calling
                      : Icons.call,
                  size: 20,
                  color: AppColors.callGreen,
                ),
                tooltip: 'Call back',
                onPressed:
                    _selectedIds.isEmpty ? () => _callBack(record) : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showCallDetails(CallRecordModel record) {
    final verdict = _verdictLabel(record.verificationVerdict);
    final vColor = _verdictColor(record.verificationVerdict);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: vColor.withValues(alpha: 0.18),
                  child: Icon(_directionIcon(record.direction), color: vColor),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(record.contactName,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold)),
                      Text(record.contactNumber,
                          style: const TextStyle(color: Colors.white54)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            _detailRow('Call type',
                record.callType == CallType.voip ? 'VoIP' : 'Cellular'),
            _detailRow('Direction', record.direction.name),
            _detailRow('Time', record.formattedTime),
            _detailRow('Duration', record.formattedDuration),
            if (verdict.isNotEmpty)
              _detailRow('Detection result', verdict, valueColor: vColor),
            if (record.verificationConfidence != null)
              _detailRow('Confidence',
                  '${(record.verificationConfidence! * 100).round()}%',
                  valueColor: vColor),
            if (record.similarityScore != null)
              _detailRow(
                  'Voice match', '${(record.similarityScore! * 100).round()}%'),
            if (record.spoofProbability != null)
              _detailRow(
                  'Spoof risk', '${(record.spoofProbability! * 100).round()}%'),
            if (record.segmentsAnalyzed != null)
              _detailRow('Segments analyzed', '${record.segmentsAnalyzed}'),
            if (record.verificationMessage?.isNotEmpty == true) ...[
              const SizedBox(height: 8),
              Text(record.verificationMessage!,
                  style: const TextStyle(color: Colors.white60, fontSize: 13)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: const TextStyle(color: Colors.white38, fontSize: 13)),
          ),
          Text(value,
              style: TextStyle(
                color: valueColor ?? Colors.white,
                fontWeight: FontWeight.w600,
              )),
        ],
      ),
    );
  }
}
