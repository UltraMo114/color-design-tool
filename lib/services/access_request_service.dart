import 'package:mailer/mailer.dart';
import 'package:mailer/smtp_server.dart';

/// Holds SMTP credentials so they can be swapped without touching call-sites.
/// In release builds you can pass values via `--dart-define` using the keys
/// referenced below.
class AccessRequestCredentials {
  final String smtpHost;
  final int smtpPort;
  final String username;
  final String password;
  final bool useSsl;
  final String senderName;

  const AccessRequestCredentials({
    required this.smtpHost,
    required this.smtpPort,
    required this.username,
    required this.password,
    required this.useSsl,
    required this.senderName,
  });

  factory AccessRequestCredentials.fromEnvironment() {
    const host = String.fromEnvironment('CDT_SMTP_HOST', defaultValue: '');
    const port = int.fromEnvironment('CDT_SMTP_PORT', defaultValue: 465);
    const username = String.fromEnvironment(
      'CDT_SMTP_USERNAME',
      defaultValue: '',
    );
    const password = String.fromEnvironment(
      'CDT_SMTP_PASSWORD',
      defaultValue: '',
    );
    const useSsl = bool.fromEnvironment('CDT_SMTP_USE_SSL', defaultValue: true);
    const sender = String.fromEnvironment(
      'CDT_SMTP_SENDER',
      defaultValue: 'CDT App',
    );

    if (host.isEmpty || username.isEmpty || password.isEmpty) {
      throw StateError(
        'Missing SMTP credentials. Provide them via --dart-define '
        '(CDT_SMTP_HOST, CDT_SMTP_USERNAME, CDT_SMTP_PASSWORD).',
      );
    }

    return AccessRequestCredentials(
      smtpHost: host,
      smtpPort: port,
      username: username,
      password: password,
      useSsl: useSsl,
      senderName: sender,
    );
  }
}

/// Sends background email requests so users cannot edit the message content.
class AccessRequestService {
  AccessRequestService({
    required this.credentials,
    this.recipient = 'm.r.luo@zju.edu.cn',
    this.subject = 'Restricted QTX Library Access Request',
  });

  final AccessRequestCredentials credentials;
  final String recipient;
  final String subject;

  Future<void> requestLibraryAccess(String libraryId) async {
    final smtpServer = SmtpServer(
      credentials.smtpHost,
      port: credentials.smtpPort,
      ssl: credentials.useSsl,
      username: credentials.username,
      password: credentials.password,
    );

    final message = Message()
      ..from = Address(credentials.username, credentials.senderName)
      ..recipients.add(recipient)
      ..subject = subject
      ..text = _buildBody(libraryId);

    await send(message, smtpServer);
  }

  String _buildBody(String libraryId) {
    final timestamp = DateTime.now().toUtc().toIso8601String();
    return '''
Requesting access to restricted QTX library.

Library ID : $libraryId
Sent (UTC) : $timestamp

This request was generated automatically by the Color Design Tool mobile app.
''';
  }
}
