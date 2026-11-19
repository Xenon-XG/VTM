# WebRTC voice activity detector

The small C detector is the WebRTC VAD subset distributed by
[py-webrtcvad](https://github.com/wiseman/py-webrtcvad/tree/e283ca41df3a84b0e87fb1f5cb9b21580a286b09/cbits/webrtc),
pinned to commit `e283ca41df3a84b0e87fb1f5cb9b21580a286b09`.
This does not include the Python binding, any networking or media stack, a
model file, or a remote service. The app compiles it in as source, so build and
runtime need no network access for VAD.

The license and standard WebRTC patent grant are bundled as
`VTM/Resources/WebRTCVAD-Notice.txt`. Local changes: skip the unrelated
`dot_product_with_scale.cc` (not built by py-webrtcvad either), add a guard for
allocation failure in `webrtc_vad.c`, and provide the small `VTMLiveVAD` bridge.
The header search path is this directory; on POSIX builds use `WEBRTC_POSIX=1`
for the once-only initialization guard. No architecture-specific cores or
runtime code generation are enabled.

Run `bash scripts/check_webrtc_vad.sh` on macOS or Linux to compile and link the
native source and check the bridge at 16 kHz.
