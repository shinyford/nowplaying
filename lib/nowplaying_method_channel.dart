import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'nowplaying_platform_interface.dart';

/// An implementation of [NowplayingPlatform] that uses method channels.
class MethodChannelNowplaying extends NowplayingPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('nowplaying');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
