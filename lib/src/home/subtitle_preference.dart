import 'package:segmeris/src/rust/api/downloader.dart';

/// The subtitle decision the user made on the candidates card.
///
/// It is deliberately *not* one of the engine's `SubtitleMode` values: a
/// pick has to answer two different questions — "which track for this one
/// download" and "which language for every episode of a series" — and the
/// [translate] helpers below are the only place that knows how the two map
/// onto the engine contract.
sealed class SubtitlePreference {
  const SubtitlePreference();
}

/// Keep whatever the episode itself declares as its default track.
final class SubtitleAutoPreference extends SubtitlePreference {
  const SubtitleAutoPreference();
}

/// Save no subtitle file at all.
final class SubtitleOffPreference extends SubtitlePreference {
  const SubtitleOffPreference();
}

/// Prefer one concrete track the inspection listed.
final class SubtitleTrackPreference extends SubtitlePreference {
  const SubtitleTrackPreference(this.track);

  final MediaSubtitleTrack track;

  @override
  bool operator ==(Object other) =>
      other is SubtitleTrackPreference &&
      other.track.language == track.language &&
      other.track.url == track.url;

  @override
  int get hashCode => Object.hash(track.language, track.url);
}

/// Map this preference onto the engine contract for a single download:
/// the exact track URL is valid here, because the download is the episode
/// the pick was made on.
(SubtitleMode, String) subtitleChoiceForSingle(SubtitlePreference preference) {
  return switch (preference) {
    SubtitleAutoPreference() => (SubtitleMode.auto, ''),
    SubtitleOffPreference() => (SubtitleMode.off, ''),
    SubtitleTrackPreference(:final track) => track.url.trim().isEmpty
        ? (SubtitleMode.auto, '')
        : (SubtitleMode.track, track.url.trim()),
  };
}

/// Map this preference onto the engine contract for a series queue: an
/// exact URL only addresses the episode it came from, so the language tag
/// travels instead and every episode resolves its own matching track.
(SubtitleMode, String) subtitleChoiceForSeries(SubtitlePreference preference) {
  return switch (preference) {
    SubtitleAutoPreference() => (SubtitleMode.auto, ''),
    SubtitleOffPreference() => (SubtitleMode.off, ''),
    SubtitleTrackPreference(:final track) => track.language.trim().isEmpty
        ? (SubtitleMode.auto, '')
        : (SubtitleMode.language, track.language.trim()),
  };
}
