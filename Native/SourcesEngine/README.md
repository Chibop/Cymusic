# Native sources

Build the four Swift files and `Runtime/CyMusicUserApiRuntime.m` in the app target with ARC. With `Native` as the project root set `SWIFT_OBJC_BRIDGING_HEADER` to `SourcesEngine/Runtime/CyMusicUserApiRuntime.h` or import that header from the app's existing bridge. Link JavaScriptCore and Security. CommonCrypto is supplied by the SDK. Copy `Runtime/user-api-preload.js` to the bundle root using Copy Bundle Resources. Exclude `verify-engine.sh` and this document from the app bundle.

Provide `SourceEngine`, `Playback` and `Library` environment objects and embed the screens in the host's NavigationStack. `SearchScreen(onSavePlaylist:)` accepts an optional `(String, [Song]) -> Void` callback. `SourceEngine.importScript(_:name:)` validates, persists and selects a script. Failed imports preserve the previous selection. Returned playback URLs remain transient.

QQ search, the hot-song chart, and public playlists use anonymous catalog requests. Playlist input accepts IDs and QQ URLs containing an ID. Availability and track counts depend on the service. Playback of QQ songs requires a compatible provider. Apple search returns preview clips. CommonJS supports the upstream positional `getMusicUrl` contract and a basic scoped `fetch` implementation. Browser DOM, Node modules, and multipart uploads are outside this host's implementation. LX utilities use the bundled upstream preload.

Run `bash Native/SourcesEngine/verify-engine.sh` from the repository root for fixture-based JavaScriptCore resolution and persistence checks. Append `--live` to print current public catalog responses.
