import 'package:flutter_tts/flutter_tts.dart';

import 'preferences.dart';

/// A text-to-speech voice on the phone.
class TtsVoice {
  final String name;
  final String locale;
  final bool online; // needs mobile data (Google's most natural voices)
  final int quality; // higher is better
  const TtsVoice(this.name, this.locale, this.online, this.quality);

  /// "English (India)" ...
  String get accent {
    final l = locale.toLowerCase().replaceAll('_', '-');
    if (l.endsWith('-in')) return 'English (India)';
    if (l.endsWith('-gb')) return 'English (UK)';
    if (l.endsWith('-us')) return 'English (US)';
    if (l.endsWith('-au')) return 'English (Australia)';
    if (l.endsWith('-ng')) return 'English (Nigeria)';
    return 'English ($locale)';
  }
}

/// Spoken directions for the trip screen, in a clear navigation voice the worker can choose
/// (More > Navigation voice). Uses the phone's own text-to-speech; offline voices work without data.
class VoiceGuide {
  static const sample = 'In 200 metres, turn right onto Bank Road. Then, turn left.';
  static const rates = {'Slow': 0.42, 'Normal': 0.5, 'Fast': 0.58};

  final FlutterTts _tts = FlutterTts();
  bool _ready = false;

  bool _on = true;

  bool get enabled {
    try {
      _on = Preferences.instance.getBool(Preferences.tripVoice) ?? _on;
    } catch (_) {}
    return _on;
  }

  set enabled(bool v) {
    _on = v;
    try {
      Preferences.instance.setBool(Preferences.tripVoice, v);
    } catch (_) {}
    if (!v) _tts.stop();
  }

  static double get rate {
    try {
      return Preferences.instance.getDouble(Preferences.tripVoiceRate) ?? rates['Normal']!;
    } catch (_) {
      return rates['Normal']!;
    }
  }

  static int _quality(dynamic q) {
    final s = '${q ?? ''}'.toLowerCase();
    final n = int.tryParse(s);
    if (n != null) return n;
    if (s.contains('very high')) return 500;
    if (s.contains('high')) return 400;
    if (s.contains('normal')) return 300;
    if (s.contains('low')) return 200;
    return 300;
  }

  /// English voices on this phone, best first (India first, then quality).
  static Future<List<TtsVoice>> voices([FlutterTts? tts]) async {
    final t = tts ?? FlutterTts();
    final out = <TtsVoice>[];
    try {
      final list = await t.getVoices;
      if (list is List) {
        for (final v in list) {
          if (v is! Map) continue;
          final name = '${v['name'] ?? ''}';
          final locale = '${v['locale'] ?? ''}';
          if (name.isEmpty || !locale.toLowerCase().startsWith('en')) continue;
          final features = '${v['features'] ?? ''}'.toLowerCase();
          if (features.contains('notinstalled')) continue;
          final online = '${v['network_required'] ?? ''}' == '1' ||
              '${v['network_required']}' == 'true' ||
              name.toLowerCase().contains('network');
          out.add(TtsVoice(name, locale, online, _quality(v['quality'])));
        }
      }
    } catch (_) {}
    int rank(TtsVoice v) {
      final l = v.locale.toLowerCase();
      return l.endsWith('in') ? 0 : l.endsWith('gb') ? 1 : l.endsWith('us') ? 2 : 3;
    }
    out.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      if (r != 0) return r;
      final q = b.quality.compareTo(a.quality);
      if (q != 0) return q;
      if (a.online != b.online) return a.online ? 1 : -1; // offline first: works without data
      return a.name.compareTo(b.name);
    });
    return out;
  }

  Future<void> init() async {
    try {
      await _apply(_tts);
      await _tts.setVolume(1.0);
      await _tts.awaitSpeakCompletion(false);
      _ready = true;
    } catch (_) {
      _ready = false;
    }
  }

  /// The chosen voice, or the clearest English (India) voice on the phone.
  static Future<void> _apply(FlutterTts tts, {TtsVoice? voice}) async {
    String? name, locale;
    if (voice != null) {
      name = voice.name;
      locale = voice.locale;
    } else {
      try {
        name = Preferences.instance.getString(Preferences.tripVoiceName);
        locale = Preferences.instance.getString(Preferences.tripVoiceLocale);
      } catch (_) {}
    }
    if (name == null || name.isEmpty) {
      final all = await voices(tts);
      final best = all.where((v) => !v.online).firstOrNull ?? all.firstOrNull;
      name = best?.name;
      locale = best?.locale;
    }
    final indian = await tts.isLanguageAvailable('en-IN');
    await tts.setLanguage(locale ?? (indian == true ? 'en-IN' : 'en-US'));
    if (name != null && locale != null) {
      try {
        await tts.setVoice({'name': name, 'locale': locale});
      } catch (_) {}
    }
    await tts.setSpeechRate(rate);
    await tts.setPitch(1.0);
  }

  /// Use [v] from now on (saved on the phone).
  static Future<void> choose(TtsVoice v) async {
    await Preferences.instance.setString(Preferences.tripVoiceName, v.name);
    await Preferences.instance.setString(Preferences.tripVoiceLocale, v.locale);
  }

  static Future<void> setRate(double r) => Preferences.instance.setDouble(Preferences.tripVoiceRate, r);

  /// Speak [text] with [voice] (or the chosen one) once, to try it.
  static Future<void> preview(FlutterTts tts, {TtsVoice? voice, String text = sample}) async {
    try {
      await tts.stop();
      await _apply(tts, voice: voice);
      await tts.speak(speakable(text));
    } catch (_) {}
  }

  Future<void> say(String text) async {
    if (!enabled || !_ready || text.trim().isEmpty) return;
    try {
      await _tts.speak(speakable(text));
    } catch (_) {}
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }

  static final _abbr = <RegExp, String>{
    RegExp(r'\bRd\b'): 'Road',
    RegExp(r'\bSt\b'): 'Street',
    RegExp(r'\bAve\b'): 'Avenue',
    RegExp(r'\bHwy\b'): 'Highway',
    RegExp(r'\bBlvd\b'): 'Boulevard',
    RegExp(r'\bLn\b'): 'Lane',
    RegExp(r'\bJn\b|\bJct\b'): 'Junction',
    RegExp(r'\bNr\b'): 'near',
    RegExp(r'\bNH\s*(\d+)'): r'National Highway $1',
    RegExp(r'\bSH\s*(\d+)'): r'State Highway $1',
    RegExp(r'\bByp\b'): 'Bypass',
  };

  /// How a navigation voice says it: "Bank Rd/PR Nambiar Rd" -> "Bank Road".
  static String speakable(String text) {
    var t = text.replaceAllMapped(RegExp(r'([^\s/]+(?:\s[^\s/]+)*?)\s*/\s*[^,.]+'), (m) => m.group(1)!);
    for (final e in _abbr.entries) {
      t = t.replaceAllMapped(e.key, (m) {
        var r = e.value;
        for (var i = 1; i <= m.groupCount; i++) {
          r = r.replaceAll('\$$i', m.group(i) ?? '');
        }
        return r;
      });
    }
    return t.replaceAll(RegExp(r'\s+'), ' ').trim();
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
