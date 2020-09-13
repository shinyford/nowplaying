import 'package:flutter/material.dart';
import 'package:nowplaying/nowplaying.dart';
import 'package:provider/provider.dart';

void main() {
  NowPlaying.instance.start(resolveImages: true);
  runApp(MyApp());
}

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void initState() {
    super.initState();
    NowPlaying.instance.isEnabled().then((bool isEnabled) async {
      if (!isEnabled) {
        final shown = await NowPlaying.instance.requestPermissions(force: true);
        print('MANAGED TO SHOW PERMS PAGE: $shown');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: NowPlaying.instance,
      child: MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            title: const Text('NowPlaying example app'),
          ),
          body: Center(
            child: Consumer<NowPlaying>(
              builder: (context, nowPlaying, _) {
                final track = nowPlaying.track;
                return Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (track == null || track.isStopped) Text('nothing playing'),
                    if (track?.isStopped == false) ...[
                      if (track.title != null) Text(track.title),
                      if (track.artist != null) Text(track.artist),
                      if (track.album != null) Text(track.album),
                      if (track.duration != null)Text(track.duration.toString().split('.').first.padLeft(8, '0')),
                      Text(track.state.toString()),
                      Stack(
                        alignment: Alignment.center,
                        // fit: StackFit.loose,
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 300),
                            margin: const EdgeInsets.all(8.0),
                            width: 200,
                            height: 200,
                            alignment: Alignment.center,
                            color: Colors.grey,
                            child: _imageFrom(track)
                          ),
                          Positioned(bottom: 0, right: 0, child: _iconFrom(track))
                        ],
                      ),
                    ]
                  ],
                );
              }
            )
          ),
        ),
      ),
    );
  }

  Widget _imageFrom(NowPlayingTrack track) {
    if (track.hasImage) return Image(image: track.image, width: 200, height: 200, fit: BoxFit.contain);

    if (track.isResolvingImage) return Container(
      width: 50.0,
      height: 50.0,
      child: CircularProgressIndicator(valueColor: AlwaysStoppedAnimation<Color>(Colors.white))
    );

    return Text('NO\nARTWORK\nFOUND', textAlign: TextAlign.center, style: const TextStyle(fontSize: 24, color: Colors.white));
  }

  Widget _iconFrom(NowPlayingTrack track) {
    if (track.hasIcon) return Container(
      padding: const EdgeInsets.all(6),
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [const BoxShadow(blurRadius: 5, color: Colors.black)],
        shape: BoxShape.circle
      ),
      child: Image(
        image: track.icon,
        width: 25,
        height: 25,
        fit: BoxFit.contain,
        color: _fgColorFor(track),
        colorBlendMode: BlendMode.srcIn,
      ),
    );
    return Container();
  }

  Color _fgColorFor(NowPlayingTrack track) {
    switch (track.source) {
      case "music.apple.com": return Colors.blue;
      case "com.hughesmedia.big_finish": return Colors.red;
      case "com.spotify.music": return Colors.green;
      default: return Colors.purpleAccent;
    }
  }
}
