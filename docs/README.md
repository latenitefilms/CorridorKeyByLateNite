# CorridorKey by LateNite

**CorridorKey by LateNite** brings [Corridor Digital's](https://www.corridordigital.com) [CorridorKey](https://github.com/nikopueringer/CorridorKey) to Final Cut Pro. 🥳

!!!success
Download for **free** on the [Mac App Store](/download) and find the source code on [GitHub](https://github.com/latenitefilms/CorridorKeyByLateNite)!
!!!

This is **NOT** a fork. We've taken the blue and green CorridorKey models, converted them to MLX and built a completely new Swift & Swift UI engine powered by modern Apple frameworks. 🔥

Whilst there are already some great fork's of CorridorKey, such as [EZ-CorridorKey](https://github.com/edenaion/EZ-CorridorKey), none of them are purposely build for **Mac & Apple Silicon**.

**CorridorKey by LateNite** brings an Effect directly into **Final Cut Pro**, as well as a **Standalone Editor**.

Optimised for **ProRes** in and out with hardware decoding and encoding. 🏎️

---

## Built for Final Cut Pro

**CorridorKey by LateNite** has been built for **Final Cut Pro** editors.

It gives you all the power of CorridorKey, directly in your Final Cut Pro timeline.

![Footage courtesy of Corridor Digital's Benchmark Test Footage](/static/corridor-key-build-4.png)

---

## Standalone Editor

**CorridorKey by LateNite** has been built for **Apple Silicon Mac's**.

It makes full use of the GPU, Neural Engine, Metal and MPX - pushing the hardware to the max. 🔥

If you're working with ProRes or HEVC, it makes use of Apple Silicon's hardware encoders and decoders.

It uses Apple's [Vision Framework](https://developer.apple.com/documentation/vision) to use machine learning to "cut out" any foreground people, to use as a "hint" for CorridorKey.

![Footage courtesy of Corridor Digital's Benchmark Test Footage](/static/corridor-key-standalone.png)

---

## Manual Hint

Foreground and background points adjust a small, soft-edged area of the coarse mask supplied to CorridorKey. Foreground points are not an outline or a selection: objects outside those points can still appear in the matte. A background point influences the area around it, rather than selecting an entire object for removal. Use the **Hint** output to inspect the mask the model receives.

New points belong to the frame where you place them. Pause on a frame, add foreground or background hints, then move to another frame to add a separate set. Choose **Analyse Clip** after editing. Changing hints invalidates the previous analysis in both the Standalone Editor and Final Cut Pro.

Frames without points use the automatic chroma hint. CorridorKey processes each frame independently; these points do not train the model, track the subject or propagate a correction through the clip. Temporal Stability smooths the resulting mattes and is not a tracking system.

In the Standalone Editor, use the **Subject Hints** menu. In Final Cut Pro, click the viewer for foreground, Shift-click for background, and Option-click to erase a nearby hint. Both hosts offer **Clear Hints on This Frame** and **Clear All Hints**.

Hints saved by older versions have no frame information and retain their original clip-wide behaviour. Clear and replace them to use frame-specific hints. Existing analysis must be rebuilt once after this update.

---

## Edge Decontaminate

**Edge Decontaminate** reduces residual green or blue spill in partially transparent edges, using the selected **Screen Colour**. It removes only excess of that colour, preserving neutral edges and opaque interiors.

The control is off by default in the Standalone Editor and Final Cut Pro. Enable it when an edge still contains screen spill; naturally green or blue details may also be affected. Existing saved settings retain their chosen value.

---

## What is CorridorKey?

[CorridorKey](https://github.com/nikopueringer/CorridorKey) is an open source project created by the talented [Corridor Digital](https://www.corridordigital.com) team.

You can learn more about CorridorKey on their official [GitHub](https://github.com/nikopueringer/CorridorKey).

You can also watch these amazing videos that explain the history of CorridorKey:

https://www.youtube.com/watch?v=3Ploi723hg4

https://www.youtube.com/watch?v=Y3Dfw969itU

https://www.youtube.com/watch?v=MR0vQjr-Avc
