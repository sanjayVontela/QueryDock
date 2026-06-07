import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AiProvider { openAi, githubCopilot }

class AiAssistantSettings {
  final AiProvider provider;
  final String openAiApiKey;
  final String githubCopilotToken;
  final String model;

  const AiAssistantSettings({
    this.provider = AiProvider.openAi,
    this.openAiApiKey = '',
    this.githubCopilotToken = '',
    this.model = 'gpt-5.4-mini',
  });

  String get providerName =>
      provider == AiProvider.openAi ? 'OpenAI' : 'GitHub Copilot';

  bool get configured => switch (provider) {
    AiProvider.openAi => openAiApiKey.trim().isNotEmpty,
    AiProvider.githubCopilot => githubCopilotToken.trim().isNotEmpty,
  };
}

class AiAssistantSettingsStore {
  static const _openAiApiKeyStorageKey = 'ai.openai.api_key';
  static const _copilotTokenStorageKey = 'ai.github_copilot.token';
  static const _providerPreferenceKey = 'ai.provider';
  static const _modelPreferenceKey = 'ai.openai.model';
  static const _storage = FlutterSecureStorage();

  const AiAssistantSettingsStore();

  Future<AiAssistantSettings> load() async {
    final preferences = await SharedPreferences.getInstance();
    return AiAssistantSettings(
      provider: AiProvider.values.firstWhere(
        (provider) =>
            provider.name == preferences.getString(_providerPreferenceKey),
        orElse: () => AiProvider.openAi,
      ),
      openAiApiKey: await _storage.read(key: _openAiApiKeyStorageKey) ?? '',
      githubCopilotToken:
          await _storage.read(key: _copilotTokenStorageKey) ?? '',
      model:
          preferences.getString(_modelPreferenceKey)?.trim().isNotEmpty == true
          ? preferences.getString(_modelPreferenceKey)!.trim()
          : 'gpt-5.4-mini',
    );
  }

  Future<void> save(AiAssistantSettings settings) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_providerPreferenceKey, settings.provider.name);
    await preferences.setString(_modelPreferenceKey, settings.model.trim());
    if (settings.openAiApiKey.trim().isEmpty) {
      await _storage.delete(key: _openAiApiKeyStorageKey);
    } else {
      await _storage.write(
        key: _openAiApiKeyStorageKey,
        value: settings.openAiApiKey.trim(),
      );
    }
    if (settings.githubCopilotToken.trim().isEmpty) {
      await _storage.delete(key: _copilotTokenStorageKey);
    } else {
      await _storage.write(
        key: _copilotTokenStorageKey,
        value: settings.githubCopilotToken.trim(),
      );
    }
  }
}

class AiAssistantMessage {
  final String role;
  final String text;

  const AiAssistantMessage({required this.role, required this.text});
}

class AiAssistantClient {
  static const _endpoint = 'https://api.openai.com/v1/responses';

  Future<String> respond({
    required AiAssistantSettings settings,
    required List<AiAssistantMessage> conversation,
    required String context,
  }) async {
    if (!settings.configured) {
      throw AiAssistantException(
        '${settings.providerName} credentials are not configured.',
      );
    }

    final contextText = context.length > 60000
        ? '${context.substring(0, 60000)}\n[Context truncated]'
        : context;
    final recentConversation = conversation
        .skip(conversation.length > 12 ? conversation.length - 12 : 0)
        .toList();
    if (settings.provider == AiProvider.githubCopilot) {
      return _respondWithCopilot(
        settings: settings,
        conversation: recentConversation,
        context: contextText,
      );
    }
    return _respondWithOpenAi(
      settings: settings,
      conversation: recentConversation,
      context: contextText,
    );
  }

  Future<String> _respondWithOpenAi({
    required AiAssistantSettings settings,
    required List<AiAssistantMessage> conversation,
    required String context,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.postUrl(Uri.parse(_endpoint));
      request.headers
        ..contentType = ContentType.json
        ..set(
          HttpHeaders.authorizationHeader,
          'Bearer ${settings.openAiApiKey}',
        );
      request.write(
        jsonEncode(
          buildRequestBody(
            settings: settings,
            conversation: conversation,
            context: context,
          ),
        ),
      );

      final response = await request.close().timeout(
        const Duration(minutes: 2),
      );
      final body = await utf8.decoder.bind(response).join();
      final decoded = jsonDecode(body);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final error = decoded is Map<String, dynamic> ? decoded['error'] : null;
        final message = error is Map ? error['message']?.toString() : null;
        final code = error is Map ? error['code']?.toString() : null;
        final type = error is Map ? error['type']?.toString() : null;
        throw AiAssistantException(
          friendlyApiError(
            statusCode: response.statusCode,
            code: code,
            type: type,
            message: message,
          ),
        );
      }
      if (decoded is! Map<String, dynamic>) {
        throw const AiAssistantException(
          'OpenAI returned an invalid response.',
        );
      }
      final text = extractOutputText(decoded);
      if (text.isEmpty) {
        throw const AiAssistantException('OpenAI returned no text response.');
      }
      return text;
    } on AiAssistantException {
      rethrow;
    } on SocketException catch (error) {
      throw AiAssistantException('Network error: ${error.message}');
    } on TimeoutException {
      throw const AiAssistantException('OpenAI request timed out.');
    } catch (error) {
      throw AiAssistantException('AI request failed: $error');
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _respondWithCopilot({
    required AiAssistantSettings settings,
    required List<AiAssistantMessage> conversation,
    required String context,
  }) async {
    final prompt = buildCopilotPrompt(
      conversation: conversation,
      context: context,
    );
    Process? process;
    try {
      final processEnvironment = Map<String, String>.from(Platform.environment);
      final copilotExecutable = await _resolveCopilotExecutable(
        processEnvironment,
      );
      if (Platform.isWindows) {
        processEnvironment['PATH'] = await _refreshedWindowsPath(
          processEnvironment,
        );
      }
      processEnvironment['COPILOT_GITHUB_TOKEN'] = settings.githubCopilotToken
          .trim();
      process = await Process.start(
        copilotExecutable,
        copilotArguments(),
        workingDirectory: Directory.systemTemp.path,
        environment: processEnvironment,
        runInShell: Platform.isWindows && copilotExecutable == 'copilot',
      );
      process.stdin.write(prompt);
      await process.stdin.close();
      final outputFuture = utf8.decoder.bind(process.stdout).join();
      final errorFuture = utf8.decoder.bind(process.stderr).join();
      final exitCode = await process.exitCode.timeout(
        const Duration(minutes: 2),
        onTimeout: () {
          process?.kill();
          throw const AiAssistantException('GitHub Copilot request timed out.');
        },
      );
      final output = (await outputFuture).trim();
      final error = (await errorFuture).trim();
      if (exitCode != 0) {
        throw AiAssistantException(
          copilotError(exitCode: exitCode, error: error),
        );
      }
      if (output.isEmpty) {
        throw const AiAssistantException(
          'GitHub Copilot returned no text response.',
        );
      }
      return output;
    } on AiAssistantException {
      rethrow;
    } on ProcessException {
      throw const AiAssistantException(
        'GitHub Copilot CLI was not found. Install it, verify `copilot '
        '--version` works, and then retry.',
      );
    } catch (error) {
      throw AiAssistantException('GitHub Copilot request failed: $error');
    } finally {
      process?.kill();
    }
  }

  static Future<String> _resolveCopilotExecutable(
    Map<String, String> environment,
  ) async {
    if (!Platform.isWindows) {
      final home = environment['HOME'];
      final candidates = <String>[
        '/usr/local/bin/copilot',
        '/usr/bin/copilot',
        '/opt/homebrew/bin/copilot',
        if (home != null) '$home/.local/bin/copilot',
      ];
      for (final candidate in candidates) {
        if (await File(candidate).exists()) return candidate;
      }
      return 'copilot';
    }

    final localAppData =
        environment['LOCALAPPDATA'] ??
        (environment['USERPROFILE'] == null
            ? null
            : '${environment['USERPROFILE']}\\AppData\\Local');
    if (localAppData == null || localAppData.isEmpty) return 'copilot';

    final candidates = <String>[
      '$localAppData\\Microsoft\\WinGet\\Links\\copilot.exe',
      '$localAppData\\Microsoft\\WindowsApps\\copilot.exe',
    ];
    for (final candidate in candidates) {
      if (await File(candidate).exists()) return candidate;
    }

    final packages = Directory('$localAppData\\Microsoft\\WinGet\\Packages');
    try {
      await for (final entity in packages.list()) {
        if (entity is! Directory ||
            !entity.path
                .split(Platform.pathSeparator)
                .last
                .toLowerCase()
                .startsWith('github.copilot_')) {
          continue;
        }
        await for (final child in entity.list(recursive: true)) {
          if (child is File &&
              child.path.split(Platform.pathSeparator).last.toLowerCase() ==
                  'copilot.exe') {
            return child.path;
          }
        }
      }
    } on FileSystemException {
      // PATH lookup below can still find an app execution alias.
    }
    return 'copilot';
  }

  static Future<String> _refreshedWindowsPath(
    Map<String, String> environment,
  ) async {
    final paths = <String>[
      if ((environment['PATH'] ?? '').trim().isNotEmpty) environment['PATH']!,
    ];
    for (final key in const [
      r'HKCU\Environment',
      r'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment',
    ]) {
      try {
        final result = await Process.run('reg.exe', [
          'query',
          key,
          '/v',
          'Path',
        ]);
        if (result.exitCode != 0) continue;
        final value = _registryPathValue(result.stdout.toString());
        if (value.isNotEmpty) paths.add(value);
      } on ProcessException {
        break;
      }
    }
    return paths
        .expand((path) => path.split(';'))
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty)
        .toSet()
        .join(';');
  }

  static String _registryPathValue(String output) {
    for (final line in const LineSplitter().convert(output)) {
      final match = RegExp(
        r'^\s*Path\s+REG_(?:EXPAND_)?SZ\s+(.*)$',
        caseSensitive: false,
      ).firstMatch(line);
      if (match != null) return match.group(1)?.trim() ?? '';
    }
    return '';
  }

  static String registryPathValueForTest(String output) =>
      _registryPathValue(output);

  static List<String> copilotArguments() => const ['-s', '--no-ask-user'];

  static String buildCopilotPrompt({
    required List<AiAssistantMessage> conversation,
    required String context,
  }) {
    final buffer = StringBuffer()
      ..writeln(
        'You are a PostgreSQL assistant inside a database workbench. '
        'Use only explicitly attached metadata and SQL. Never assume missing '
        'columns. Do not execute commands or access files. Prefer safe '
        'read-only SQL. Put generated SQL in fenced ```sql blocks.',
      );
    if (context.trim().isNotEmpty) {
      buffer
        ..writeln('\nAttached database context:')
        ..writeln(context);
    }
    if (conversation.isNotEmpty) {
      buffer.writeln('\nConversation:');
      for (final message in conversation) {
        buffer
          ..writeln(message.role == 'assistant' ? 'Assistant:' : 'User:')
          ..writeln(message.text);
      }
    }
    return buffer.toString();
  }

  static String copilotError({required int exitCode, required String error}) {
    final lower = error.toLowerCase();
    if (lower.contains('not recognized as an internal or external command') ||
        lower.contains('is not recognized as the name of a cmdlet') ||
        lower.contains('command not found')) {
      return 'GitHub Copilot CLI is not installed or is not on PATH. Install '
          'it with `winget install GitHub.Copilot`, restart QueryDock, and '
          'verify `copilot --version` works. Installing or authenticating the '
          '`gh` CLI does not install the separate Copilot CLI.';
    }
    if (lower.contains('auth') ||
        lower.contains('token') ||
        lower.contains('401')) {
      return 'GitHub Copilot authentication failed. Use a gho_, ghu_, or '
          'github_pat_ token with Copilot Requests permission. Classic ghp_ '
          'tokens are not supported.';
    }
    if (lower.contains('subscription') || lower.contains('entitlement')) {
      return 'This GitHub account does not have an active Copilot entitlement.';
    }
    if (lower.contains('model') && lower.contains('not available')) {
      return 'The selected GitHub Copilot model is not available for this '
          'account. QueryDock now uses the Copilot CLI default model; restart '
          'the updated app and retry.';
    }
    return error.isEmpty
        ? 'GitHub Copilot CLI exited with code $exitCode.'
        : error;
  }

  static String friendlyApiError({
    required int statusCode,
    String? code,
    String? type,
    String? message,
  }) {
    if (statusCode == 429 &&
        (code == 'insufficient_quota' ||
            type == 'insufficient_quota' ||
            message?.toLowerCase().contains('current quota') == true)) {
      return 'OpenAI API billing is not active or has no available credits. '
          'ChatGPT subscriptions and API billing are separate. Open '
          'https://platform.openai.com/settings/organization/billing/overview, '
          'add payment details, and purchase API credits. After adding credits, '
          'allow a few minutes for billing access to update.';
    }
    if (statusCode == 429) {
      return 'OpenAI API rate limit reached. Wait briefly and try again. '
          'If it continues, review your project limits.';
    }
    if (statusCode == 401) {
      return 'The OpenAI API key is invalid, expired, or belongs to a different '
          'project. Create a new project API key and update AI Provider Settings.';
    }
    return message ?? 'OpenAI request failed ($statusCode).';
  }

  static Map<String, Object?> buildRequestBody({
    required AiAssistantSettings settings,
    required List<AiAssistantMessage> conversation,
    required String context,
  }) {
    return {
      'model': settings.model,
      'store': false,
      'max_output_tokens': 2400,
      'instructions':
          'You are a PostgreSQL assistant inside a database workbench. '
          'Use only the explicitly attached metadata and SQL. Never assume '
          'columns that are not provided. Do not claim to execute queries. '
          'Prefer safe read-only SQL. Clearly warn before suggesting writes '
          'or DDL. Put generated SQL in fenced ```sql blocks.',
      'input': [
        if (context.trim().isNotEmpty)
          {
            'role': 'user',
            'content': [
              {
                'type': 'input_text',
                'text': 'Attached database context:\n$context',
              },
            ],
          },
        for (final message in conversation)
          {
            'role': message.role,
            'content': [
              {
                'type': message.role == 'assistant'
                    ? 'output_text'
                    : 'input_text',
                'text': message.text,
              },
            ],
          },
      ],
    };
  }

  static String extractOutputText(Map<String, dynamic> response) {
    final parts = <String>[];
    final output = response['output'];
    if (output is! List) return '';
    for (final item in output) {
      if (item is! Map) continue;
      final content = item['content'];
      if (content is! List) continue;
      for (final part in content) {
        if (part is Map && part['type'] == 'output_text') {
          final text = part['text']?.toString().trim() ?? '';
          if (text.isNotEmpty) parts.add(text);
        }
      }
    }
    return parts.join('\n\n');
  }
}

class AiAssistantException implements Exception {
  final String message;

  const AiAssistantException(this.message);

  @override
  String toString() => message;
}
