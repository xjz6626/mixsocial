# Mixsocial 品牌图标

`mixsocial-icon-master.png` 是 Android 图标与启动页资源的主图。各密度 PNG 由该文件
缩放生成，不要直接编辑生成后的 `mipmap-*` 文件。

主图通过 Codex 内置 `imagegen` 生成。最终使用的提示词如下：

```text
Use case: precise-object-edit
Asset type: final Android launcher icon master artwork
Input images: Image 1 is the edit target
Primary request: preserve the exact overall two-interlocking-speech-bubbles composition, but make it a production-clean flat launcher icon
Change only: replace every transparent or black background area with one fully opaque, full-bleed solid deep indigo #4263EB; replace the white bubble shapes with pure flat white #FFFFFF; replace the center accent with pure flat coral #FF5C7A; clean every edge into crisp smooth vector-like curves
Composition/framing: keep the mark centered and safely inside the central 66 percent of the square canvas
Constraints: final canvas must be fully opaque; exactly three flat colors; no alpha transparency; no black; no gray; no gradient; no shadow; no glow; no texture; no speckles; no edge noise; no text; no watermark; keep the simple strong silhouette
```

设计意图：两枚互联的对话气泡代表跨来源内容，中间的珊瑚色交集代表聚合阅读；整体轮廓
也隐约形成 Mixsocial 的首字母 `m`。
