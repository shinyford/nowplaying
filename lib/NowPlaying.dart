
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

class NowPlaying extends ChangeNotifier with WidgetsBindingObserver {
  static const _channel = const MethodChannel('gomes.com.es/nowplaying');
  static const _refreshPeriod = const Duration(seconds: 1);

  StreamController<NowPlayingTrack> _controller;
  Stream<NowPlayingTrack> get stream => _controller.stream;

  static NowPlaying instance = NowPlaying._();
  NowPlaying._();

  Timer _refreshTimer;

  NowPlayingImageResolver _resolver;
  NowPlayingTrack track = NowPlayingTrack.notPlaying;
  bool _resolveImages = false;

  void start({bool resolveImages, NowPlayingImageResolver resolver}) async { // async, but should not be awaited
    this._resolveImages = resolveImages ?? resolver != null;
    this._resolver = resolver ?? _NowPlayingImageResolver();

    _controller = StreamController<NowPlayingTrack>.broadcast();
    _controller.add(NowPlayingTrack.notPlaying);

    await _bindToWidgetsBinding();
    if (Platform.isAndroid) _channel.setMethodCallHandler(_handler);
    if (Platform.isIOS) _refreshTimer = Timer.periodic(_refreshPeriod, _refresh);

    _refresh();
  }

  void stop() {
    _controller?.close();
    _controller = null;

    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isAndroid) _channel.setMethodCallHandler(null);
    if (Platform.isIOS) {
      _refreshTimer?.cancel();
      _refreshTimer = null;
    }
  }

  void _updateAndNotifyFor(NowPlayingTrack track) {
    this.track = track;
    if (_resolveImages) _resolveImageFor(track);
    _controller.add(track);
    this.track = track;
  }

  void _resolveImageFor(NowPlayingTrack track) async {
    if (!track.hasOrIsResolvingImage) {
      await track._resolveImage();
      this.track = track.copy();
      _controller.add(this.track);
    }
  }

  Future<bool> isEnabled() async =>
      Platform.isIOS || await _channel.invokeMethod('isEnabled');

  Future<bool> requestPermissions({bool force = false}) async {
    if (Platform.isIOS) return true;

    // check to see if we've requested before
    // (unless force == true, in which case make the request again)
    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/com.gomes.nowplaying');
    if (!force && await file.exists()) return false;

    file.create();
    await _channel.invokeMethod('requestPermissions');
    return true;
  }

  // Android
  Future<dynamic> _handler(MethodCall call) async {
    if (call.method == 'track') {
      final data = Map<String, Object>.from(call.arguments[0] ?? {});
      _updateAndNotifyFor(NowPlayingTrack.fromJson(data));
    }
    return true;
  }
  // /Android

  // iOS
  Future<void> _refresh([_]) async {
    final data = await _channel.invokeMethod('track');
    final json = Map<String, Object>.from(data);
    final track = NowPlayingTrack.fromJson(json);
    if (_shouldNotifyFor(track)) _updateAndNotifyFor(track);
  }

  bool _shouldNotifyFor(NowPlayingTrack track) {
    if (track.id == this.track.id && track.state == this.track.state) return false;

    switch (track.state) {
      case NowPlayingState.playing: return true;
      case NowPlayingState.paused: return this.track.isStopped || (this.track.isPlaying && track.id == this.track.id);
      case NowPlayingState.stopped: return track.id != this.track.id;
      default: return false;
    }
  }
  // /iOS

  Future<bool> _bindToWidgetsBinding() {
    if (WidgetsBinding.instance?.isRootWidgetAttached == true) {
      WidgetsBinding.instance.addObserver(this);
      return Future.value(true);
    } else {
      return Future.delayed(const Duration(milliseconds: 250), _bindToWidgetsBinding);
    }
  }

  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!Platform.isIOS) return;

    if (state == AppLifecycleState.resumed) {
      _refreshTimer ??= Timer.periodic(_refreshPeriod, _refresh);
      _refresh();
    } else {
      _refreshTimer?.cancel();
      _refreshTimer = null;
    }
  }
}

enum _NowPlayingImageResolutionState {
  unresolved, resolving, resolved
}

class NowPlayingTrack {
  static NowPlayingTrack notPlaying = NowPlayingTrack();

  static final _images = _LruMap<String, ImageProvider>(size: 3);
  static final _resolutionStates =
      _LruMap<String, _NowPlayingImageResolutionState>(size: 3);
  static final _icons =  _LruMap<String, ImageProvider>();

  final String id;
  final String title;
  final String album;
  final String artist;
  final String source;
  final Duration duration;
  final Duration _position;
  final DateTime _createdAt;
  final NowPlayingState state;

  Duration get progress {
    if (state == NowPlayingState.playing) return _position + DateTime.now().difference(_createdAt);
    return _position;
  }

  ImageProvider get icon {
    if (Platform.isIOS) return const AssetImage('assets/apple_music.png', package: 'nowplaying');
    return _icons[this.source];
  }

  bool get hasIcon => Platform.isIOS || _icons.containsKey(this.source);
  bool get hasImage => image != null;
  bool get isResolvingImage =>
      _resolutionState == _NowPlayingImageResolutionState.resolving;
  bool get needsResolving =>
      _resolutionState == _NowPlayingImageResolutionState.unresolved;
  bool get hasOrIsResolvingImage => hasImage || isResolvingImage;

  String get _imageId => '$artist:$album';

  ImageProvider get image => _images[_imageId];
  set image(ImageProvider image) => _images[_imageId] = image;

  _NowPlayingImageResolutionState get _resolutionState => _resolutionStates[_imageId];
  set _resolutionState(_NowPlayingImageResolutionState state) =>
      _resolutionStates[_imageId] = state;

  NowPlayingTrack({
    this.id,
    this.title,
    this.album,
    this.artist,
    this.duration = Duration.zero,
    this.state = NowPlayingState.stopped,
    this.source,
    Duration position,
    DateTime createdAt,
  }) :
    this._position = position ?? Duration.zero,
    this._createdAt = createdAt ?? DateTime.now();

  factory NowPlayingTrack.fromJson(Map<String, dynamic> json) {
    if (json == null || json.isEmpty) return notPlaying;

    final state = NowPlayingState.values[json['state']];
    if (state == NowPlayingState.stopped) return notPlaying;

    final String imageId = '${json['artist']}:${json['album']}';
    if (!_images.containsKey(imageId)) {
      final Uint8List imageData = json['image'];
      if (imageData is Uint8List) {
        _images[imageId] = MemoryImage(imageData);
      } else {
        final String imageUri = json['imageUri'];
        if (imageUri is String) _images[imageId] = NetworkImage(imageUri);
      }
      _resolutionStates[imageId] = _NowPlayingImageResolutionState.unresolved;
    }

    final Uint8List iconData = json['sourceIcon'];
    if (iconData is Uint8List) _icons[json['source']] ??= MemoryImage(iconData);

    final String id = json['id'].toString();
    return NowPlayingTrack(
      id: id,
      title: json['title'],
      album: json['album'],
      artist: json['artist'],
      duration: Duration(milliseconds: json['duration'] ?? 0),
      position: Duration(milliseconds: json['position'] ?? 0),
      state: state,
      source: json['source']
    );
  }

  NowPlayingTrack copy() =>
    NowPlayingTrack(
      id: this.id,
      title: this.title,
      album: this.album,
      artist: this.artist,
      duration: this.duration,
      position: this._position,
      state: this.state,
      source: this.source,
      createdAt: this._createdAt
    );

  bool get isPlaying => this.state == NowPlayingState.playing;
  bool get isPaused => this.state == NowPlayingState.paused;
  bool get isStopped => this.state == NowPlayingState.stopped;

  String toString() =>
    isStopped
      ? 'NowPlaying: -silence-'
      : 'NowPlaying:'
        '\n title: $title'
        '\n artist: $artist'
        '\n album: $album'
        '\n duration: ${duration.inMilliseconds}ms'
        '\n stat: $state';

  Future<void> _resolveImage() async {
    if (this.needsResolving) {
      _resolutionState = _NowPlayingImageResolutionState.resolving;
      this.image = await NowPlaying.instance._resolver.resolve(this);
      _resolutionState = _NowPlayingImageResolutionState.resolved;
    }
  }
}

enum NowPlayingState {
  playing, paused, stopped
}

abstract class NowPlayingImageResolver {
  Future<ImageProvider> resolve(NowPlayingTrack track);
}

class _NowPlayingImageResolver implements NowPlayingImageResolver {
  Future<ImageProvider> resolve(NowPlayingTrack track) async {
    if (track.hasImage) return null;
    if (track.artist == null || track.album == null) return null;

    return _getAlbumCover(track);
  }

  Future<ImageProvider> _getAlbumCover(NowPlayingTrack track) async {
    final String albumTitle = _rationalise(track.album);
    final String artistName = _rationalise(track.artist);

    final json = await _getJson('https://musicbrainz.org/ws/2/release?type=album&limit=100&query=$albumTitle');
    if (json == null) return null;

    for (Map<String, dynamic> release in json['releases']) {
      for (Map<String, dynamic> artist in release['artist-credit']) {
        if (artist['joinphrase'] != null) continue;
        if (_rationalise(artist['name']) == artistName) {
          final albumArt = await _getAlbumArt(release['id']);
          if (albumArt != null) return albumArt;
        }
      }
    }

    return null;
  }

  Future<ImageProvider> _getAlbumArt(String mbid) async {
    final json = await _getJson('https://coverartarchive.org/release/$mbid');
    if (json == null) return null;

    String image;
    String thumb;

    for (Map<String, dynamic> image in json['images']) {
      if (image['front'] == true) {
        final thumbs = Map<String, String>.from(image['thumbnails']);
        thumb ??= thumbs['large'];
        image ??= image['image'];
        if (thumb != null && image != null) break;
      }
    }

    if (image == null && thumb == null) return null;
    return NetworkImage(thumb ?? image);
  }

  Future<Map<String, dynamic>> _getJson(String url) async {
    final client = HttpClient();
    final req = await client.openUrl('GET', Uri.parse(url));
    req.headers.add('Accept', 'application/json');
    req.headers.add('User-Agent', 'NowPlaying Flutter Package/0.1.0 ( nicsford+NowPlayingFlutter@gmail.com )');
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

  String _rationalise(String text) =>
      text.toLowerCase().replaceAll('the ', '').trim();
}

class _LruMap<K, V> {
  final int size;
  final List<K> _keys = [];
  final Map<K, V> _map = {};

  _LruMap({this.size = 5}) : assert(size > 0);

  operator [](K key) => _map[key];

  void operator []=(K key, V value) {
    _map[key] = value;
    _keys.remove(key);
    _keys.insert(0, key);
    if (_keys.length > size) {
      final K removedKey = _keys.removeLast();
      _map.remove(removedKey);
    }
  }

  void remove(K key) {
    _keys.remove(key);
    _map.remove(key);
  }

  bool containsKey(K key) => _keys.contains(key);
}
