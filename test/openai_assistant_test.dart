import 'package:db_viewer/features/ai/services/openai_assistant.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('extracts all output text items from a Responses API payload', () {
    final text = AiAssistantClient.extractOutputText({
      'output': [
        {
          'type': 'message',
          'content': [
            {'type': 'output_text', 'text': 'Explanation'},
            {'type': 'output_text', 'text': '```sql\nSELECT 1;\n```'},
          ],
        },
      ],
    });

    expect(text, contains('Explanation'));
    expect(text, contains('SELECT 1;'));
  });

  test('AI settings require a non-empty API key', () {
    expect(const AiAssistantSettings().configured, isFalse);
    expect(
      const AiAssistantSettings(openAiApiKey: 'sk-test').configured,
      isTrue,
    );
    expect(
      const AiAssistantSettings(
        provider: AiProvider.githubCopilot,
        githubCopilotToken: 'github_pat_test',
      ).configured,
      isTrue,
    );
  });

  test('uses role-appropriate Responses API content types', () {
    final body = AiAssistantClient.buildRequestBody(
      settings: const AiAssistantSettings(openAiApiKey: 'sk-test'),
      context: 'Schema: public',
      conversation: const [
        AiAssistantMessage(role: 'user', text: 'Generate SQL'),
        AiAssistantMessage(role: 'assistant', text: 'Here is the SQL'),
        AiAssistantMessage(role: 'user', text: 'Add a filter'),
      ],
    );

    final input = body['input']! as List<Object?>;
    expect(_contentType(input[0]), 'input_text');
    expect(_contentType(input[1]), 'input_text');
    expect(_contentType(input[2]), 'output_text');
    expect(_contentType(input[3]), 'input_text');
  });

  test('builds a read-only Copilot prompt with attached context', () {
    final prompt = AiAssistantClient.buildCopilotPrompt(
      context: 'Table: public.users',
      conversation: const [
        AiAssistantMessage(role: 'user', text: 'Find duplicates'),
      ],
    );

    expect(prompt, contains('Do not execute commands or access files'));
    expect(prompt, contains('public.users'));
    expect(prompt, contains('Find duplicates'));
  });

  test('AI prompts use the selected database engine', () {
    final prompt = AiAssistantClient.buildCopilotPrompt(
      databaseEngine: 'MySQL',
      context: 'MySQL database: app',
      conversation: const [],
    );
    final body = AiAssistantClient.buildRequestBody(
      settings: const AiAssistantSettings(openAiApiKey: 'sk-test'),
      databaseEngine: 'MySQL',
      context: 'MySQL database: app',
      conversation: const [],
    );

    expect(prompt, contains('MySQL database assistant'));
    expect(prompt, isNot(contains('PostgreSQL assistant')));
    expect(body['instructions'], contains('MySQL database assistant'));
  });

  test('lets Copilot CLI choose an available model', () {
    final arguments = AiAssistantClient.copilotArguments();

    expect(arguments, ['-s', '--no-ask-user']);
    expect(arguments, isNot(contains('--model')));
  });

  test('explains unsupported classic Copilot tokens', () {
    final message = AiAssistantClient.copilotError(
      exitCode: 1,
      error: 'authentication token rejected',
    );

    expect(message, contains('github_pat_'));
    expect(message, contains('ghp_ tokens are not supported'));
  });

  test('explains that GitHub CLI does not install Copilot CLI', () {
    final message = AiAssistantClient.copilotError(
      exitCode: 1,
      error: "'copilot' is not recognized as an internal or external command",
    );

    expect(message, contains('winget install GitHub.Copilot'));
    expect(message, contains('`gh` CLI does not install'));
  });

  test('extracts PATH values from Windows registry output', () {
    final value = AiAssistantClient.registryPathValueForTest(
      '    Path    REG_EXPAND_SZ    C:\\Tools;%LOCALAPPDATA%\\Apps\r\n',
    );

    expect(value, r'C:\Tools;%LOCALAPPDATA%\Apps');
  });

  test('explains insufficient API quota as a billing setup issue', () {
    final message = AiAssistantClient.friendlyApiError(
      statusCode: 429,
      code: 'insufficient_quota',
      type: 'insufficient_quota',
      message: 'You exceeded your current quota.',
    );

    expect(
      message,
      contains('ChatGPT subscriptions and API billing are separate'),
    );
    expect(message, contains('purchase API credits'));
    expect(message, contains('platform.openai.com'));
  });
}

String _contentType(Object? item) {
  final message = item! as Map<String, Object?>;
  final content = message['content']! as List<Object?>;
  final part = content.single! as Map<String, Object?>;
  return part['type']! as String;
}
