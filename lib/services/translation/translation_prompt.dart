import 'translation_failure.dart';

/// Shared prompt construction and response parsing for translation providers.
///
/// HTTP providers and the local Claude Code CLI provider must give the model
/// exactly the same instructions and parse the answer identically, so the
/// prompt/parse logic lives here instead of in a single provider.

/// Builds the batch translation prompt.
String buildTranslationPrompt({
  required List<String> texts,
  required String sourceLanguage,
  required String targetLanguage,
  List<String> contextBefore = const [],
  List<String> contextAfter = const [],
  Map<String, String> glossary = const {},
}) {
  final buffer = StringBuffer();
  buffer.writeln('You are a professional subtitle translator.');
  buffer.writeln(
    'Translate the following subtitle lines from $sourceLanguage to $targetLanguage.',
  );
  buffer.writeln();
  buffer.writeln('RULES:');
  buffer.writeln('1. Keep translations natural and conversational');
  buffer.writeln('2. Maintain consistent terminology throughout');
  buffer.writeln('3. Return EXACTLY ${texts.length} translated lines');
  buffer.writeln(
    '4. Each translated line should correspond to the same numbered input line',
  );
  buffer.writeln(
    '5. Output ONLY the translations, one per line, numbered like: 1. translated text',
  );
  buffer.writeln(
    '6. Do NOT translate proper nouns unless there is a widely used translation',
  );
  buffer.writeln();

  if (glossary.isNotEmpty) {
    buffer.writeln('GLOSSARY (use these translations consistently):');
    glossary.forEach((source, target) {
      buffer.writeln('  "$source" -> "$target"');
    });
    buffer.writeln();
  }

  if (contextBefore.isNotEmpty) {
    buffer.writeln(
      'PRECEDING CONTEXT (already translated, for reference only):',
    );
    for (final line in contextBefore) {
      buffer.writeln('  - $line');
    }
    buffer.writeln();
  }

  buffer.writeln('LINES TO TRANSLATE:');
  for (var i = 0; i < texts.length; i++) {
    buffer.writeln('${i + 1}. ${texts[i]}');
  }

  if (contextAfter.isNotEmpty) {
    buffer.writeln();
    buffer.writeln(
      'FOLLOWING CONTEXT (for reference only, do NOT translate):',
    );
    for (final line in contextAfter) {
      buffer.writeln('  - $line');
    }
  }

  return buffer.toString();
}

/// Picks at most [maxSamples] evenly spaced lines for the context summary.
List<String> sampleTextsForContext(
  List<String> allTexts, {
  int maxSamples = 50,
}) {
  if (allTexts.isEmpty) {
    return const <String>[];
  }

  final sampleSize = allTexts.length > maxSamples
      ? maxSamples
      : allTexts.length;
  final step = allTexts.length ~/ sampleSize;
  if (step == 0) {
    return const <String>[];
  }

  final sample = <String>[];
  for (
    var i = 0;
    i < allTexts.length && sample.length < sampleSize;
    i += step
  ) {
    sample.add(allTexts[i]);
  }
  return sample;
}

/// Builds the transcript analysis prompt used to establish global context.
String buildContextSummaryPrompt({
  required List<String> sampleTexts,
  required String sourceLanguage,
  required String targetLanguage,
}) {
  final numbered = sampleTexts
      .asMap()
      .entries
      .map((e) => '${e.key + 1}. ${e.value}')
      .join('\n');

  return '''
You are analyzing a video transcript for translation preparation.

Source language: $sourceLanguage
Target language: $targetLanguage

Here is a sample of the transcript:
$numbered

Please provide:
1. A brief summary of the content topic
2. Key terms and proper nouns that should be translated consistently
3. The overall tone (formal/informal/technical)

Keep your response concise (under 200 words).
''';
}

/// Parses a numbered-line translation response into exactly
/// [expectedCount] entries, filling gaps with error placeholders.
List<String> parseTranslationResponse(
  String response,
  int expectedCount, [
  String? finishReason,
]) {
  if (response.isEmpty) {
    if (finishReason != null && finishReason.isNotEmpty) {
      return List.filled(expectedCount, buildTranslationError(finishReason));
    }
    return List.filled(
      expectedCount,
      buildTranslationError(
        'The output may contain sensitive terms. Please try switching to a different model. 翻译错误，可能包含敏感词，请尝试更换模型',
      ),
    );
  }

  final lines = response
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();

  final results = <String>[];
  for (final line in lines) {
    final match = RegExp(r'^\d+[.:]\s*(.+)$').firstMatch(line);
    if (match != null) {
      results.add(match.group(1)!.trim());
    }
  }

  if (results.length != expectedCount && lines.length == expectedCount) {
    return lines;
  }

  while (results.length < expectedCount) {
    results.add(buildTranslationError('Incomplete response'));
  }

  return results.length > expectedCount
      ? results.sublist(0, expectedCount)
      : results;
}
