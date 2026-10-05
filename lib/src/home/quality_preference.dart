import 'package:segmeris/src/rust/api/downloader.dart';

/// Pick the stream that matches the tier the user chose.
///
/// A multi-episode download resolves every episode separately — that is what
/// keeps each episode's signed CDN URLs fresh — so the exact URL the user
/// picked is only valid for the episode it was picked on. What travels across
/// the queue is the *tier*: the source's own quality name plus the codec and
/// protocol it arrived in.
///
/// The cascade runs from "the same stream" to "the closest thing the server
/// still offers": an exact tier match, then the same quality in another codec
/// or protocol, then the same height, and finally the best-ranked candidate so
/// that one episode lacking a tier never sinks the whole queue. What was
/// actually picked is visible on the task itself, since each task reports the
/// quality label it resolved.
MediaCandidate? candidateForTier(
  List<MediaCandidate> candidates,
  MediaCandidate? preferred,
) {
  if (candidates.isEmpty) {
    return null;
  }
  if (preferred == null) {
    return candidates.first;
  }

  final label = preferred.qualityLabel.trim();
  final codec = preferred.codec.trim();
  final protocol = preferred.protocol.trim();
  final height = preferred.height;

  MediaCandidate? sameLabel;
  MediaCandidate? sameLabelOtherProtocol;
  MediaCandidate? sameHeight;
  MediaCandidate? sameHeightOtherProtocol;

  for (final candidate in candidates) {
    final protocolMatches = candidate.protocol.trim() == protocol;
    if (label.isNotEmpty && candidate.qualityLabel.trim() == label) {
      if (candidate.codec.trim() == codec && protocolMatches) {
        return candidate;
      }
      sameLabel ??= candidate;
      if (protocolMatches) {
        sameLabelOtherProtocol ??= candidate;
      }
    }
    if (height > 0 && candidate.height == height) {
      if (candidate.codec.trim() == codec && protocolMatches) {
        sameHeight ??= candidate;
      }
      sameHeightOtherProtocol ??= candidate;
    }
  }

  return sameLabelOtherProtocol ??
      sameLabel ??
      sameHeight ??
      sameHeightOtherProtocol ??
      candidates.first;
}
