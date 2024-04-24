import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:package_info/package_info.dart';

import '../nowplaying_track.dart';
import 'nowplaying_image_resolver.dart';

class NativeImageResolver implements NowPlayingImageResolver {
  static final RegExp _rationaliseRegExp = RegExp(r' - single|the |and |& |\(.*\)');

  Future<ImageProvider?> resolve(NowPlayingTrack track) async {
    if (track.hasImage) return null;

    final String query = Uri.encodeQueryComponent([
      if (track.artist != null) 'artist:(${_rationalise(track.artist!)})',
      if (track.album != null) 'release:(${_rationalise(track.album!)})',
    ].join(' AND '));
    if (query.isEmpty) return null;

    print('NowPlaying - image resolution query: $query');

    final json = await _getJson('https://musicbrainz.org/ws/2/release?primarytype=album&limit=100&query=$query');
    if (json == null) return null;

    for (Map<String, dynamic> release in json['releases']) {
      if (release['score'] as int >= 100) {
        final albumArt = await _getAlbumArt(release['id']);
        if (albumArt != null) return albumArt;
      }
    }

    return null;
  }

  Future<ImageProvider?> _getAlbumArt(String? mbid) async {
    print('NowPlaying - trying to find cover for $mbid');
    final json = await _getJson('https://coverartarchive.org/release/$mbid');
    if (json == null) return null;

    String? image;
    String? thumb;

    for (Map<String, dynamic> imageData in json['images']) {
      if (imageData['front'] == true) {
        final thumbs = Map<String, String>.from(imageData['thumbnails']);
        thumb ??= thumbs['large'];
        image = imageData['image'];
        if (thumb != null) break;
      }
    }

    final String? usable = thumb ?? image;
    return usable is String ? NetworkImage(usable) : null;
  }

  Future<Map<String, dynamic>?> _getJson(String url) async {
    final info = await PackageInfo.fromPlatform();
    final client = HttpClient();
    final req = await client.openUrl('GET', Uri.parse(url));
    req.headers.add('Accept', 'application/json');
    req.headers.add('User-Agent', 'Flutter NowPlaying ${info.version} in ${info.packageName} ( nicsford+NowPlayingFlutter@gmail.com )');
    final resp = await req.close();
    if (resp.statusCode != 200) return null;

    final completer = Completer<Map<String, dynamic>>();
    final body = StringBuffer();
    resp.transform(utf8.decoder).listen(body.write, onDone: () {
      final json = jsonDecode(body.toString());
      completer.complete(json);
    });
    return completer.future;
  }

  String _rationalise(String text) {
    final lowerText = text.toLowerCase().trim();
    if (lowerText == 'the the') return lowerText; // the Matt Johnson exemption
    return lowerText.replaceAll(_rationaliseRegExp, '').trim();
  }
}
