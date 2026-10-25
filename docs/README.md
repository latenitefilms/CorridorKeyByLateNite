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

## Apple Vision + Manual Points

Apple Vision supplies the starting matte. Foreground points select detected subjects; mark each subject you want to retain. Background points correct small, soft-edged areas. Ignore points (red crosses) exclude a detected object, with a local correction when no instance is detected. Ignore takes precedence if the same instance is also marked Foreground. Vision must distinguish objects as separate instances to select them independently.

New points belong to the frame where you place them. Unmarked frames use the Vision matte. Points do not track or propagate through the clip. Use **Alpha Hint (Diagnostic)** to inspect the guide and choose **Analyse Clip** after editing. The points guide CorridorKey's prediction; review the final matte. Changing points invalidates the previous analysis in both hosts.

In the Standalone Editor, use **Subject Hints**. In Final Cut Pro, click for foreground, Shift-click for background, Command-click for Ignore, and Option-click to erase a nearby point. Both hosts offer **Clear Hints on This Frame** and **Clear All Hints**.

Hints saved by older versions retain their frame scope, including clip-wide points without frame information. Clear and replace those points to use frame-specific hints. Existing analysis must be rebuilt after this update. Generated Hint starts with **None**, while saved selections retain their original values.

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
