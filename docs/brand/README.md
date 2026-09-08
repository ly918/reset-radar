# Reset Radar Logo

以金灿灿的拟物 RESET 按钮为主体：拉丝金属、高光倒角、立体侧壁、深灰底座与清晰的 RESET 刻字。

- `logo.png`：由内置 image_gen 工具生成的最终位图，用于 README 和图标打包。
- `apps/macos/Resources/AppIcon.icns`：完整 macOS 图标尺寸集。
- `prompt.md`：生成方式与提示词记录。

图标打包不重新生成图像，只转换尺寸与格式：`./scripts/package-icon.sh`。它仅需要 macOS 自带的 sips 和 iconutil；普通应用构建直接使用已提交的 icns 文件。

项目资产随 MIT 许可提供；第三方商标不在授权范围内。
