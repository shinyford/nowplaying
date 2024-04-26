import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nowplaying/nowplaying.dart';
import 'package:nowplaying/nowplaying_track.dart';
import 'package:provider/provider.dart';

void main() async {
  await NowPlaying.instance.start(
    resolveImages: true,
    spotifyClientId: 'xxxx',
    spotifyClientSecret: 'xxxx',
  );
  runApp(NowPlayingExample());
}

class NowPlayingExample extends StatelessWidget {
  const NowPlayingExample({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('NowPlaying example app')),
        body: Center(child: NowPlayingTrackWidget()),
      ),
    );
  }
}

class NowPlayingTrackWidget extends StatefulWidget {
  @override
  _NowPlayingTrackState createState() => _NowPlayingTrackState();
}

class _NowPlayingTrackState extends State<NowPlayingTrackWidget> {
  @override
  void initState() {
    super.initState();
    NowPlaying.instance.isEnabled().then((isEnabled) async {
      if (!isEnabled) {
        final shown = await NowPlaying.instance.requestPermissions();
        print('MANAGED TO SHOW PERMS PAGE: $shown');
      }

      if (NowPlaying.spotify.isEnabled && NowPlaying.spotify.isUnconnected) {
        NowPlaying.spotify.signIn(context);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return StreamProvider<NowPlayingTrack>.value(
      initialData: NowPlayingTrack.loading,
      value: NowPlaying.instance.stream,
      child: Consumer<NowPlayingTrack>(
        builder: (context, track, _) {
          // if (track == NowPlayingTrack.loading) return Container();
          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (track.isStopped) Text('nothing playing'),
              if (!track.isStopped) ...[
                if (track.title != null) Text(track.title!.trim()),
                if (track.artist != null) Text(track.artist!.trim()),
                if (track.album != null) Text(track.album!.trim()),
                Text(_timeStr(track.duration)),
                TrackProgressIndicator(track),
                Text(track.state.toString()),
                Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      margin: const EdgeInsets.fromLTRB(8, 8, 8, 16),
                      width: 200,
                      height: 200,
                      alignment: Alignment.center,
                      color: Colors.grey,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 350),
                        child: _imageFrom(track),
                      ),
                    ),
                    Positioned(bottom: 0, right: 0, child: _iconFrom(track)),
                    Positioned(
                        bottom: 0, left: 8, child: Text(track.source!.trim())),
                  ],
                ),
              ]
            ],
          );
        },
      ),
    );
  }

  Widget _imageFrom(NowPlayingTrack track) {
    if (track.hasImage)
      return Image(
        key: Key(track.id),
        image: track.image!,
        width: 200,
        height: 200,
        fit: BoxFit.contain,
      );

    if (track.isResolvingImage) {
      return SizedBox(
        width: 50.0,
        height: 50.0,
        child: CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(Colors.white)),
      );
    }

    return Text('NO\nARTWORK\nFOUND',
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 24, color: Colors.white));
  }

  Widget _iconFrom(NowPlayingTrack track) {
    if (track.hasIcon)
      return Container(
        padding: const EdgeInsets.all(6),
        decoration: const BoxDecoration(
            color: Colors.white,
            boxShadow: [const BoxShadow(blurRadius: 5, color: Colors.black)],
            shape: BoxShape.circle),
        child: Image(
          image: track.icon!,
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
      case "com.apple.music":
        return Colors.blue;
      case "com.hughesmedia.big_finish":
        return Colors.red;
      case "com.spotify.music":
        return Colors.green;
      default:
        return Colors.purpleAccent;
    }
  }
}

class TrackProgressIndicator extends StatefulWidget {
  final NowPlayingTrack track;

  TrackProgressIndicator(this.track);

  @override
  _TrackProgressIndicatorState createState() => _TrackProgressIndicatorState();
}

class _TrackProgressIndicatorState extends State<TrackProgressIndicator> {
  late Timer _timer;

  @override
  void initState() {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    super.initState();
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = widget.track.progress;
    final countdown =
        widget.track.duration - progress + const Duration(seconds: 1);
    return Column(
      children: [
        Text(_timeStr(progress)),
        Text(_timeStr(countdown)),
      ],
    );
  }
}

String _timeStr(Duration duration) {
  final seconds = duration.inSeconds;
  final hours = seconds ~/ 3600;
  final mins = (seconds % 3600) ~/ 60;
  final secs = seconds % 60;
  return "$hours:${mins < 10 ? "0$mins" : mins}:${secs < 10 ? "0$secs" : secs}";
}
