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

- **Quality** (it defaults to **Recommended**)
- Screen Colour (it defaults to **Green**)
- Upscale Method (it defaults to **Lanczos**)
- If you want to use Apple's Vision Framework to do the hint tick **Auto Subject Hint**
- Alternatively, you can use **Show Subject Marker** to manually select the foreground object in your Viewer

Then press **Analyse Clip**:

![](/static/standalone-editor-result.png)

Once you're happy to you can export your result as ProRes or HEVC (with alpha):

For a still image, use the same **Analyse Clip** button and keying controls, then choose **Export…** to save a 16-bit PNG or TIFF with transparency. The export uses the current **Output** setting and excludes the preview backdrop. Stills display their pixel dimensions instead of playback controls.

![](/static/standalone-export.png)

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

- **Quality** (it defaults to **Recommended**)
- Screen Colour (it defaults to **Green**)
- Upscale Method (it defaults to **Lanczos**)
- If you want to use Apple's Vision Framework to do the hint tick **Auto Subject Hint**
- Alternatively, you can use **Show Subject Marker** to manually select the foreground object in your Viewer

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
