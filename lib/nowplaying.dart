/// A library that surfaces metadata for the track currently playing over the
/// device's audio, outside the control of the importing app.
///
/// Use a NotificationListenerService for Android; polls the current playing
/// information from the systemMusicPlayer for iOS

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:oauth2/oauth2.dart';
import 'package:package_info/package_info.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotify/spotify.dart';
import 'package:uuid/uuid.dart';
import 'package:webview_flutter/webview_flutter.dart';

bool get isIOS => !kIsWeb && Platform.isIOS;
bool get isAndroid => !kIsWeb && Platform.isAndroid;

/// A container for the service. Connects with the underlying OS via a method
/// channel to pull out track data.
class NowPlaying with WidgetsBindingObserver {
  static const _channel = const MethodChannel('gomes.com.es/nowplaying');
  static const _refreshPeriod = const Duration(seconds: 1);

  SpotifyApi? _spotifyApi;

  static const String _SPOTIFY_ACCESS_KEY = 'spotify.access.key';
  static const String _SPOTIFY_REFRESH_KEY = 'spotify.refresh.key';
  static const String _SPOTIFY_EXPIRATION_KEY = 'spotify.expiration.key';

  static const String _redirectUri = 'https://nowplaying.gomes.com/redirect';
  static const List<String> _scopes = const [
    'user-read-email',
    'user-library-read',
    'user-read-recently-played',
    'user-read-currently-playing'
  ];

  static NowPlaying instance = NowPlaying._();
  NowPlaying._();

  Timer? _refreshTimer;

  StreamController<NowPlayingTrack>? _controller;
  Stream<NowPlayingTrack> get stream => _controller!.stream;
  NowPlayingImageResolver? _resolver;
  NowPlayingTrack track = NowPlayingTrack.notPlaying;
  bool _resolveImages = false;
  late AuthorizationCodeGrant _grant;
  late SharedPreferences _prefs;

  /// Starts the service.
  ///
  /// Initialises stream, sets up the app lifecycle observer, starts a polling
  /// timer on iOS, sets incoming method handler for Android
  Future<void> start({bool resolveImages = false, NowPlayingImageResolver? resolver}) async {
    // async, but should not be awaited
    this._resolveImages = resolver != null || resolveImages;
    this._resolver = resolver ?? (_resolveImages ? DefaultNowPlayingImageResolver() : null);

    this.track = NowPlayingTrack.notPlaying;

    this._prefs = await SharedPreferences.getInstance();

    _controller = StreamController<NowPlayingTrack>.broadcast();
    _controller!.add(NowPlayingTrack.notPlaying);

    await _bindToWidgetsBinding();
    if (isAndroid) _channel.setMethodCallHandler(_handler);
    if (isIOS) _refreshTimer = Timer.periodic(_refreshPeriod, _refresh);

    final info = await PackageInfo.fromPlatform();
    debugPrint('NowPlaying ${info.version} is part of ${info.packageName}');

    await _refresh();
  }

  /// Stops the service.
  ///
  /// Kills stream, timer and method call handler
  void stop() {
    _controller?.close();
    _controller = null;

    _resolver = null;

    WidgetsBinding.instance.removeObserver(this);
    if (isAndroid) _channel.setMethodCallHandler(null);
    if (isIOS) {
      _refreshTimer?.cancel();
      _refreshTimer = null;
    }
  }

  void _updateAndNotifyFor(NowPlayingTrack track) {
    if (_resolveImages) _resolveImageFor(track);
    _controller!.add(track);
    this.track = track;
  }

  void _resolveImageFor(NowPlayingTrack track) async {
    if (track.imageNeedsResolving) {
      await track._resolveImage();
      this.track = track.copy();
      _controller!.add(this.track);
    }
  }

  /// Returns true is the service has permission granted by the systme and user
  Future<bool> isEnabledForDeviceSources() async {
    return isIOS || (await _channel.invokeMethod<bool>('isEnabled') ?? false);
  }

  Future<bool> isEnabledForSpotify() async {
    return false;
  }

  Future<bool> isEnabled() async {
    final result = await Future.wait([isEnabledForDeviceSources(), isEnabledForSpotify()]);
    return result.any((t) => t);
  }

  /// Opens an OS settings page
  ///
  /// Returns true if:
  ///   - OS is iOS, or
  ///   - permission has already been given, or
  ///   - the settings screen has not been opened by this app before, or
  ///   - opening the screen this time is `force`d
  ///
  /// Returns false if:
  ///   - OS is Android, and
  ///   - permission has not been given by the user, and
  ///   - the settings screen has been opened by this app before
  Future<bool> requestPermissions({bool force = false}) async {
    if (isIOS) return true;

    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/com.gomes.nowplaying');
    if (!force && await file.exists()) return false;

    file.create();
    await _channel.invokeMethod<bool>('requestPermissions');
    return true;
  }

  // Android
  Future<dynamic> _handler(MethodCall call) async {
    if (call.method == 'track') {
      final data = Map<String, Object?>.from(call.arguments[0] ?? {});
      final track = NowPlayingTrack.fromJson(data);
      if (_shouldNotifyFor(track)) _updateAndNotifyFor(track);
    }
    return true;
  }
  // /Android

  // iOS
  Future<void> _refresh([_]) async {
    final data = await _channel.invokeMethod('track');
    final json = Map<String, Object?>.from(data);
    final track = NowPlayingTrack.fromJson(json);
    if (_shouldNotifyFor(track)) _updateAndNotifyFor(track);
  }
  // /iOS

  bool _shouldNotifyFor(NowPlayingTrack newTrack) {
    if (newTrack.isStopped) return !this.track.isStopped;

    final positionDifferential = (newTrack.position - this.track.position).inMilliseconds;
    final timeDifferential = newTrack._createdAt.difference(this.track._createdAt).inMilliseconds;
    final positionUnexpected = positionDifferential < 0 || positionDifferential > timeDifferential + 250;

    if (newTrack.id != this.track.id || newTrack.state != this.track.state || positionUnexpected) {
      switch (newTrack.state) {
        case NowPlayingState.playing:
          return true;
        case NowPlayingState.paused:
          return this.track.isStopped || (this.track.isPlaying && newTrack.id == this.track.id);
        default:
          return false;
      }
    }

    return false;
  }

  Future<bool> _bindToWidgetsBinding() async {
    WidgetsFlutterBinding.ensureInitialized();
    if (WidgetsBinding.instance.isRootWidgetAttached == true) {
      WidgetsBinding.instance.addObserver(this);
      return true;
    } else {
      return Future.delayed(const Duration(milliseconds: 250), _bindToWidgetsBinding);
    }
  }

  /// Respond to changes in the app lifecycle state, on iOS
  ///
  /// Restart timer if resumed; else cancel it
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (isIOS) _refreshTimer ??= Timer.periodic(_refreshPeriod, _refresh);
      _refresh();
    } else {
      _refreshTimer?.cancel();
      _refreshTimer = null;
      this.track = NowPlayingTrack.notPlaying;
    }
  }

  String clientId = '';
  String clientSecret = '';

  void setSpotifyCredentials({required String clientId, required String clientSecret}) {
    this.clientId = clientId;
    this.clientSecret = clientSecret;
  }

  bool get spotifyConnected {
    final int expiration = _prefs.getInt(_SPOTIFY_EXPIRATION_KEY) ?? 0;
    return expiration > DateTime.now().millisecondsSinceEpoch;
  }

  bool get spotifyUnconnected => !spotifyConnected;

  Widget spotifySignInPage(context) {
    final _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (navReq) {
            if (navReq.url.startsWith(_redirectUri)) {
              this._spotifyApi = SpotifyApi.fromAuthCodeGrant(this._grant, navReq.url);
              _saveCredentials();
              Navigator.of(context).pop();
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(_authUri);

    return WebViewWidget(controller: _controller);
  }

  Future<SpotifyApi?> spotifyApi() async {
    if (this._spotifyApi == null) {
      final String? accessToken = _prefs.getString(_SPOTIFY_ACCESS_KEY);
      final String? refreshToken = _prefs.getString(_SPOTIFY_REFRESH_KEY);
      final int expiration = _prefs.getInt(_SPOTIFY_EXPIRATION_KEY) ?? 0;

      if (accessToken is String && refreshToken is String && expiration > DateTime.now().millisecondsSinceEpoch) {
        final creds = SpotifyApiCredentials(
          this.clientId,
          this.clientSecret,
          accessToken: accessToken,
          refreshToken: refreshToken,
          scopes: _scopes,
          expiration: DateTime.fromMillisecondsSinceEpoch(expiration),
        );

        try {
          this._spotifyApi = SpotifyApi(creds);
        } on AuthorizationException catch (e) {
          debugPrint(e.toString());
          this._spotifyApi = null;
        }

        _saveCredentials();
      }
    }

    return this._spotifyApi;
  }

  void _saveCredentials() async {
    if (this._spotifyApi is SpotifyApi) {
      final SpotifyApiCredentials creds = await this._spotifyApi!.getCredentials();
      _prefs.setString(_SPOTIFY_ACCESS_KEY, creds.accessToken!);
      _prefs.setString(_SPOTIFY_REFRESH_KEY, creds.refreshToken!);
      _prefs.setInt(_SPOTIFY_EXPIRATION_KEY, creds.expiration!.millisecondsSinceEpoch);
    }
  }

  Uri get _authUri {
    this._grant = SpotifyApi.authorizationCodeGrant(
      SpotifyApiCredentials(this.clientId, this.clientSecret),
    );
    return this._grant.getAuthorizationUrl(Uri.parse(_redirectUri), scopes: _scopes);
  }
}

enum _NowPlayingImageResolutionState { unresolved, resolving, resolved }

/// A container for metadata around a single track state
///
/// Artist, album, track, duration, genre, source, progress
class NowPlayingTrack {
  static final NowPlayingTrack notPlaying = NowPlayingTrack(id: 'notplaying');
  static final NowPlayingTrack loading = NowPlayingTrack(id: 'loading');

  static final _essentialRegExp = RegExp(r'\(.*\)|\[.*\]');

  static final _images = _LruMap<String, ImageProvider?>(size: 3);
  static final _resolutionStates = _LruMap<String, _NowPlayingImageResolutionState?>(size: 3);
  static final _icons = _LruMap<String?, ImageProvider>();

  final String id;
  final String? title;
  final String? album;
  final String? artist;
  final String? source;
  final Duration duration;
  final Duration position;
  final DateTime _createdAt;
  final NowPlayingState state;

  /// How long the track been has been playing, as a `Duration`
  ///
  /// If the track is playing: how much had been played at the time the state
  /// was recorded, plus elapsed time since then
  ///
  /// If the track is not playing: how much had been played at the time the state
  /// was recorded
  Duration get progress {
    if (state == NowPlayingState.playing) return position + DateTime.now().difference(_createdAt);
    return position;
  }

  String? get essentialAlbum => _essential(album);
  String? get essentialTitle => _essential(title);
  String? _essential(String? text) {
    if (text == null) return null;
    final String essentialText = text.replaceAll(_essentialRegExp, '').trim();
    return essentialText.isEmpty ? text : essentialText;
  }

  /// An image representing the app playing the track
  ImageProvider? get icon {
    if (isIOS) return const AssetImage('assets/apple_music.png', package: 'nowplaying');
    if (source == 'com.acmeandroid.listen') return const AssetImage('assets/listenapp.png', package: 'nowplaying');
    return _icons[this.source];
  }

  bool get hasIcon => isIOS || _icons.containsKey(this.source);
  bool get hasImage => image != null;

  /// true if the image is being resolved, else false
  bool get isResolvingImage => _resolutionState == _NowPlayingImageResolutionState.resolving;

  /// true of the image is empty and a resolution hasn't been attempted, else false
  bool get imageNeedsResolving => _resolutionState == _NowPlayingImageResolutionState.unresolved;

  String get _imageId => '$artist:$album';

  /// The image for the track, probably album art
  ///
  /// A bit of sophistry here: images are stored per album rather than per
  /// track, for efficiency, and shared.
  ImageProvider? get image => _images[_imageId];
  set image(ImageProvider? image) => _images[_imageId] = image;

  _NowPlayingImageResolutionState? get _resolutionState => _resolutionStates[_imageId];
  set _resolutionState(_NowPlayingImageResolutionState? state) => _resolutionStates[_imageId] = state;

  NowPlayingTrack({
    String? id,
    this.title,
    this.album,
    this.artist,
    this.duration = Duration.zero,
    this.state = NowPlayingState.stopped,
    this.source,
    this.position = Duration.zero,
    DateTime? createdAt,
  })  : this.id = id ?? Uuid().v4(),
        this._createdAt = createdAt ?? DateTime.now();

  /// Creates a track from json
  ///
  /// Returns the static `notPlaying` instance if player is stopped
  ///
  /// Creates image and icon art if not already present/resolved
  factory NowPlayingTrack.fromJson(Map<String, dynamic> json) {
    if (json.isEmpty) return notPlaying;

    final state = NowPlayingState.values[json['state']];
    if (state == NowPlayingState.stopped) return notPlaying;

    final String imageId = '${json['artist']}:${json['album']}';

    if (!_images.containsKey(imageId)) {
      final Uint8List? imageData = json['image'];
      if (imageData is Uint8List) {
        _images[imageId] = MemoryImage(imageData);
      } else {
        final String? imageUri = json['imageUri'];
        if (imageUri is String) _images[imageId] = NetworkImage(imageUri);
      }
    }

    _resolutionStates[imageId] ??= _NowPlayingImageResolutionState.unresolved;

    final Uint8List? iconData = json['sourceIcon'];
    if (iconData is Uint8List) _icons[json['source']] ??= MemoryImage(iconData);

    return NowPlayingTrack(
      id: json['id'].toString(),
      title: json['title'],
      album: json['album'],
      artist: json['artist'],
      duration: Duration(milliseconds: json['duration'] ?? 0),
      position: Duration(milliseconds: json['position'] ?? 0),
      state: state,
      source: json['source'],
    );
  }

  /// Creates a copy of a track, largely so that the stream knows it's mutated
  NowPlayingTrack copy() => NowPlayingTrack(
        id: this.id,
        title: this.title,
        album: this.album,
        artist: this.artist,
        duration: this.duration,
        position: this.position,
        state: this.state,
        source: this.source,
        createdAt: this._createdAt,
      );

  bool get isPlaying => this.state == NowPlayingState.playing;
  bool get isPaused => this.state == NowPlayingState.paused;
  bool get isStopped => this.state == NowPlayingState.stopped;

  String toString() => isStopped
      ? 'NowPlaying: -silence-'
      : 'NowPlaying:'
          '\n title: $title'
          '\n artist: $artist'
          '\n album: $album'
          '\n duration: ${duration.inMilliseconds}ms'
          '\n position: ${position.inMilliseconds}ms'
          '\n has image: $hasImage'
          '\n state: $state';

  Future<void> _resolveImage() async {
    if (imageNeedsResolving && !hasImage) {
      _resolutionState = _NowPlayingImageResolutionState.resolving;
      final ImageProvider? image = await NowPlaying.instance._resolver?.resolve(this);
      if (image != null) this.image = image;
      _resolutionState = _NowPlayingImageResolutionState.resolved;
    }
  }
}

/// The current playing state of a track
enum NowPlayingState { playing, paused, stopped }

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

class SpotifyImageResolver implements NowPlayingImageResolver {
  static const int _BATCH_SIZE = 50;

  Future<ImageProvider?> resolve(NowPlayingTrack track) async {
    if (track.hasImage) return null;
    if (NowPlaying.instance.spotifyUnconnected) return null;

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
    final api = await NowPlaying.instance.spotifyApi();
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

class NativeImageResolver implements NowPlayingImageResolver {
  static final RegExp _rationaliseRegExp = RegExp(r' - single|the |and |& |\(.*\)');

  Future<ImageProvider?> resolve(NowPlayingTrack track) async {
    if (track.hasImage) return null;

    final String query = Uri.encodeQueryComponent([
      if (track.artist != null) 'artist:(${_rationalise(track.artist!)})',
      if (track.album != null) 'release:(${_rationalise(track.album!)})',
    ].join(' AND '));
    if (query.isEmpty) return null;

    debugPrint('NowPlaying - image resolution query: $query');

    final json = await _getJson('https://musicbrainz.org/ws/2/release?primarytype=album&limit=100&query=$query');
    if (json == null) return null;

    for (Map<String, dynamic> release in json['releases']) {
      if (release['score'] < 100) break;
      final albumArt = await _getAlbumArt(release['id']);
      if (albumArt != null) return albumArt;
    }

    return null;
  }

  Future<ImageProvider?> _getAlbumArt(String? mbid) async {
    debugPrint('NowPlaying - trying to find cover for $mbid');
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
    req.headers.add('User-Agent',
        'Flutter NowPlaying ${info.version} in ${info.packageName} ( nicsford+NowPlayingFlutter@gmail.com )');
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

  bool containsKey(K key) => _map.containsKey(key);
}
