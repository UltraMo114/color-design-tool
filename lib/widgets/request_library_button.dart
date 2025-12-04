import 'package:flutter/material.dart';

import '../services/access_request_service.dart';

class RequestLibraryButton extends StatefulWidget {
  const RequestLibraryButton({
    super.key,
    required this.libraryId,
    required this.service,
  });

  final String libraryId;
  final AccessRequestService service;

  @override
  State<RequestLibraryButton> createState() => _RequestLibraryButtonState();
}

class _RequestLibraryButtonState extends State<RequestLibraryButton> {
  bool _sending = false;

  Future<void> _handlePressed() async {
    if (_sending) return;
    setState(() {
      _sending = true;
    });
    try {
      await widget.service.requestLibraryAccess(widget.libraryId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Request sent for ${widget.libraryId}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to send request: $e')));
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: _sending ? null : _handlePressed,
      icon: _sending
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.lock_open_outlined),
      label: Text(_sending ? 'Sending...' : 'Request Access'),
    );
  }
}
