# How To Use

!!!primary
**CorridorKey by LateNite** is currently in a **public beta testing phase**. 👷

We're just using a placeholder icon for now (taken from [VFX Toolbox](https://vfxtoolbox.fcp.cafe)).
!!!

## Standalone Editor

Run **CorridorKey by LateNite** from your `/Applications` folder.

Click **Open Standalone Editor**.

![](/static/wrapper-app.png)

Choose **Import Media…** or drop a video or still image into the editor. Still-image formats include PNG, TIFF, JPEG, and HEIC. Images open at their original pixel resolution with embedded orientation applied. Files containing multiple images use the primary image.

![](/static/standalone-editor.png)

First pick your:

- **Quality** defaults to **Recommended**, which chooses a model resolution for your source and Mac.
- **Screen Colour** defaults to **Auto**.
- **Upscale Method** defaults to **Lanczos**.
- **Generated Hint** defaults to **None**, letting CorridorKey v2 identify the subject. **Chroma**, **Apple Vision**, and **Apple Vision + Manual Points** provide optional guidance.
- **Time Awareness** defaults to **Off**. Each frame is keyed immediately during analysis. Enabling it adds a preparation pass and combines surrounding frames.

**Reduce Edge Flicker**, **Light Wrap**, and **Auto Despeckle** are off by default so the initial result preserves the model's detail. Reduce Edge Flicker is an additional smoothing pass; it can soften edges or introduce trails. Try Time Awareness first when a shot flickers. Saved effects retain their explicit settings.

Then press **Analyse Clip**:

![](/static/standalone-editor-result.png)

Once you're happy to you can export your result as ProRes or HEVC (with alpha):

For a still image, use the same **Analyse Clip** button and keying controls, then choose **Export…** to save a 16-bit PNG or TIFF with transparency. The export uses the current **Output** setting and excludes the preview backdrop. Stills display their pixel dimensions instead of playback controls.

![](/static/standalone-export.png)

### Playback

Press **Space** to play or pause, and **Left Arrow** or **Right Arrow** to step one frame. The first-frame and last-frame buttons pause playback and jump to the corresponding source sample. The FPS display shows achieved playback speed followed by the source rate, for example `23fps (25fps)`. Source resolution and frame rate also appear below Cached mattes in the inspector.

### Batch export

Choose **Batch Import…** beside **Import…**, or drop/import multiple videos. Add or remove shots in the queue, choose a codec and an output folder, then choose **Export Shots**. Each shot is analysed and exported in turn using the current keying settings. Shot-specific manual points and Alpha Hint files are excluded; Apple Vision + Manual Points uses Apple Vision for the batch.

Output names end in `(Keyed)`, with numbered suffixes when needed. Existing files are preserved. A failed shot shows its error and the queue continues. **Stop Batch** cancels pending work; starting again retries unfinished shots and keeps completed exports.

### Hints and undo

**Generated Hint** creates an optional guide from the source. **Alpha Hint** imports a black-and-white image, video, or image sequence: white keeps foreground, black removes background. Enable **Use Alpha Hint** to use that file instead of generated hints and manual points. **Single Frame** needs Time Awareness to propagate an image through a video; **All Frames** supplies a matching mask for every frame. Start with **Alpha Hint Strength** at 0.75.

In **Subject Hints**, choose **Mark Foreground** to select a detected Vision subject; mark additional subjects to keep them too. **Mark Background** removes a small area. **Mark Ignore** (red cross) excludes the detected object under the point, or removes a small area if Vision did not detect an object there. Ignore takes precedence over Foreground on the same object. Adding a point switches to **Apple Vision + Manual Points**. **Erase Nearest Hint** removes a point. Points belong to the displayed frame and do not track; unmarked frames use the Vision matte. View **Alpha Hint (Diagnostic)** to inspect the guide, then choose **Analyse Clip** to update the key. These are model hints, so always review the resulting matte.

**Undo** and **Redo** restore keying settings, manual points, and their associated analysis results. A slider drag is one undo step. Output adjustments reuse the current analysis; changing model inputs requires analysis again, and Undo restores the previous results.


---

## Final Cut Pro

Run **CorridorKey by LateNite** from your `/Applications` folder.

It will look like this:

![](/static/wrapper-app.png)

**CorridorKey by LateNite** will automatically install the Motion Template in this folder:

```
/Users/YOUR-USER-NAME/Movies/Motion Templates.localized/Effects.localized/CorridorKey by LateNite
```

Click the **Open Final Cut Pro** button to launch Final Cut Pro.

You can then apply the **CorridorKey by LateNite** effect to your clips from the **Effects Browser:**

![](/static/effects-browser.png)

First pick your:

- **Quality** defaults to **Recommended**, which chooses a model resolution for your source and Mac.
- **Screen Colour** defaults to **Auto**.
- **Upscale Method** defaults to **Lanczos**.
- **Generated Hint** defaults to **None**, letting CorridorKey v2 identify the subject. **Chroma**, **Apple Vision**, and **Apple Vision + Manual Points** provide optional guidance.
- **Time Awareness** defaults to **Off**. Each frame is keyed immediately during analysis. Enabling it adds a preparation pass and combines surrounding frames.

**Reduce Edge Flicker**, **Light Wrap**, and **Auto Despeckle** are off by default so the initial result preserves the model's detail. Reduce Edge Flicker is an additional smoothing pass; it can soften edges or introduce trails. Try Time Awareness first when a shot flickers. Saved effects retain their explicit settings.

Then press **Analyse Clip**:

![](/static/default-effect.png)

You'll see a progress bar:

![](/static/progress-bar.png)

Then once done, you'll see it's complete:

![](/static/complete.png)

You can now adjust the other properties as you want to get best results.

Setting the **Output** to **Matte Only** can be helpful initially to get suitable values:

![](/static/matte-only.png)

You can then tweak all the parameters until you get a result you're happy with:

![](/static/result.png)
