import 'package:flutter/material.dart';
import 'package:oauth2/oauth2.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotify/spotify.dart';
import 'package:webview_flutter/webview_flutter.dart';

class NowplayingSpotifyController {
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

  late SharedPreferences _prefs;

  SpotifyApi? _spotifyApi;
  String _clientId = '';
  String _clientSecret = '';

  late AuthorizationCodeGrant _grant;

  void setPrefs(SharedPreferences prefs) => this._prefs = prefs;

  void setCredentials({required String clientId, required String clientSecret}) {
    this._clientId = clientId;
    this._clientSecret = clientSecret;
  }

  bool get isConnected {
    final int expiration = _prefs.getInt(_SPOTIFY_EXPIRATION_KEY) ?? 0;
    return expiration > DateTime.now().millisecondsSinceEpoch;
  }

  bool get isUnconnected => !isConnected;

  Widget signInPage(context) {
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

  Future<SpotifyApi?> api() async {
    if (this._spotifyApi == null) {
      final String? accessToken = _prefs.getString(_SPOTIFY_ACCESS_KEY);
      final String? refreshToken = _prefs.getString(_SPOTIFY_REFRESH_KEY);
      final int expiration = _prefs.getInt(_SPOTIFY_EXPIRATION_KEY) ?? 0;

      if (accessToken is String && refreshToken is String && expiration > DateTime.now().millisecondsSinceEpoch) {
        final creds = SpotifyApiCredentials(
          this._clientId,
          this._clientSecret,
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
      SpotifyApiCredentials(this._clientId, this._clientSecret),
    );
    return this._grant.getAuthorizationUrl(Uri.parse(_redirectUri), scopes: _scopes);
  }
}
