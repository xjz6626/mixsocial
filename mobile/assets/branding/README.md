# Mixsocial 品牌图标

`mixsocial-icon-master.png` 是带浅色底的 Android 图标主图，
`mixsocial-icon-foreground.png` 是自适应图标与启动页使用的透明前景。各密度 PNG
由这两个文件缩放生成，不要直接编辑生成后的 `mipmap-*` 文件。

主图通过 Codex 内置 `imagegen` 生成。最终使用的提示词如下：

```text
Use case: logo-brand
Asset type: Android adaptive launcher icon foreground for Mixsocial
Primary request: three interlocking speech-bubble ribbons subtly forming a rounded m and representing three social platforms flowing together
Style/medium: minimal geometric Material-style logo with a strong silhouette
Composition/framing: centered inside the adaptive-icon safe zone with generous transparent padding
Color palette: coral red #E9274F, warm orange #E06A2B, vivid blue #1769E0, with clean white separators
Constraints: transparent background; no text; no platform trademarks; no watermark
```

生成稿经纯色映射和孤立像素清理后输出为主图，以保证 48px 下仍有清晰边缘。

设计意图：三枚相连的对话气泡对应三个内容来源，整体轮廓隐约形成 Mixsocial 的首字母
`m`；红、橙、蓝也与应用内来源角标保持一致。
