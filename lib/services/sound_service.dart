import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/enums.dart';
import 'hive_service.dart';

/// One selectable chip sound.
///
/// Every option is a real slice of the banker's own recording
/// (`assets/sounds/Chip_sound.wav`), cut at the natural silences between
/// the gestures they performed. Nothing is synthesised —
/// `tool/split_chip_sounds.py` does the detection and cutting, and this
/// list mirrors the manifest it writes.
class ChipSample {
  /// Stable id persisted in settings. Never renumber these — an existing
  /// install stores this string, so changing it would silently reset the
  /// banker's choice.
  final String id;

  /// Asset path as `audioplayers` wants it: relative to `assets/`, which
  /// pubspec already declares. Do NOT prefix with `assets/`.
  final String asset;

  final String title;
  final String description;
  final double duration;

  const ChipSample({
    required this.id,
    required this.asset,
    required this.title,
    required this.description,
    required this.duration,
  });
}

/// Chip variations split out of the supplied master recording, shortest
/// first — the snappy ones are what most bankers want under a tap.
const List<ChipSample> kChipSamples = [
  ChipSample(
    id: 'chip_1',
    asset: 'sounds/chip_1.wav',
    title: 'Single Chip',
    description: 'One clean chip set down',
    duration: 0.27,
  ),
  ChipSample(
    id: 'chip_2',
    asset: 'sounds/chip_2.wav',
    title: 'Chip Drop',
    description: 'A handful of chips dropped',
    duration: 0.36,
  ),
  ChipSample(
    id: 'chip_3',
    asset: 'sounds/chip_3.wav',
    title: 'Chip Drop 2',
    description: 'A crisper handful, brighter tail',
    duration: 0.41,
  ),
  ChipSample(
    id: 'chip_4',
    asset: 'sounds/chip_4.wav',
    title: 'Chip Cascade',
    description: 'A shorter pour, chips settling',
    duration: 0.65,
  ),
  ChipSample(
    id: 'chip_5',
    asset: 'sounds/chip_5.wav',
    title: 'Chip Pour',
    description: 'A long cascade onto the felt',
    duration: 0.83,
  ),
  ChipSample(
    id: 'chip_6',
    asset: 'sounds/chip_6.wav',
    title: 'Chip Pour 2',
    description: 'The fullest pour, longest tail',
    duration: 1.04,
  ),
];

/// Kept so existing call sites stay expressive. Every value plays the
/// banker's one chosen sample.
enum SoundEffect {
  buyIn,
  rebuy,
  cashOut,
  rake,
  addPlayer,
  cashDrop,
}

/// Plays the poker chip sound.
///
/// ALL AUDIO COMES FROM THE BANKER'S OWN RECORDING.
/// `assets/sounds/Chip_sound.wav` is a 41-second take containing several
/// different chip gestures. `tool/split_chip_sounds.py` cuts it at the
/// natural silences into the selectable variations in [kChipSamples].
/// Nothing here is synthesised, and the master ships untouched so the
/// variations can always be re-derived.
///
/// Design rules, in priority order:
///
/// 1. **Audio must never affect the ledger.** Every call is
///    fire-and-forget and fully guarded — a missing asset, a device with
///    no audio route, revoked audio focus, or a platform with no plugin
///    registered can never throw into a transaction path.
/// 2. **Never interrupt the room.** Mixes with other audio and never
///    seizes the audio session.
/// 3. **Fast retrigger.** A small pool of players is rotated so rapid
///    taps overlap naturally instead of cutting each other off.
/// 4. **Respects the setting instantly** — read on every play, so
///    toggling it off silences the very next tap.
class AppSounds {
  AppSounds._();

  /// The banker's full original recording, shipped untouched as the
  /// source the variations were cut from. Not played directly — it is a
  /// 41-second multi-take.
  static const String masterRecording = 'sounds/Chip_sound.wav';

  static const _enabledKey = 'sound_effects_enabled';
  static const _sampleKey = 'chip_sound_sample_id';
  static const _poolSize = 4;

  static final List<AudioPlayer> _pool = [];
  static int _next = 0;
  static bool _initialised = false;
  static bool _unavailable = false;
  static bool _enabled = true;
  static String _sampleId = kChipSamples[1].id; // "Chip Drop" — good default

  /// Whether chip sounds are currently switched on.
  static bool get enabled => _enabled;

  /// The currently selected sample. Falls back to the default if a
  /// stored id no longer exists (e.g. after the sample set is
  /// regenerated), so a stale preference can never silence the app.
  static ChipSample get selectedSample => kChipSamples.firstWhere(
        (s) => s.id == _sampleId,
        orElse: () => kChipSamples[1],
      );

  static String get selectedSampleId => selectedSample.id;

  /// Retained so existing call sites (`AppSounds.forTransaction(type)`)
  /// keep compiling and reading clearly. All values play the same sound.
  static SoundEffect forTransaction(TransactionType type) {
    switch (type) {
      case TransactionType.buyIn:
        return SoundEffect.buyIn;
      case TransactionType.rebuy:
        return SoundEffect.rebuy;
      case TransactionType.cashOut:
        return SoundEffect.cashOut;
      case TransactionType.rakeCollection:
        return SoundEffect.rake;
      case TransactionType.cashDrop:
        return SoundEffect.cashDrop;
    }
  }

  /// Loads the persisted preference. Safe to call before Hive is ready —
  /// it simply falls back to "on".
  static void loadPreference() {
    try {
      _enabled = HiveService.settings.get(_enabledKey, defaultValue: true) as bool;
      final stored = HiveService.settings.get(_sampleKey) as String?;
      if (stored != null && kChipSamples.any((s) => s.id == stored)) {
        _sampleId = stored;
      }
    } catch (_) {
      _enabled = true;
    }
  }

  /// Chooses which chip sound the whole app uses.
  static Future<void> setSample(String sampleId) async {
    if (!kChipSamples.any((s) => s.id == sampleId)) return;
    _sampleId = sampleId;
    try {
      await HiveService.settings.put(_sampleKey, sampleId);
    } catch (_) {
      // Best-effort persistence; the selection still applies this session.
    }
  }

  static Future<void> setEnabled(bool value) async {
    _enabled = value;
    try {
      await HiveService.settings.put(_enabledKey, value);
    } catch (_) {
      // A failed preference write must not break the toggle in the UI.
    }
    if (!value) await stopAll();
  }

  static void _ensureInit() {
    if (_initialised || _unavailable) return;
    try {
      for (var i = 0; i < _poolSize; i++) {
        final p = AudioPlayer()..setReleaseMode(ReleaseMode.stop);
        p.setAudioContext(
          AudioContext(
            android: const AudioContextAndroid(
              isSpeakerphoneOn: false,
              stayAwake: false,
              contentType: AndroidContentType.sonification,
              usageType: AndroidUsageType.assistanceSonification,
              audioFocus: AndroidAudioFocus.none,
            ),
            iOS: AudioContextIOS(
              category: AVAudioSessionCategory.ambient,
              options: const {AVAudioSessionOptions.mixWithOthers},
            ),
          ),
        );
        _pool.add(p);
      }
      _initialised = true;
    } catch (e) {
      // No audio on this platform/device — degrade to silence, forever.
      _unavailable = true;
      debugPrint('AppSounds: audio unavailable, continuing silently ($e)');
    }
  }

  /// Plays the chip sound. Fire-and-forget: never awaited by callers,
  /// never throws, and silent when sounds are switched off.
  ///
  /// [effect] is accepted for call-site readability; all values play the
  /// same recording.
  static void play(SoundEffect effect, {double volume = 1.0}) {
    if (!_enabled) return;
    _playChipAsset(volume: volume);
  }

  /// Plays the chip sound without naming an action.
  static void playChip({double volume = 1.0}) {
    if (!_enabled) return;
    _playChipAsset(volume: volume);
  }

  static void _playChipAsset({double volume = 1.0}) =>
      _playAsset(selectedSample.asset, volume: volume);

  static void _playAsset(String asset, {double volume = 1.0}) {
    _ensureInit();
    if (_unavailable || _pool.isEmpty) return;

    final player = _pool[_next % _pool.length];
    _next++;

    // Deliberately not awaited — the ledger write must not wait on audio.
    () async {
      try {
        await player.stop();
        await player.setVolume(volume.clamp(0.0, 1.0));
        await player.play(AssetSource(asset));
      } catch (e) {
        debugPrint('AppSounds: could not play $asset ($e)');
      }
    }();
  }

  /// A light haptic tick alongside the sound, for when the banker's phone
  /// is face-down on the table or the room is loud.
  static void playWithHaptic(SoundEffect effect) {
    play(effect);
    try {
      HapticFeedback.lightImpact();
    } catch (_) {
      // Haptics are optional garnish; a device without them is fine.
    }
  }

  static Future<void> stopAll() async {
    for (final p in _pool) {
      try {
        await p.stop();
      } catch (_) {
        // Already stopped / disposed — nothing to do.
      }
    }
  }

  /// Auditions a specific sample from Settings, ignoring the on/off
  /// preference so the banker can always hear what they are choosing.
  static void previewSample(ChipSample sample) {
    final wasEnabled = _enabled;
    _enabled = true;
    _playAsset(sample.asset);
    _enabled = wasEnabled;
  }

  /// Previews whichever sample is currently selected.
  static void preview([SoundEffect? effect]) => previewSample(selectedSample);
}
