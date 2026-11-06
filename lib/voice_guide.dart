import 'package:flutter_tts/flutter_tts.dart';

import 'preferences.dart';

/// Spoken directions for the trip screen (the phone's own text-to-speech; works offline once the voice is installed).
class VoiceGuide {
  static const _prefKey = 'trip_voice';
  final FlutterTts _tts = FlutterTts();
  bool _ready = false;

  bool get enabled => Preferences.instance.getBool(_prefKey) ?? true;
  set enabled(bool v) {
    Preferences.instance.setBool(_prefKey, v);
    if (!v) _tts.stop();
  }

  Future<void> init() async {
    try {
      final indian = await _tts.isLanguageAvailable('en-IN');
      await _tts.setLanguage(indian == true ? 'en-IN' : 'en-US');
      await _tts.setSpeechRate(0.48);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
      await _tts.awaitSpeakCompletion(false);
      _ready = true;
    } catch (_) {
      _ready = false;
    }
  }

  Future<void> say(String text) async {
    if (!enabled || !_ready || text.trim().isEmpty) return;
    try {
      await _tts.speak(text);
    } catch (_) {}
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }

  /// "300 metres", "1.2 kilometres" for speaking.
  static String distance(double m) {
    if (m >= 1000) {
      final km = m / 1000;
      return '${km >= 10 ? km.round() : km.toStringAsFixed(1)} kilometres';
    }
    final r = m >= 100 ? (m / 50).round() * 50 : (m / 10).round() * 10;
    return '$r metres';
  }
}
