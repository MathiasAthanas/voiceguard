import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../../core/constants/app_colors.dart';
import '../../core/models/contact_model.dart';
import '../../core/services/cellular_call_service.dart';
import '../../core/services/verification_service.dart';
import '../enroll/enroll_screen.dart';
import '../in_call/in_call_screen.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  late Box _contactsBox;
  final TextEditingController _searchController = TextEditingController();
  List<ContactModel> _contacts = [];
  String _searchQuery = '';
  bool _isLoading = false;
  // Prevents double-tap from pushing two InCallScreens, which would create two
  // peer connections sharing the same WebRTCService and race each other.
  bool _voipNavigating = false;

  @override
  void initState() {
    super.initState();
    _contactsBox = Hive.box('contacts');
    _loadContacts();
  }

  Future<void> _loadContacts() async {
    setState(() => _isLoading = true);

    final permission = await Permission.contacts.request();
    final savedContacts = _loadSavedContacts();
    var contacts = savedContacts;

    if (permission.isGranted && mounted) {
      final deviceContacts =
          await context.read<CellularCallService>().getDeviceContacts();
      final savedByNumber = {
        for (final contact in savedContacts)
          _normalizePhone(contact.phoneNumber): contact,
      };

      contacts = deviceContacts.map((contact) {
        final saved = savedByNumber[_normalizePhone(contact.phoneNumber)];
        return contact.copyWith(
          id: saved?.id ?? contact.id,
          alternatePhoneNumber: saved?.alternatePhoneNumber,
          email: saved?.email,
          notes: saved?.notes,
          phoneLabel: saved?.phoneLabel,
          isFavorite: saved?.isFavorite,
          isEnrolled: saved?.isEnrolled ?? false,
          enrolledAt: saved?.enrolledAt,
          avatarUrl: saved?.avatarUrl,
        );
      }).toList();

      final deviceNumbers = {
        for (final contact in deviceContacts)
          _normalizePhone(contact.phoneNumber),
      };
      contacts.addAll(savedContacts.where((contact) =>
          !deviceNumbers.contains(_normalizePhone(contact.phoneNumber))));
    }

    contacts
        .sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    if (!mounted) return;
    setState(() {
      _contacts = contacts;
      _isLoading = false;
    });
  }

  List<ContactModel> _loadSavedContacts() {
    return _contactsBox.values
        .map((e) => ContactModel.fromMap(Map<String, dynamic>.from(e)))
        .toList();
  }

  String _normalizePhone(String phoneNumber) {
    return phoneNumber.replaceAll(RegExp(r'\D'), '');
  }

  List<ContactModel> get _filteredContacts {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return _contacts;

    final normalizedQuery = _normalizePhone(query);
    return _contacts.where((contact) {
      final name = contact.name.toLowerCase();
      final number = contact.phoneNumber.toLowerCase();
      final normalizedNumber = _normalizePhone(contact.phoneNumber);
      return name.contains(query) ||
          number.contains(query) ||
          (normalizedQuery.isNotEmpty &&
              normalizedNumber.contains(normalizedQuery));
    }).toList();
  }

  void _addContact() {
    final nameCtrl = TextEditingController();
    final numberCtrl = TextEditingController();
    final alternateCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    final notesCtrl = TextEditingController();
    var phoneLabel = 'Mobile';
    var saveToDevice = true;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: AppColors.surface,
          title:
              const Text('Add Contact', style: TextStyle(color: Colors.white)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildField(nameCtrl, 'Full name', Icons.person),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: _buildField(
                        numberCtrl,
                        'Phone number',
                        Icons.phone,
                        isPhone: true,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: phoneLabel,
                        dropdownColor: AppColors.cardBg,
                        style: const TextStyle(color: Colors.white),
                        decoration: _fieldDecoration('Type', Icons.label),
                        items: const ['Mobile', 'Home', 'Work', 'Main']
                            .map((label) => DropdownMenuItem(
                                  value: label,
                                  child: Text(label),
                                ))
                            .toList(),
                        onChanged: (value) {
                          if (value != null) {
                            setDialogState(() => phoneLabel = value);
                          }
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _buildField(
                  alternateCtrl,
                  'Alternate phone',
                  Icons.phone_android,
                  isPhone: true,
                ),
                const SizedBox(height: 12),
                _buildField(emailCtrl, 'Email', Icons.email, isEmail: true),
                const SizedBox(height: 12),
                _buildField(notesCtrl, 'Notes', Icons.notes, maxLines: 3),
                const SizedBox(height: 8),
                CheckboxListTile(
                  value: saveToDevice,
                  contentPadding: EdgeInsets.zero,
                  activeColor: AppColors.primary,
                  title: const Text(
                    'Save to phone contacts',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                  onChanged: (value) =>
                      setDialogState(() => saveToDevice = value ?? true),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child:
                  const Text('Cancel', style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              onPressed: () async {
                final name = nameCtrl.text.trim();
                final number = numberCtrl.text.trim();
                if (name.isEmpty || number.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('Name and phone number are required'),
                    backgroundColor: AppColors.warning,
                  ));
                  return;
                }

                var savedToDevice = false;
                if (saveToDevice) {
                  final permission = await Permission.contacts.request();
                  if (permission.isGranted && mounted) {
                    savedToDevice = await context
                        .read<CellularCallService>()
                        .saveDeviceContact(
                          name: name,
                          phoneNumber: number,
                          alternatePhoneNumber:
                              alternateCtrl.text.trim().isEmpty
                                  ? null
                                  : alternateCtrl.text.trim(),
                          email: emailCtrl.text.trim().isEmpty
                              ? null
                              : emailCtrl.text.trim(),
                          notes: notesCtrl.text.trim().isEmpty
                              ? null
                              : notesCtrl.text.trim(),
                          phoneLabel: phoneLabel,
                        );
                  }
                }

                final contact = ContactModel(
                  id: const Uuid().v4(),
                  name: name,
                  phoneNumber: number,
                  alternatePhoneNumber: alternateCtrl.text.trim().isEmpty
                      ? null
                      : alternateCtrl.text.trim(),
                  email: emailCtrl.text.trim().isEmpty
                      ? null
                      : emailCtrl.text.trim(),
                  notes: notesCtrl.text.trim().isEmpty
                      ? null
                      : notesCtrl.text.trim(),
                  phoneLabel: phoneLabel,
                );
                await _contactsBox.put(contact.id, contact.toMap());
                if (mounted) {
                  setState(() {
                    _contacts = [
                      contact,
                      ..._contacts.where((c) => c.id != contact.id),
                    ]..sort((a, b) =>
                        a.name.toLowerCase().compareTo(b.name.toLowerCase()));
                  });
                }
                await _loadContacts();
                if (!mounted) return;
                Navigator.pop(context);

                var openedNativeSave = false;
                if (saveToDevice && !savedToDevice) {
                  openedNativeSave = await context
                      .read<CellularCallService>()
                      .openNativeContactInsert(
                        name: name,
                        phoneNumber: number,
                        alternatePhoneNumber: alternateCtrl.text.trim().isEmpty
                            ? null
                            : alternateCtrl.text.trim(),
                        email: emailCtrl.text.trim().isEmpty
                            ? null
                            : emailCtrl.text.trim(),
                        notes: notesCtrl.text.trim().isEmpty
                            ? null
                            : notesCtrl.text.trim(),
                      );
                }

                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(savedToDevice
                      ? 'Contact saved to phone and VoiceGuard'
                      : openedNativeSave
                          ? 'Contact saved in VoiceGuard. Confirm phone contact save on the next screen.'
                          : 'Contact saved in VoiceGuard'),
                  backgroundColor:
                      savedToDevice ? AppColors.verified : AppColors.surface,
                ));
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _fieldDecoration(String hint, IconData icon) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.white38),
      filled: true,
      fillColor: AppColors.cardBg,
      prefixIcon: Icon(icon, color: AppColors.primary),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
    );
  }

  Widget _buildField(
    TextEditingController ctrl,
    String hint,
    IconData icon, {
    bool isPhone = false,
    bool isEmail = false,
    int maxLines = 1,
  }) {
    return TextField(
      controller: ctrl,
      style: const TextStyle(color: Colors.white),
      keyboardType: isPhone
          ? TextInputType.phone
          : isEmail
              ? TextInputType.emailAddress
              : TextInputType.text,
      maxLines: maxLines,
      decoration: _fieldDecoration(hint, icon),
    );
  }

  void _deleteContact(ContactModel contact) {
    // Use addPostFrameCallback so the PopupMenu fully closes before the dialog opens
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text(
            'Delete contact?',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: Text(
            'Remove ${contact.name} from VoiceGuard? This will not delete them from your device contacts.',
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style:
                  ElevatedButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      ).then((confirmed) {
        if (confirmed == true && mounted) {
          _contactsBox.delete(contact.id);
          _loadContacts();
        }
      });
    });
  }

  Future<void> _markEnrolled(ContactModel contact) async {
    final enrolled = contact.copyWith(
      isEnrolled: true,
      enrolledAt: DateTime.now(),
    );
    await _contactsBox.put(enrolled.id, enrolled.toMap());
    await _loadContacts();
  }

  /// Delete the AI voiceprint, mark unenrolled in Hive, then open EnrollScreen.
  Future<void> _reEnrollContact(ContactModel contact) async {
    // Optimistically clear the local enrollment flag immediately
    final unenrolled = contact.copyWith(isEnrolled: false, enrolledAt: null);
    await _contactsBox.put(unenrolled.id, unenrolled.toMap());

    if (!mounted) return;

    // Delete from AI backend (non-blocking — if it fails the new enrollment
    // will overwrite the old voiceprint anyway)
    context.read<VerificationService>().deleteVoiceprint(contact.name);

    final enrolled = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => EnrollScreen(contact: unenrolled)),
    );

    if (enrolled == true) {
      await _markEnrolled(contact);
    } else {
      _loadContacts();
    }
  }

  void _voipCallContact(ContactModel contact) {
    if (contact.phoneNumber.isEmpty || _voipNavigating) return;
    _voipNavigating = true;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => InCallScreen(
          contactName: contact.name,
          contactNumber: contact.phoneNumber,
          isVoIP: true,
          isIncoming: false,
        ),
      ),
    ).whenComplete(() {
      if (mounted) setState(() => _voipNavigating = false);
    });
  }

  void _callContact(ContactModel contact) async {
    if (contact.phoneNumber.isEmpty) return;

    final cellular = context.read<CellularCallService>();

    // Guard: don't place a new call while one is already in progress
    if (cellular.callState != CellularCallState.idle) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('A call is already in progress'),
        backgroundColor: AppColors.danger,
        duration: Duration(seconds: 2),
      ));
      return;
    }

    final phoneStatus = await Permission.phone.request();
    if (!mounted) return;

    if (!phoneStatus.isGranted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Phone permission is required to place calls'),
        backgroundColor: AppColors.danger,
        duration: Duration(seconds: 2),
      ));
      return;
    }

    // VoiceGuardInCallService (which drives all call-state events) only binds
    // when VoiceGuard is the default phone app. Without this role call-state
    // updates won't reach InCallScreen, so we handle the two cases separately.
    final isDefault = await cellular.isDefaultDialer();
    if (!mounted) return;

    if (!isDefault) {
      // Not the default dialer — give the user a real choice instead of
      // silently returning after the dialog (the old bug that meant "nothing
      // happens" after tapping "Set Now" and coming back).
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text(
            'Default Phone App Required',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: const Text(
            'VoiceGuard needs to be your default phone app to monitor '
            'and protect outgoing calls.\n\n'
            'Tap "Set Default" to enable full protection, or "Call Now" '
            'to call immediately without monitoring.',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: const Text('Cancel',
                  style: TextStyle(color: Colors.white54)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'call_now'),
              child: Text('Call Now',
                  style: TextStyle(color: AppColors.warning)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, 'set_default'),
              style:
                  ElevatedButton.styleFrom(backgroundColor: AppColors.primary),
              child: const Text('Set Default'),
            ),
          ],
        ),
      );

      if (!mounted || choice == null || choice == 'cancel') return;

      if (choice == 'set_default') {
        await cellular.requestDefaultDialer();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'After setting VoiceGuard as default, tap Call again to connect with protection'),
            backgroundColor: AppColors.primary,
            duration: Duration(seconds: 5),
          ));
        }
        return;
      }

      // 'call_now': place the call via the system path (Kotlin falls back to
      // ACTION_CALL when tm.placeCall fails). The system phone app handles the
      // UI — don't push InCallScreen, which would be stuck at "Calling…" with
      // no state updates since VoiceGuardInCallService isn't bound.
      await cellular.makeCall(contact.phoneNumber);
      return;
    }

    // VoiceGuard IS the default dialer — full monitoring with InCallScreen.
    await cellular.makeCall(contact.phoneNumber);
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => InCallScreen(
          contactName: contact.name,
          contactNumber: contact.phoneNumber,
          isVoIP: false,
          isIncoming: false,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primary))
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: TextField(
                    controller: _searchController,
                    style: const TextStyle(color: Colors.white),
                    onChanged: (value) => setState(() => _searchQuery = value),
                    decoration: InputDecoration(
                      hintText: 'Search contacts',
                      hintStyle: const TextStyle(color: Colors.white38),
                      prefixIcon:
                          const Icon(Icons.search, color: Colors.white54),
                      suffixIcon: _searchQuery.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close,
                                  color: Colors.white54),
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _searchQuery = '');
                              },
                            ),
                      filled: true,
                      fillColor: AppColors.surface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: _filteredContacts.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.contacts_outlined,
                                  size: 64, color: Colors.white24),
                              const SizedBox(height: 16),
                              Text(
                                _searchQuery.isEmpty
                                    ? 'No contacts yet'
                                    : 'No matching contacts',
                                style: const TextStyle(
                                    color: Colors.white38, fontSize: 16),
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'Allow contacts permission or add a contact manually',
                                style: TextStyle(
                                    color: Colors.white24, fontSize: 13),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: _filteredContacts.length,
                          itemBuilder: (context, i) => _ContactTile(
                            contact: _filteredContacts[i],
                            onEnroll: () async {
                              final contact = _filteredContacts[i];
                              final enrolled = await Navigator.push<bool>(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      EnrollScreen(contact: contact),
                                ),
                              );
                              if (enrolled == true) {
                                await _markEnrolled(contact);
                              } else {
                                _loadContacts();
                              }
                            },
                            onReEnroll: () =>
                                _reEnrollContact(_filteredContacts[i]),
                            onCall: () => _callContact(_filteredContacts[i]),
                            onVoipCall: () =>
                                _voipCallContact(_filteredContacts[i]),
                            onDelete: () =>
                                _deleteContact(_filteredContacts[i]),
                          ),
                        ),
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppColors.primary,
        onPressed: _addContact,
        child: const Icon(Icons.person_add, color: Colors.white),
      ),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }
}

class _ContactTile extends StatelessWidget {
  final ContactModel contact;
  final VoidCallback onEnroll;
  final VoidCallback onReEnroll;
  final VoidCallback onCall;
  final VoidCallback onVoipCall;
  final VoidCallback onDelete;

  const _ContactTile({
    required this.contact,
    required this.onEnroll,
    required this.onReEnroll,
    required this.onCall,
    required this.onVoipCall,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: AppColors.primary.withValues(alpha: 0.2),
          child: Text(
            contact.initials,
            style: const TextStyle(
                color: AppColors.primary, fontWeight: FontWeight.bold),
          ),
        ),
        title: Text(contact.name, style: const TextStyle(color: Colors.white)),
        subtitle: Text(
          contact.phoneNumber.isEmpty ? 'No number' : contact.phoneNumber,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Enrollment status badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: contact.isEnrolled
                    ? AppColors.verified.withValues(alpha: 0.15)
                    : AppColors.warning.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                contact.isEnrolled ? '✓ Enrolled' : 'Not enrolled',
                style: TextStyle(
                  color: contact.isEnrolled
                      ? AppColors.verified
                      : AppColors.warning,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.call, color: AppColors.callGreen),
              onPressed: onCall,
            ),
            PopupMenuButton(
              icon: const Icon(Icons.more_vert, color: Colors.white38),
              color: AppColors.cardBg,
              itemBuilder: (_) => [
                // ── VoIP call ─────────────────────────────────────────────
                PopupMenuItem(
                  onTap: onVoipCall,
                  child: const Row(
                    children: [
                      Icon(Icons.wifi_calling_3,
                          color: AppColors.primary, size: 18),
                      SizedBox(width: 10),
                      Text('VoIP Call',
                          style: TextStyle(color: AppColors.primary)),
                    ],
                  ),
                ),
                // ── Enroll / Re-enroll (context-sensitive label) ──────────
                PopupMenuItem(
                  onTap: contact.isEnrolled ? onReEnroll : onEnroll,
                  child: Row(
                    children: [
                      Icon(
                        contact.isEnrolled
                            ? Icons.refresh
                            : Icons.record_voice_over,
                        color: contact.isEnrolled
                            ? AppColors.warning
                            : Colors.white,
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        contact.isEnrolled ? 'Re-enroll Voice' : 'Enroll Voice',
                        style: TextStyle(
                          color: contact.isEnrolled
                              ? AppColors.warning
                              : Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
                // ── Delete contact ────────────────────────────────────────
                PopupMenuItem(
                  onTap: onDelete,
                  child: const Row(
                    children: [
                      Icon(Icons.delete_outline,
                          color: AppColors.danger, size: 18),
                      SizedBox(width: 10),
                      Text('Delete', style: TextStyle(color: AppColors.danger)),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
