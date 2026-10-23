# NoNetChat Apple native compilation fixture

This source-only repository contains the allowlisted Swift components and a
disposable Xcode/Flutter compilation harness. It has independent Git history.
It contains no NoNetChat Dart code, user data, signing material or app assets.

CI executes the shared native ownership checks, then compiles the actual Swift
sources against iOS 26+ and macOS SDKs, including
the gated WiFiAware code. It generates a trivial Flutter demo, NOT NoNetChat.
There is no app publication and no Windows build. No secrets are required.
These builds do not validate radios, provisioning, the full NoNetChat app or UX.
The disposable demo resolves flutter_webrtc 1.6.2+hotfix.4. Native source-identity
checks also link the exact WebRTC 150.7871.01 macOS framework (archive and image
hashes pinned here) and check its runtime bundle. They use receive-only peers
without SDP, a microphone, a renderer, a file or network traffic; this does not
prove received audio or recording. No application pub cache is modified.
Paired WiFiAware remains disabled pending device and provisioning validation.

SOURCE.json records the source revision and each public file's SHA-256.
The included Apple sample notice applies to the adapted pairing UI.
