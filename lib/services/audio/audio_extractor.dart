import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/app_paths.dart';

/// Service for extracting audio from video files.
///
/// Uses system/bundled ffmpeg to produce 16kHz mono WAV.
class AudioExtractor {
  /// Extract audio from a video file and convert to 16kHz mono WAV.
  ///
  /// Returns the path to the extracted WAV file.
  Future<String> extractAudio(String videoPath) async {
    final tempDir = await AppPaths.temp();
    final outputFileName = '${p.basenameWithoutExtension(videoPath)}_audio.wav';
    final outputPath = p.join(tempDir.path, 'caption_trans', outputFileName);

    // Ensure output directory exists
    await Directory(p.dirname(outputPath)).create(recursive: true);

    // Delete existing file if present
    final outputFile = File(outputPath);
    if (await outputFile.exists()) {
      await outputFile.delete();
    }

    if (Platform.isMacOS) {
      await _extractWithProcess(videoPath, outputPath);
    } else if (Platform.isWindows) {
      await _extractWithBundledFfmpeg(videoPath, outputPath);
    } else {
      throw UnsupportedError(
        'Unsupported platform: ${Platform.operatingSystem}',
      );
    }

    // Verify output file was created
    if (!await File(outputPath).exists()) {
      throw Exception('Audio extraction failed: output file not created');
    }

    return outputPath;
  }

  /// Extract using system ffmpeg (macOS).
  Future<void> _extractWithProcess(String videoPath, String outputPath) async {
    final result = await Process.run('ffmpeg', [
      '-i',
      videoPath,
      '-vn',
      '-acodec',
      'pcm_s16le',
      '-ar',
      '16000',
      '-ac',
      '1',
      '-y',
      outputPath,
    ]);

    if (result.exitCode != 0) {
      throw Exception(
        'FFmpeg failed (exit code ${result.exitCode}): ${result.stderr}',
      );
    }
  }

  /// Extract using bundled ffmpeg.exe on Windows.
  Future<void> _extractWithBundledFfmpeg(
    String videoPath,
    String outputPath,
  ) async {
    // Look for bundled ffmpeg in app directory
    final ffmpegPath = await _findBundledFfmpeg();

    final result = await Process.run(ffmpegPath, [
      '-i',
      videoPath,
      '-vn',
      '-acodec',
      'pcm_s16le',
      '-ar',
      '16000',
      '-ac',
      '1',
      '-y',
      outputPath,
    ]);

    if (result.exitCode != 0) {
      throw Exception(
        'FFmpeg failed (exit code ${result.exitCode}): ${result.stderr}',
      );
    }
  }

  /// Find the bundled ffmpeg executable.
  Future<String> _findBundledFfmpeg() async {
    if (Platform.isWindows) {
      // Check alongside the executable
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final candidates = [
        p.join(exeDir, 'ffmpeg.exe'),
        p.join(exeDir, 'bundled', 'ffmpeg.exe'),
        p.join(exeDir, 'data', 'flutter_assets', 'assets', 'ffmpeg.exe'),
      ];

      for (final candidate in candidates) {
        if (await File(candidate).exists()) {
          return candidate;
        }
      }

      // Fallback to system PATH
      return 'ffmpeg';
    }

    // macOS/Linux fallback
    return 'ffmpeg';
  }

  /// Clean up temporary audio files.
  Future<void> cleanup() async {
    try {
      final tempDir = await AppPaths.temp();
      final audioDir = Directory(p.join(tempDir.path, 'caption_trans'));
      if (await audioDir.exists()) {
        await audioDir.delete(recursive: true);
      }
    } catch (_) {
      // Ignore cleanup errors
    }
  }
}
