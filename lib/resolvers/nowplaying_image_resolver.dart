import 'package:flutter/widgets.dart';

import '../nowplaying_track.dart';
import 'native_image_resolver.dart';
import 'spotify_image_resolver.dart';

/// Resolve (probably) missing images for a track by returning an
/// appropriate `ImageProvider` for it
abstract class NowPlayingImageResolver {
  /// Returns an `ImageProvider` for a given `NowPlayingTrack`
  ///
  /// If an image cannot be resolved, or does not need to be for
  /// some reason (e.g. we're happy with the image that has already
  /// been found in the system metadata) `resolve` should return `null`
  Future<ImageProvider?> resolve(NowPlayingTrack track);
}

class DefaultNowPlayingImageResolver implements NowPlayingImageResolver {
  final spotifyImageResolver = SpotifyImageResolver();
  final nativeImageResolver = NativeImageResolver();

  Future<ImageProvider?> resolve(NowPlayingTrack track) async {
    final provider = await spotifyImageResolver.resolve(track);
    if (provider is ImageProvider) return provider;
    return nativeImageResolver.resolve(track);
  }
}
