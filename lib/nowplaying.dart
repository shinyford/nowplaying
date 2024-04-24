/// A library that surfaces metadata for the track currently playing over the
/// device's audio, outside the control of the importing app.
///
/// Use a NotificationListenerService for Android; polls the current playing
/// information from the systemMusicPlayer for iOS

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nowplaying/nowplaying_spotify_controller.dart';
import 'package:package_info/package_info.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'nowplaying_track.dart';
import 'resolvers/nowplaying_image_resolver.dart';

bool get isIOS => !kIsWeb && Platform.isIOS;
bool get isAndroid => !kIsWeb && Platform.isAndroid;

/// The current playing state of a track
enum NowPlayingState { playing, paused, stopped }

/// A container for the service. Connects with the underlying OS via a method
/// channel to pull out track data.
class NowPlaying with WidgetsBindingObserver {
  static const _channel = MethodChannel('gomes.com.es/nowplaying');
  static const _refreshPeriod = Duration(seconds: 1);

  static NowPlaying instance = NowPlaying._();
  NowPlaying._();

  Timer? _refreshTimer;

  NowPlayingImageResolver? resolver;
  SpotifyTrack? _spotifyTrack;
  NowPlayingTrack? _deviceTrack;
  NowPlayingTrack get track {
    if (_deviceTrack?.isPlaying == true) return _deviceTrack!;
    if (_spotifyTrack is SpotifyTrack) return _spotifyTrack!;
    if (_deviceTrack is NowPlayingTrack) return _deviceTrack!;
    return NowPlayingTrack.notPlaying;
  }

  set track(NowPlayingTrack? track) {
    if (track == null) {
      _spotifyTrack = _deviceTrack = null;
    } else if (track.isSpotifyTrack) {
      _spotifyTrack = track as SpotifyTrack;
    } else {
      _deviceTrack = track;
    }
  }

  static NowplayingSpotifyController spotify = NowplayingSpotifyController();

  late StreamController<NowPlayingTrack> _controller;
  Stream<NowPlayingTrack> get stream => _controller.stream;
  bool _resolveImages = false;

  /// Starts the service.
  ///
  /// Initialises stream, sets up the app lifecycle observer, starts a polling
  /// timer on iOS, sets incoming method handler for Android
  Future<void> start({
    bool resolveImages = false,
    NowPlayingImageResolver? resolver,
    String? spotifyClientId,
    String? spotifyClientSecret,
  }) async {
    WidgetsFlutterBinding.ensureInitialized();

    _spotifyTrack = _deviceTrack = null;
    _controller = StreamController<NowPlayingTrack>.broadcast();
    _controller.add(track);

    this._resolveImages = resolver != null || resolveImages;
    this.resolver = resolver ?? (_resolveImages ? DefaultNowPlayingImageResolver() : null);

    final prefs = await SharedPreferences.getInstance();
    NowPlaying.spotify.setPrefs(prefs);
    if (spotifyClientId is String && spotifyClientSecret is String) {
      NowPlaying.spotify.setCredentials(clientId: spotifyClientId, clientSecret: spotifyClientSecret);
    }

    _bindToWidgetsBinding();
    if (isAndroid) _channel.setMethodCallHandler(_handler);
    _refreshTimer = Timer.periodic(_refreshPeriod, _refresh);

    final info = await PackageInfo.fromPlatform();
    print('NowPlaying ${info.version} is part of ${info.packageName}');

    await _refresh();
  }

  /// Stops the service.
  ///
  /// Kills stream, timer and method call handler
  void stop() {
    _controller.close();

    resolver = null;

    WidgetsBinding.instance.removeObserver(this);
    if (isAndroid) _channel.setMethodCallHandler(null);

    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  void _updateAndNotifyFor(NowPlayingTrack track) {
    if (_resolveImages && track.imageNeedsResolving) _resolveImageFor(track);
    _controller.add(track);
    this.track = track;
  }

  void _resolveImageFor(NowPlayingTrack track) async {
    await track.resolveImage();
    this.track = track.copy();
    _controller.add(this.track);
  }

  /// Returns true is the service has permission granted by the systme and user
  Future<bool> isEnabled() async {
    return isIOS || (await _channel.invokeMethod<bool>('isEnabled') ?? false);
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

  Future<void> _refresh([_]) async {
    if (NowPlaying.spotify.isConnected) {
      final track = await NowPlaying.spotify.currentTrack();
      if (_shouldNotifyFor(track)) _updateAndNotifyFor(track);
    }

    if (isIOS) {
      final data = await _channel.invokeMethod('track');
      final json = Map<String, Object?>.from(data);
      final track = NowPlayingTrack.fromJson(json);
      if (_shouldNotifyFor(track)) _updateAndNotifyFor(track);
    }
  }

  bool _shouldNotifyFor(NowPlayingTrack newTrack) {
    if (newTrack.isSpotifyNotification && this.track is SpotifyTrack) return false;
    return newTrack.isPlaying || !this.track.isPlaying;
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
}
