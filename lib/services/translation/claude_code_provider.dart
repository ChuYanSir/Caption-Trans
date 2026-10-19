import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'translation_prompt.dart';
import 'translation_provider.dart';

/// Value used in the model dropdown to mean "whatever the CLI is
/// configured with".
const String kClaudeCodeDefaultModel = '(default)';

/// Model aliases offered in the app's model dropdown. Claude Code resolves
/// them itself; [kClaudeCodeDefaultModel] means "do not pass --model".
const List<String> kClaudeCodeModels = <String>[
  kClaudeCodeDefaultModel,
  'sonnet',
  'opus',
  'haiku',
];

/// Translation provider that shells out to a locally installed Claude Code
/// CLI instead of calling an HTTP API.
///
/// The prompt is written to the CLI's stdin and the answer is read from
/// stdout, so no API key is required and long batches never hit the command
/// line length limit.
class ClaudeCodeProvider implements TranslationProvider {
  ClaudeCodeProvider({String? command, this.model})
    : command = (command == null || command.trim().isEmpty)
          ? 'claude'
          : command.trim();

  /// Executable name or absolute path of the Claude Code CLI.
  final String command;

  /// Optional model alias passed through as `--model`.
  final String? model;

  @override
  String get name => 'Claude Code (local CLI)';

  @override
  Future<List<String>> translateBatch({
    required List<String> texts,
    required String sourceLanguage,
    required String targetLanguage,
    String? model,
    List<String> contextBefore = const [],
    List<String> contextAfter = const [],
    Map<String, String> glossary = const {},
    void Function(int completed, int total)? onProgress,
    Future<void>? abortTrigger,
  }) async {
    final prompt = buildTranslationPrompt(
      texts: texts,
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage,
      contextBefore: contextBefore,
      contextAfter: contextAfter,
      glossary: glossary,
    );

    onProgress?.call(0, texts.length);
    final output = await _runClaude(prompt, abortTrigger: abortTrigger);
    onProgress?.call(texts.length, texts.length);

    return parseTranslationResponse(output, texts.length);
  }

  @override
  Future<String> buildContextSummary({
    required List<String> allTexts,
    required String sourceLanguage,
    required String targetLanguage,
    String? model,
    Future<void>? abortTrigger,
  }) async {
    final sampleTexts = sampleTextsForContext(allTexts);
    if (sampleTexts.isEmpty) {
      return '';
    }

    final prompt = buildContextSummaryPrompt(
      sampleTexts: sampleTexts,
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage,
    );
    return _runClaude(prompt, abortTrigger: abortTrigger);
  }

  /// The CLI authenticates itself, so there is no key to validate. Calling
  /// it without a key must still succeed, otherwise translation would abort
  /// before the first batch.
  @override
  Future<bool> validateApiKey(
    String apiKey, {
    String? model,
    String? baseUrl,
  }) async {
    try {
      final result = await _run(
        const <String>['--version'],
        commandOverride: baseUrl,
        timeout: const Duration(seconds: 30),
      );
      return result.stdout.trim().isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Claude Code resolves model aliases itself; the list below only feeds the
  /// app's model dropdown.
  @override
  Future<List<String>> listModels(String apiKey, {String? baseUrl}) async {
    return kClaudeCodeModels;
  }

  @override
  void dispose() {}

  Future<String> _runClaude(
    String prompt, {
    Future<void>? abortTrigger,
  }) async {
    final args = <String>['-p'];
    final selectedModel = model?.trim();
    if (selectedModel != null &&
        selectedModel.isNotEmpty &&
        selectedModel != kClaudeCodeDefaultModel) {
      args.addAll(<String>['--model', selectedModel]);
    }

    final result = await _run(
      args,
      stdinPayload: prompt,
      abortTrigger: abortTrigger,
    );

    final output = result.stdout.trim();
    if (output.isEmpty) {
      final detail = result.stderr.trim();
      throw Exception(
        'Claude Code returned no output'
        '${detail.isEmpty ? '' : ': $detail'}',
      );
    }
    return output;
  }

  Future<_CliResult> _run(
    List<String> args, {
    String? stdinPayload,
    String? commandOverride,
    Future<void>? abortTrigger,
    Duration? timeout,
  }) async {
    final executable = (commandOverride != null &&
            commandOverride.trim().isNotEmpty)
        ? commandOverride.trim()
        : command;

    final Process process;
    try {
      process = await Process.start(
        executable,
        args,
        // Resolve .cmd/.bat shims on Windows.
        runInShell: true,
        // Neutral working directory: Claude Code reads project instructions
        // (CLAUDE.md) from the current directory, which we do not want here.
        workingDirectory: Directory.systemTemp.path,
      );
    } on ProcessException catch (error) {
      throw Exception('Failed to launch "$executable": ${error.message}');
    }

    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();

    if (stdinPayload != null && stdinPayload.isNotEmpty) {
      process.stdin.write(stdinPayload);
    }
    await process.stdin.flush();
    await process.stdin.close();

    var aborted = false;
    if (abortTrigger != null) {
      unawaited(
        abortTrigger.then((_) {
          aborted = true;
          process.kill(ProcessSignal.sigkill);
        }),
      );
    }

    int? exitCode;
    final exitFuture = process.exitCode.then((code) {
      exitCode = code;
      return code;
    });
    final effectiveTimeout = timeout;
    if (effectiveTimeout == null) {
      await exitFuture;
    } else {
      try {
        await exitFuture.timeout(effectiveTimeout);
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await exitFuture;
        throw Exception('Claude Code timed out after ${effectiveTimeout.inSeconds}s');
      }
    }

    final stdout = await stdoutFuture;
    final stderr = await stderrFuture;

    if (aborted) {
      throw const TranslationAbortedException();
    }

    return _CliResult(
      stdout: stdout,
      stderr: stderr,
      exitCode: exitCode ?? -1,
    );
  }
}

class _CliResult {
  const _CliResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
  });

  final String stdout;
  final String stderr;
  final int exitCode;
}
