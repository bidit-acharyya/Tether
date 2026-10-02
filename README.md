# Tether

A Swift package that stores app data locally on raw SQLite, lets iPhone and Mac edit offline, and merges every change deterministically when they reconnect, even when the devices run different versions of the app.

## Definition of done

A Mac on v1 and an iPhone on v2, both offline, edit the same list, reconnect, and converge with nothing lost, including the v2-only fields the Mac can't display. Then the Mac upgrades and those fields appear. All of it in a 60-second video, and every claim in this README backed by a test or a benchmark.

## Requirements

- Swift 6.1 (Xcode 16.3), Swift 6 language mode, zero warnings
- iOS 17, macOS 14, watchOS 10
- System SQLite, tested against 3.43.2 (macOS 15)
