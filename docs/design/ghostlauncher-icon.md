# Ghost Launcher 图标

使用内置 imagegen 生成，参考 `/Applications/Ghost Nexus.app/Contents/Resources/AppIcon.icns`。圆角图标外部保留透明通道，使用系统 `sips` 缩放为 macOS 的 16、32、64、128、256、512、1024 像素尺寸。

最终图标：[`app_icon_1024.png`](../../launcher/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png)。

生成提示词：

```text
Use case: logo-brand
Asset type: production macOS application icon for GhostLauncher, square 1024 by 1024 image.
Primary request: Create a new companion icon closely inspired by the provided Ghost Nexus reference icon. Keep the same recognizable friendly white ghost silhouette, two tall dark oval eyes, flat clean shapes and restrained midnight navy to deep violet background. Distinguish the launcher app by replacing the reference's connected network nodes inside the lower ghost body with a single bold, minimal upward launch-arrow emblem, colored cyan with a violet accent. The launch arrow should feel integrated into the ghost, simple enough to read at 32 pixels. Keep the ghost as the dominant subject, with a balanced centered front-facing composition and generous breathing room.
Input images: Image 1 is a style and brand reference only, not an edit target.
Scene/backdrop: A macOS rounded-square tile with smooth navy to deep violet gradient and crisp rounded corners. Actual transparent alpha outside the tile, no white canvas or checkerboard baked in.
Style/medium: polished minimal flat vector-like raster icon, smooth anti-aliased edges, no outlines, no 3D bevels, no complex textures.
Text: none.
Constraints: one icon only, no wordmark, no letters, no watermark, no mockup, no extra ghost characters. Preserve the clear white ghost and cyan/violet family resemblance while changing the lower emblem to represent launching.
```

