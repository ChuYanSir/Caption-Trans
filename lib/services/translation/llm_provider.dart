import 'dart:convert';

import 'package:http/http.dart' as http;

import 'translation_prompt.dart';
import 'translation_provider.dart';

/// LLM implementation of [TranslationProvider] using the standard OpenAI API.
class LlmProvider implements TranslationProvider {
  static const _defaultBaseUrl = 'https://api.openai.com/v1';
  static const _defaultModel = 'gpt-4o';

  final String providerId;
  final http.Client Function() _clientFactory;

  String? _apiKey;
  String? _baseUrl;
  http.Client? _httpClient;

  LlmProvider({required this.providerId, http.Client Function()? clientFactory})
    : _clientFactory = clientFactory ?? http.Client.new;

  @override
  String get name => providerId;

  void _ensureClient(String apiKey, String? baseUrl) {
    if (_apiKey != apiKey || _baseUrl != baseUrl || _httpClient == null) {
      _apiKey = apiKey;
      _baseUrl = baseUrl;
      _httpClient?.close();
      _httpClient = _clientFactory();
    }
  }

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
    if (_apiKey == null) {
      throw StateError('API key not configured. Call validateApiKey first.');
    }

    final prompt = buildTranslationPrompt(
      texts: texts,
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage,
      contextBefore: contextBefore,
      contextAfter: contextAfter,
      glossary: glossary,
    );

    onProgress?.call(0, texts.length);

    final response = await _createChatCompletion(
      apiKey: _apiKey!,
      baseUrl: _baseUrl,
      model: model ?? _defaultModel,
      prompt: prompt,
      abortTrigger: abortTrigger,
    );

    onProgress?.call(texts.length, texts.length);

    return parseTranslationResponse(
      response.text ?? '',
      texts.length,
      response.finishReason,
    );
  }

  @override
  Future<String> buildContextSummary({
    required List<String> allTexts,
    required String sourceLanguage,
    required String targetLanguage,
    String? model,
    Future<void>? abortTrigger,
  }) async {
    if (_apiKey == null) {
      throw StateError('API key not configured. Call validateApiKey first.');
    }
    if (allTexts.isEmpty) return '';

    final sampleTexts = sampleTextsForContext(allTexts);
    if (sampleTexts.isEmpty) return '';

    final prompt = buildContextSummaryPrompt(
      sampleTexts: sampleTexts,
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage,
    );

    final response = await _createChatCompletion(
      apiKey: _apiKey!,
      baseUrl: _baseUrl,
      model: model ?? _defaultModel,
      prompt: prompt,
      abortTrigger: abortTrigger,
    );
    return response.text ?? '';
  }

  @override
  Future<bool> validateApiKey(
    String apiKey, {
    String? model,
    String? baseUrl,
  }) async {
    try {
      final response = await _createChatCompletion(
        apiKey: apiKey,
        baseUrl: baseUrl,
        model: model ?? _defaultModel,
        prompt: 'Reply with a single word: OK',
      );
      final text = response.text ?? '';
      return text.toLowerCase().contains('ok');
    } catch (e) {
      return false;
    }
  }

  @override
  Future<List<String>> listModels(String apiKey, {String? baseUrl}) async {
    try {
      final response = await _sendJson(
        apiKey: apiKey,
        baseUrl: baseUrl,
        method: 'GET',
        path: '/models',
      );

      final data = response['data'];
      final models = <String>[];
      if (data is List) {
        for (final item in data) {
          if (item is Map<String, dynamic>) {
            final id = item['id'];
            if (id is String && id.isNotEmpty) {
              models.add(id);
            }
          }
        }
      }

      models.sort((a, b) {
        if (a.contains('flash') && !b.contains('flash')) return -1;
        if (!a.contains('flash') && b.contains('flash')) return 1;
        return a.compareTo(b);
      });

      return models;
    } catch (e) {
      return ['Get models failed. Please check your API key and baseURL.'];
    }
  }

  @override
  void dispose() {
    _httpClient?.close();
    _httpClient = null;
    _apiKey = null;
    _baseUrl = null;
  }

  Future<_ChatCompletionResult> _createChatCompletion({
    required String apiKey,
    required String? baseUrl,
    required String model,
    required String prompt,
    Future<void>? abortTrigger,
  }) async {
    final response = await _sendJson(
      apiKey: apiKey,
      baseUrl: baseUrl,
      method: 'POST',
      path: '/chat/completions',
      abortTrigger: abortTrigger,
      body: {
        'model': model,
        'messages': [
          {'role': 'user', 'content': prompt},
        ],
      },
    );

    return _ChatCompletionResult.fromJson(response);
  }

  Future<Map<String, dynamic>> _sendJson({
    required String apiKey,
    required String? baseUrl,
    required String method,
    required String path,
    Future<void>? abortTrigger,
    Map<String, dynamic>? body,
  }) async {
    _ensureClient(apiKey, baseUrl);

    final request = http.AbortableRequest(
      method,
      _buildUri(baseUrl, path),
      abortTrigger: abortTrigger,
    );
    request.headers.addAll({
      'Authorization': 'Bearer $apiKey',
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    });
    if (body != null) {
      request.body = jsonEncode(body);
    }

    try {
      final streamedResponse = await _httpClient!.send(request);
      final response = await http.Response.fromStream(streamedResponse);
      return _decodeJsonResponse(response);
    } on http.RequestAbortedException {
      throw const TranslationAbortedException();
    }
  }

  Uri _buildUri(String? baseUrl, String path) {
    final rawBaseUrl = (baseUrl != null && baseUrl.trim().isNotEmpty)
        ? baseUrl.trim()
        : _defaultBaseUrl;
    final baseUri = Uri.parse(rawBaseUrl);

    if (!baseUri.hasScheme || baseUri.host.isEmpty) {
      throw FormatException('Invalid base URL: $rawBaseUrl');
    }

    final basePath = baseUri.path.endsWith('/')
        ? baseUri.path.substring(0, baseUri.path.length - 1)
        : baseUri.path;
    final normalizedPath = path.startsWith('/') ? path : '/$path';

    return baseUri.replace(path: '$basePath$normalizedPath');
  }

  Map<String, dynamic> _decodeJsonResponse(http.Response response) {
    final responseBody = utf8.decode(response.bodyBytes);
    Object? decoded;
    if (responseBody.isNotEmpty) {
      try {
        decoded = jsonDecode(responseBody);
      } on FormatException {
        if (response.statusCode < 200 || response.statusCode >= 300) {
          final errorMessage = responseBody.trim().isEmpty
              ? 'Unknown error'
              : responseBody.trim();
          throw Exception(
            'OpenAI API request failed (${response.statusCode}): $errorMessage',
          );
        }
        throw const FormatException('Expected a JSON object response.');
      }
    }
    final json = decoded is Map<String, dynamic> ? decoded : null;

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final errorMessage = _extractErrorMessage(json, responseBody);
      throw Exception(
        'OpenAI API request failed (${response.statusCode}): $errorMessage',
      );
    }

    if (json == null) {
      throw const FormatException('Expected a JSON object response.');
    }

    return json;
  }

  String _extractErrorMessage(Map<String, dynamic>? json, String responseBody) {
    if (json case {'error': final error}) {
      if (error is Map<String, dynamic>) {
        final message = error['message'];
        if (message is String && message.isNotEmpty) {
          return message;
        }
      }
    }

    final trimmedBody = responseBody.trim();
    if (trimmedBody.isNotEmpty) {
      return trimmedBody;
    }

    return 'Unknown error';
  }

}

class _ChatCompletionResult {
  final String? text;
  final String? finishReason;

  const _ChatCompletionResult({this.text, this.finishReason});

  factory _ChatCompletionResult.fromJson(Map<String, dynamic> json) {
    final choices = json['choices'];
    if (choices is! List || choices.isEmpty) {
      return const _ChatCompletionResult();
    }

    final firstChoice = choices.first;
    if (firstChoice is! Map<String, dynamic>) {
      return const _ChatCompletionResult();
    }

    final message = firstChoice['message'];
    final content = message is Map<String, dynamic> ? message['content'] : null;

    return _ChatCompletionResult(
      text: _extractTextContent(content),
      finishReason: firstChoice['finish_reason'] as String?,
    );
  }

  static String? _extractTextContent(Object? content) {
    if (content is String) {
      return content;
    }
    if (content is! List) {
      return null;
    }

    final parts = <String>[];
    for (final item in content) {
      if (item is Map<String, dynamic> && item['type'] == 'text') {
        final text = item['text'];
        if (text is String && text.isNotEmpty) {
          parts.add(text);
        }
      }
    }

    if (parts.isEmpty) {
      return null;
    }

    return parts.join('\n');
  }
}
