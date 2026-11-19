# Live Interpretation: iPhone smoke test

Use a physical iPhone and the same locale and audio route as your normal VTM setup. For LiveContainer, test using an existing JIT-less setup first. A successful Xcode build verifies compilation and packaging, not audio permissions, inference latency, or LiveContainer compatibility.

1. Download a Whisper model from **Settings → Model Management**. Open **Live Interpretation**, choose Chinese → English, and allow the microphone only after tapping Start.
2. Speak three short sentences with pauses. Each should appear in sequence as source text and then translation. Switch the phone offline once the translation models are cached; repeat with a previously prepared language pair. For an uncached pair, expect model preparation or an understandable failure, not a cloud translation request.
3. Speak quietly, then leave several seconds of silence, then speak a longer sentence. Check for dropped words, unwanted silent transcription, duplicate history, and whether the UI stays responsive.
4. Stop explicitly, switch to a different tab, and repeat with the Home gesture and with an audio interruption. In all cases expect listening to stop and not restart automatically. Return to the original Translate tab and confirm push-to-talk still works.
5. Return to Live Interpretation and relaunch the app. Verify that finalized history persists locally, that Clear History requires an explicit confirmation, and that a language change affects only the new session.
6. If comparing another model on the same phone, hold input, language pair, and audio route constant. Record time to the first text, time to the final translation, visible accuracy, and any interruptions or thermal slowing. Keep model-download and first-run load time separate from the steady-state measurements.
