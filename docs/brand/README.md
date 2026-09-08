# Reset Radar Logo

原创图形：以可按下的 RESET 按钮为主体，金色键面、较深的前沿和石墨灰底座体现按键层次。按键上的回转符号与自绘 RESET 字样表达重置，暖金色对应应用中 12h 概率的重点色。

- `logo.svg`：可编辑矢量版本。
- `logo.png`：1024×1024 透明外边距版本，用于 README。
- `apps/macos/Resources/AppIcon.icns`：完整 macOS 图标尺寸集。

采用项目 MIT 许可。重新生成需 Python 3 + Pillow，以及 macOS 自带的 iconutil：`python3 scripts/generate-logo.py`。普通构建直接使用已提交的图标，不要求 Pillow。
