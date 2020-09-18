# Changelog

## 1.0.1
- Meet need to know status of permissions on Android at start up, with breaking change:
  - change `start` method return type from `void` to `Future<void>`

## 0.1.4
- fix bug with image resolution, whereby existing image was discarded

## 0.1.3
- improved image resolution algorithm

## 0.1.2
- deal with shonky iOS now playing information, which variously returns
  images and persistent IDs as empty or zero
- improve in-code documentation

## 0.1.1
- remove unnecessary imports and ChangeNotifier

## 0.1.0
- initial release
- stream of now playing tracks
- optional resolution of missing album art

# SemVer use
- patch:
  - bugfix, tweak or typo
- minor:
  - non-breaking change
- major:
  - breaking change