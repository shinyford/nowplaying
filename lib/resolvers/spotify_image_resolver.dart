import 'package:flutter/widgets.dart';
import 'package:spotify/spotify.dart';

import '../nowplaying.dart';
import '../nowplaying_track.dart';
import 'nowplaying_image_resolver.dart';

class SpotifyImageResolver implements NowPlayingImageResolver {
  static const int _BATCH_SIZE = 50;

  Future<ImageProvider?> resolve(NowPlayingTrack track) async {
    if (track.hasImage) return null;
    if (NowPlaying.spotify.isUnconnected) return null;

    final album = await _findAlbumFor(track);
    if (album is AlbumSimple) {
      final url = album.images!.first.url!;
      debugPrint('Found image using Spotify image resolver: $url');
      return NetworkImage(url);
    }

    return null;
  }

  Future<AlbumSimple?> _findAlbumFor(NowPlayingTrack track) async {
    if (track.album is! String || track.artist is! String) return null;

    final title = _rationalise(track.album);
    final artist = _rationalise(track.artist);
    final api = await NowPlaying.spotify.api();
    return _search(artist, title, api);
  }

  Future<AlbumSimple?> _search(String artist, String title, SpotifyApi? api, [final int offset = 0]) async {
    if (api is SpotifyApi) {
      final searchTerm = 'remaster album:"$title" artist:"$artist"'.replaceAll(' ', '%2520');
      final search = await api.search.get(searchTerm, types: [SearchType.album]).getPage(_BATCH_SIZE, offset);
      for (final searchItem in search) {
        for (final item in searchItem.items!) {
          if (_isAlbumWithArt(item, artist: artist, title: title)) return item as AlbumSimple;
        }
      }
      if (search.length == _BATCH_SIZE) return _search(artist, title, api, offset + _BATCH_SIZE);
    }
    return null;
  }

  bool _isAlbumWithArt(dynamic album, {required String title, required String artist}) =>
      album is AlbumSimple &&
      album.images?.isNotEmpty == true &&
      _rationalise(album.name) == title &&
      album.artists?.any((a) => _rationalise(a.name) == artist) == true;

  static final _removeDisallowedCharacters = RegExp(r'\[.*?\]|\(.*?\)|[^a-z0-9 ]');
  static final _removeMultipleWhitespace = RegExp(r'\s+');

  String _rationalise(String? text) {
    if (text is! String) return '';
    return text
        .toLowerCase()
        .replaceAll(' & ', ' and ')
        .replaceAll(_removeDisallowedCharacters, '')
        .replaceAll(_removeMultipleWhitespace, ' ')
        .trim();
  }
}
