import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'nowplaying_method_channel.dart';

abstract class NowplayingPlatform extends PlatformInterface {
  /// Constructs a NowplayingPlatform.
  NowplayingPlatform() : super(token: _token);

  static final Object _token = Object();

  static NowplayingPlatform _instance = MethodChannelNowplaying();

  /// The default instance of [NowplayingPlatform] to use.
  ///
  /// Defaults to [MethodChannelNowplaying].
  static NowplayingPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [NowplayingPlatform] when
  /// they register themselves.
  static set instance(NowplayingPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
