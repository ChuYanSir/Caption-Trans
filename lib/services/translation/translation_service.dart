import 'dart:async';
import '../../core/constants.dart';
import '../../models/subtitle_segment.dart';
import '../../models/translation_config.dart';
import 'claude_code_provider.dart';
import 'translation_provider.dart';
import 'translation_failure.dart';
import 'llm_provider.dart';

typedef TranslationProviderFactory =
    TranslationProvider Function(TranslationConfig config);

/// Orchestrates the translation process with context management.
///
/// Handles batch splitting, context window sliding, glossary extraction,
/// and progress reporting.
class TranslationService {
  static final TranslationService _instance = TranslationService._internal();
  final TranslationProviderFactory _providerFactory;

  factory TranslationService({TranslationProviderFactory? providerFactory}) {
    if (providerFactory != null) {
      return TranslationService._withProviderFactory(providerFactory);
    }
    return _instance;
  }

  TranslationService._internal() : _providerFactory = _defaultProviderFactory;

  TranslationService._withProviderFactory(this._providerFactory);

  TranslationProvider? _provider;
  String? _contextSummary;
  Completer<void>? _abortCompleter;
  bool _isCancelled = false;

  /// Get the current context summary (built during translateAll).
  String? get contextSummary => _contextSummary;
  final Map<String, String> _glossary = {};

  TranslationProvider? get currentProvider => _provider;

  static TranslationProvider _defaultProviderFactory(TranslationConfig config) {
    if (config.providerId == AppConstants.claudeCodeCliProvider) {
      return ClaudeCodeProvider(command: config.baseUrl, model: config.model);
    }
    return LlmProvider(providerId: config.providerId);
  }

  void _ensureAbortController() {
    if (_abortCompleter != null && !_abortCompleter!.isCompleted) {
      _abortCompleter!.complete();
    }
    _abortCompleter = Completer<void>();
    _isCancelled = false;
  }

  /// Cancel any ongoing translation.
  void cancel() {
    _isCancelled = true;
    if (_abortCompleter != null && !_abortCompleter!.isCompleted) {
      _abortCompleter!.complete();
    }
    _provider?.dispose();
  }

  /// Initialize or switch the translation provider based on config.
  void configure(TranslationConfig config) {
    _provider?.dispose();
    _provider = _providerFactory(config);
  }

  /// Translate all segments with context-aware batching.
  ///
  /// Returns a new list of [SubtitleSegment] with [translatedText] populated.
  Future<List<SubtitleSegment>> translateAll({
    required List<SubtitleSegment> segments,
    required TranslationConfig config,
    bool retryFailedOnly = false,
    void Function(int completed, int total, List<SubtitleSegment> partials)?
    onProgress,
  }) async {
    if (_provider == null) {
      throw StateError(
        'Translation provider not configured. Call configure() first.',
      );
    }

    _ensureAbortController();

    // Validate API key first
    final isValid = await _provider!.validateApiKey(
      config.apiKey,
      model: config.model,
      baseUrl: config.baseUrl,
    );
    if (!isValid) {
      throw Exception(
        '${_provider!.name} is currently unavailable. Please check your API key and network connection.',
      );
    }

    final allTexts = segments.map((s) => s.text).toList();
    final totalSegments = segments.length;
    final translatedTexts = segments
        .map((s) => s.translatedText ?? '')
        .toList();
    var completedCount = _countSuccessfulTranslations(translatedTexts);

    // Step 1: Build context summary for global understanding
    onProgress?.call(
      completedCount,
      totalSegments,
      _buildSegmentsWithTranslations(segments, translatedTexts),
    );
    if (_isCancelled) {
      throw const TranslationAbortedException();
    }
    try {
      _contextSummary = await _provider!.buildContextSummary(
        allTexts: allTexts,
        sourceLanguage: config.sourceLanguage,
        targetLanguage: config.targetLanguage,
        model: config.model,
        abortTrigger: _abortCompleter?.future,
      );
    } catch (e) {
      if (_isCancelled) {
        throw const TranslationAbortedException();
      }
      rethrow;
    }

    // Step 2: Translate pending or failed segments in batches.
    if (retryFailedOnly) {
      completedCount = await _retryFailedBatches(
        segments: segments,
        config: config,
        allTexts: allTexts,
        translatedTexts: translatedTexts,
        completedCount: completedCount,
        onProgress: onProgress,
      );
    } else {
      completedCount = await _translatePendingBatches(
        segments: segments,
        config: config,
        allTexts: allTexts,
        translatedTexts: translatedTexts,
        completedCount: completedCount,
        onProgress: onProgress,
      );
    }

    // Step 3: Build result segments with translations
    return _buildSegmentsWithTranslations(segments, translatedTexts);
  }

  Future<int> _translatePendingBatches({
    required List<SubtitleSegment> segments,
    required TranslationConfig config,
    required List<String> allTexts,
    required List<String> translatedTexts,
    required int completedCount,
    void Function(int completed, int total, List<SubtitleSegment> partials)?
    onProgress,
  }) async {
    final totalSegments = segments.length;

    for (
      var batchStart = 0;
      batchStart < totalSegments;
      batchStart += config.batchSize
    ) {
      final batchEnd = (batchStart + config.batchSize).clamp(0, totalSegments);
      if (!_batchNeedsTranslation(translatedTexts, batchStart, batchEnd)) {
        continue;
      }

      final batchResults = await _translateBatch(
        texts: allTexts.sublist(batchStart, batchEnd),
        config: config,
        contextBefore: _buildContextBefore(
          translatedTexts: translatedTexts,
          start: (batchStart - config.contextOverlap).clamp(0, totalSegments),
          end: batchStart,
        ),
        contextAfter: batchEnd < totalSegments
            ? allTexts.sublist(
                batchEnd,
                (batchEnd + config.contextOverlap).clamp(0, totalSegments),
              )
            : <String>[],
      );

      completedCount += _applyBatchResults(
        translatedTexts: translatedTexts,
        indices: List<int>.generate(
          batchEnd - batchStart,
          (offset) => batchStart + offset,
        ),
        batchResults: batchResults,
      );

      onProgress?.call(
        completedCount,
        totalSegments,
        _buildSegmentsWithTranslations(segments, translatedTexts),
      );

      if (batchStart == 0) {
        _extractGlossary(allTexts.sublist(batchStart, batchEnd), batchResults);
      }
    }

    return completedCount;
  }

  Future<int> _retryFailedBatches({
    required List<SubtitleSegment> segments,
    required TranslationConfig config,
    required List<String> allTexts,
    required List<String> translatedTexts,
    required int completedCount,
    void Function(int completed, int total, List<SubtitleSegment> partials)?
    onProgress,
  }) async {
    final totalSegments = segments.length;

    for (
      var batchStart = 0;
      batchStart < totalSegments;
      batchStart += config.batchSize
    ) {
      final batchEnd = (batchStart + config.batchSize).clamp(0, totalSegments);
      final failedIndices = <int>[];

      for (var i = batchStart; i < batchEnd; i++) {
        if (isTranslationErrorText(translatedTexts[i])) {
          failedIndices.add(i);
        }
      }

      if (failedIndices.isEmpty) {
        continue;
      }

      final firstFailed = failedIndices.first;
      final lastFailed = failedIndices.last;
      final batchResults = await _translateBatch(
        texts: failedIndices.map((index) => allTexts[index]).toList(),
        config: config,
        contextBefore: _buildContextBefore(
          translatedTexts: translatedTexts,
          start: (firstFailed - config.contextOverlap).clamp(0, totalSegments),
          end: firstFailed,
        ),
        contextAfter: lastFailed + 1 < totalSegments
            ? allTexts.sublist(
                lastFailed + 1,
                (lastFailed + 1 + config.contextOverlap).clamp(
                  0,
                  totalSegments,
                ),
              )
            : <String>[],
      );

      completedCount += _applyBatchResults(
        translatedTexts: translatedTexts,
        indices: failedIndices,
        batchResults: batchResults,
      );

      onProgress?.call(
        completedCount,
        totalSegments,
        _buildSegmentsWithTranslations(segments, translatedTexts),
      );
    }

    return completedCount;
  }

  bool _batchNeedsTranslation(
    List<String> translatedTexts,
    int start,
    int end,
  ) {
    for (var i = start; i < end; i++) {
      if (translatedTexts[i].isEmpty ||
          isTranslationErrorText(translatedTexts[i])) {
        return true;
      }
    }

    return false;
  }

  List<String> _buildContextBefore({
    required List<String> translatedTexts,
    required int start,
    required int end,
  }) {
    if (end <= start) {
      return const <String>[];
    }

    return translatedTexts
        .sublist(start, end)
        .where((text) => text.isNotEmpty && !isTranslationErrorText(text))
        .toList();
  }

  Future<List<String>> _translateBatch({
    required List<String> texts,
    required TranslationConfig config,
    required List<String> contextBefore,
    required List<String> contextAfter,
  }) async {
    if (_isCancelled) {
      throw const TranslationAbortedException();
    }

    try {
      return await _provider!.translateBatch(
        texts: texts,
        sourceLanguage: config.sourceLanguage,
        targetLanguage: config.targetLanguage,
        model: config.model,
        contextBefore: contextBefore,
        contextAfter: contextAfter,
        glossary: _glossary,
        abortTrigger: _abortCompleter?.future,
      );
    } catch (e) {
      if (_isCancelled) {
        throw const TranslationAbortedException();
      }
      rethrow;
    }
  }

  int _applyBatchResults({
    required List<String> translatedTexts,
    required List<int> indices,
    required List<String> batchResults,
  }) {
    var completedDelta = 0;

    for (var i = 0; i < batchResults.length; i++) {
      final index = indices[i];
      final previousText = translatedTexts[index];
      final nextText = batchResults[i];
      final wasSuccessful =
          previousText.isNotEmpty && !isTranslationErrorText(previousText);
      final isSuccessful =
          nextText.isNotEmpty && !isTranslationErrorText(nextText);

      if (!wasSuccessful && isSuccessful) {
        completedDelta++;
      } else if (wasSuccessful && !isSuccessful) {
        completedDelta--;
      }

      translatedTexts[index] = nextText;
    }

    return completedDelta;
  }

  int _countSuccessfulTranslations(List<String> translatedTexts) {
    return translatedTexts
        .where((text) => text.isNotEmpty && !isTranslationErrorText(text))
        .length;
  }

  List<SubtitleSegment> _buildSegmentsWithTranslations(
    List<SubtitleSegment> segments,
    List<String> translatedTexts,
  ) {
    return segments
        .asMap()
        .entries
        .map(
          (entry) => entry.value.copyWith(
            translatedText: translatedTexts[entry.key].isEmpty
                ? null
                : translatedTexts[entry.key],
          ),
        )
        .toList();
  }

  /// Simple glossary extraction from first batch translations.
  void _extractGlossary(
    List<String> sourceTexts,
    List<String> translatedTexts,
  ) {
    // The glossary will be built up over time as we encounter consistent
    // translations. For now, we keep it manual-ready for future enhancement.
    // A more sophisticated implementation could use the LLM to extract
    // key term pairs from the first batch.
    _glossary.clear();
  }

  /// Clear accumulated context and glossary.
  void reset() {
    _contextSummary = null;
    _glossary.clear();
    _abortCompleter = null;
    _isCancelled = false;
  }

  void dispose() {
    _provider?.dispose();
    _provider = null;
    reset();
  }

  /// List available models from the provider.
  Future<List<String>> listModels(TranslationConfig config) async {
    if (_provider == null ||
        (_provider is LlmProvider &&
            (_provider as LlmProvider).providerId != config.providerId)) {
      configure(config);
    }
    return _provider!.listModels(config.apiKey, baseUrl: config.baseUrl);
  }
}
