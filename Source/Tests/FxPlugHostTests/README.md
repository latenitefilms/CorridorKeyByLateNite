# Manual hint host regression

Run `bash Source/Tests/FxPlugHostTests/run.sh` on Apple Silicon with Xcode and the FxPlug SDK installed.

The harness compiles the production OSC, parameter storage and hint models. A local host supplies transactions to the installed FxPlug framework's real custom-parameter decoder and encoder. It does not launch Final Cut Pro, read libraries or draw GPU overlays.

The first two “Unable to unarchive” messages are intentional: the negative control recreates a session without `classesForCustomParameterID:`. The same archive must then decode through the production OSC. Subsequent checks exercise click routing, every explicit tool, frame boundaries, external-mask gating, failed-read preservation and a new OSC session.

Private framework declarations appear only in this test harness. Production code continues to use public FxPlug APIs. GPU rendering, host coordinate transforms and live Final Cut Pro event delivery require a separate integration check.
