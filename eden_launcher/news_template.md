TEMPLATE NOTES (delete everything above the first line of "## " when you copy this into news.md)

- One `## Heading` = one card in the launcher. The heading is the card title. Put NEWEST entries FIRST in news.md.
- The card shows only the first few lines of the entry, so open with a one or two sentence summary.
- DETAILS opens the whole entry in the viewer, and that is where images show.
- Images: put the file in ExportedGames\release\news\ and reference it as `news/name.png`.
- Not supported in the viewer: embedded HTML, video, custom fonts or colors.
- Easiest way to publish: `post_news.ps1 -Title "..." -Notes "..."`, or paste an entry into news.md and run `post_news.ps1 -UploadOnly`.

---

## 0.1.3 (2026-10-05)
One or two sentence summary that fits on the launcher card. **This is what players read first.**

![Banner image, shown full width in the viewer](news/banner.png)

### Highlights
- **New:** rivers now carve proper valleys
- **Improved:** forests are denser and load faster
- **Fixed:** the camera no longer clips through cliffs
  - nested bullet, one level down
  - another nested bullet

### Known issues
1. Ordered lists work too
2. Second item
3. Third item

- [x] Task list item that is done
- [ ] Task list item still to do

### Text styles
Plain text, **bold**, *italic*, ***bold italic***, ~~strikethrough~~, and `inline code` for key names such as `F3`.

> A quote block, good for a developer note or a warning.
> Alpha build, expect bugs.

### Controls
| Key | Action |
|-----|--------|
| `W A S D` | Move |
| `F3` | Debug overlay |
| `Esc` | Menu |

### Code or settings
```
fov = 90
render_scale = 0.8
```

### Links
Read more on [the wiki](https://example.com) or just paste a bare link: https://example.com

---

### Second image, mid-entry
![Caption text goes here](news/another_screenshot.jpg)

A horizontal rule (the `---` lines) separates sections inside an entry.
