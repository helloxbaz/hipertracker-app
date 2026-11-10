import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'app_theme.dart';
import 'preferences.dart';
import 'voice_guide.dart';

/// More > Navigation voice: pick the voice that speaks trip directions, hear it, and set how fast it talks.
class VoiceScreen extends StatefulWidget {
  const VoiceScreen({super.key});

  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends State<VoiceScreen> {
  final _tts = FlutterTts();
  List<TtsVoice>? _voices;
  String? _chosen;
  double _rate = VoiceGuide.rate;
  bool _on = true;

  @override
  void initState() {
    super.initState();
    try {
      _chosen = Preferences.instance.getString(Preferences.tripVoiceName);
      _on = Preferences.instance.getBool(Preferences.tripVoice) ?? true;
    } catch (_) {}
    _loadVoices();
  }

  @override
  void dispose() {
    _tts.stop();
    super.dispose();
  }

  Future<void> _loadVoices() async {
    final all = await VoiceGuide.voices(_tts);
    if (!mounted) return;
    setState(() {
      _voices = all;
      // nothing chosen yet: show the one the trip screen would use
      _chosen ??= (all.where((v) => !v.online).firstOrNull ?? all.firstOrNull)?.name;
    });
  }

  Future<void> _pick(TtsVoice v) async {
    await VoiceGuide.choose(v);
    setState(() => _chosen = v.name);
    await VoiceGuide.preview(_tts, voice: v);
  }

  Future<void> _setRate(double r) async {
    await VoiceGuide.setRate(r);
    setState(() => _rate = r);
    final v = _voices?.where((x) => x.name == _chosen).firstOrNull;
    await VoiceGuide.preview(_tts, voice: v);
  }

  @override
  Widget build(BuildContext context) {
    final voices = _voices;
    final groups = <String, List<TtsVoice>>{};
    for (final v in voices ?? const <TtsVoice>[]) {
      groups.putIfAbsent(v.accent, () => []).add(v);
    }
    final rateName = VoiceGuide.rates.entries
        .reduce((a, b) => (a.value - _rate).abs() <= (b.value - _rate).abs() ? a : b)
        .key;
    return Scaffold(
      appBar: AppBar(title: const Text('Navigation voice')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        HsPanel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Speak directions', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text('Turn-by-turn voice during trips'),
              value: _on,
              onChanged: (v) {
                Preferences.instance.setBool(Preferences.tripVoice, v);
                setState(() => _on = v);
              },
            ),
            const SizedBox(height: 4),
            const Text('Speed', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: [for (final k in VoiceGuide.rates.keys) ButtonSegment(value: k, label: Text(k))],
              selected: {rateName},
              onSelectionChanged: (s) => _setRate(VoiceGuide.rates[s.first]!),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => VoiceGuide.preview(_tts, voice: voices?.where((x) => x.name == _chosen).firstOrNull),
              icon: const Icon(Icons.play_arrow),
              label: const Text('Play sample'),
            ),
          ]),
        ),
        const SizedBox(height: 16),
        if (voices == null)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
        else if (voices.isEmpty)
          const Text('No English voices found on this phone. Install "Speech Services by Google" from the Play Store, '
              'then come back here.')
        else
          for (final g in groups.entries) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
              child: Text(g.key,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: HsColors.navy)),
            ),
            HsPanel(
              padding: EdgeInsets.zero,
              child: Column(children: [
                for (var i = 0; i < g.value.length; i++)
                  ListTile(
                    leading: Icon(
                      g.value[i].name == _chosen ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                      color: g.value[i].name == _chosen ? HsColors.blue : HsColors.textSecondary,
                    ),
                    title: Text('Voice ${i + 1}', style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text([
                      if (g.value[i].quality >= 400) 'Natural',
                      g.value[i].online ? 'Online (uses mobile data)' : 'Works offline',
                    ].join(' · ')),
                    trailing: IconButton(
                      tooltip: 'Listen',
                      icon: const Icon(Icons.volume_up_outlined),
                      onPressed: () => VoiceGuide.preview(_tts, voice: g.value[i]),
                    ),
                    onTap: () => _pick(g.value[i]),
                  ),
              ]),
            ),
          ],
        const SizedBox(height: 16),
        const Text(
          'Tip: for more natural voices, open phone Settings > Text-to-speech > Speech Services by Google > '
          'Install voice data > English (India), and download the voices you like.',
          style: TextStyle(color: HsColors.textSecondary, fontSize: 13),
        ),
      ]),
    );
  }
}
