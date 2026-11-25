# Compress REA

一个免费、MIT 开源的 macOS 视频 / 音频压缩与格式转换工具。把文件拖进窗口，选好格式和参数，一键导出。所有处理都在你的 Mac 本机完成，不联网，也不需要另装 FFmpeg、Homebrew 或 Java。

## 下载与使用

从 [GitHub Releases](https://github.com/Sad-Salad-12/compress-rea/releases/latest) 下载 `CompressREA-v1.0.0-macOS-arm64.zip`，解压后把「Compress REA.app」拖进「应用程序」。

1. 把视频或音频拖进窗口，或点 **Add Files**。
2. 选择导出文件夹（默认是「下载」）和输出格式。
3. 在 **Video / Audio / Tools** 里调整参数。
4. 点 **Export Selected Files**；勾选 **Merge selected files** 可按队列顺序把多个文件合并成一个。

原文件永远不会被改动或覆盖，重复导出会自动编号（`-compressed-1`、`-compressed-2`…）。文件不一定会变小：体积取决于原文件和设置，想压得更小就降低码率或分辨率。

### 首次打开的安全提示

下载版只有本地 ad-hoc 签名，没有付费开发者签名或 Apple 公证，所以 macOS 可能阻止首次启动。

仅在确认下载来自本仓库、文件未被篡改且你信任源码时，在尝试打开后前往「系统设置 → 隐私与安全性」，为此 App 选择「仍要打开」。请参考 [Apple 的安全说明](https://support.apple.com/en-us/102445)。不要关闭全局 Gatekeeper 或系统完整性保护。每个 Release 都附有 SHA-256 校验值。

## 功能

- **视频输出**：MP4、MOV、MKV、AVI。编码器 H.264、H.265 / HEVC（Apple VideoToolbox 硬件加速）、MPEG-4。HEVC 需要 MP4、MOV 或 MKV。
- **音频输出 / 提取**：M4A (AAC)、MP3、WAV、FLAC、AIFF、OGG (Vorbis，立体声)。
- **批量队列**：媒体信息、播放预览、逐个文件进度、取消、导出后在 Finder 中显示，并显示压缩了百分之多少。
- **参数**：分辨率预设（480p / 720p / 1080p / 4K）或自定义尺寸、帧率、视频 / 音频码率、采样率、声道、音量。
- **工具**：剪切时间段、裁边、旋转、翻转、图片水印、合并。可选「补黑边到精确分辨率」，保持画面比例。
- 没有付费、订阅、激活、试用限制或强制水印。水印只在你自己选了图片时才会加。

## 限制

- 只导出第一条视频轨和第一条音频轨；字幕和其他音轨不会复制。
- HDR 色彩处理未经验证。
- 预览使用 macOS 自带的播放支持；macOS 无法预览的文件，引擎仍可能可以转换。
- 仅支持 Apple Silicon Mac，macOS 14 或更新版本。目前在 macOS 27.2 上测试。

## 从源码构建

需要 Xcode Command Line Tools（`xcode-select --install`）。

```bash
git clone https://github.com/Sad-Salad-12/compress-rea.git
```

```bash
cd compress-rea
```

App 需要 `Engine/` 里有 `ffmpeg` 和 `ffprobe`，两种方式任选其一：

**A. 直接用 Release 里的引擎**（已安装 Release 版 App 时）：

```bash
cp "/Applications/Compress REA.app/Contents/Resources/"{ffmpeg,ffprobe} Engine/
```

**B. 从官方源码自己编译 FFmpeg + LAME**（下载约 16 MB 源码，编译约 10 分钟）：

```bash
./Engine-Sources/fetch-sources.sh
```

```bash
./Engine-Sources/rebuild-engine.sh
```

然后构建 App 并运行冒烟测试：

```bash
./Build.command
```

```bash
./Tests/run-tests.sh
```

`Build.command` 会在仓库根目录生成「Compress REA.app」（ad-hoc 签名）。`run-tests.sh` 会现场生成测试媒体，跑 29 项引擎和队列检查，输出都放在 `Tests/.build/`。

## 项目结构

| 路径 | 内容 |
| --- | --- |
| `Source/App.swift` | SwiftUI 界面和导出队列 |
| `Source/MediaEngine.swift` | 读取媒体信息、生成 FFmpeg 参数、校验设置 |
| `Source/ProcessRunner.swift` | 运行 FFmpeg、解析进度、取消 |
| `Source/MakeIcon.swift` | 生成 App 图标 |
| `Tests/` | 引擎和队列冒烟测试，以及 `run-tests.sh` |
| `Engine-Sources/` | 引擎源码下载、校验和重新编译脚本，来源说明 |
| `Licenses/` | FFmpeg、LAME、pkgconf 的许可证和第三方声明 |

FFmpeg 始终以独立进程运行，参数以数组传入，不经过 shell。导出先写入临时的 `.partial` 文件，校验通过后才改成最终文件名。

## License

App 源码使用 [MIT](LICENSE) 许可，Copyright © 2026 Sad-Salad-12。

App 内置的 FFmpeg 9.0.2 和 LAME 4.0 以 LGPL 2.1 或更新版本授权（编译时未启用 GPL 或 nonfree 选项），详见 [Licenses/THIRD-PARTY-NOTICES.md](Licenses/THIRD-PARTY-NOTICES.md)。对应的完整源码包附在每个 Release 里，也可以用 `Engine-Sources/fetch-sources.sh` 从官方站点下载。

## English summary

A free, MIT-licensed macOS app for compressing and converting video and audio. Drag files in, pick a format and settings, export. Everything runs locally, and FFmpeg comes bundled.

- **Video:** MP4, MOV, MKV, AVI with H.264 / HEVC (VideoToolbox hardware encoding) or MPEG-4.
- **Audio:** M4A (AAC), MP3, WAV, FLAC, AIFF, OGG (Vorbis).
- **Tools:** batch queue, preview, resolution / bitrate / frame-rate / sample-rate / channel / volume controls, trim, crop, rotate, flip, image watermark, merge.
- Originals are never modified, and repeat exports get numbered names. No payments, subscriptions, trials, or forced watermarks.
- **Requirements:** Apple Silicon, macOS 14+. The download is ad-hoc signed and **not Apple-notarized**; check the release checksum and source before opening it.
- **Build from source:** get `Engine/ffmpeg` + `Engine/ffprobe` (copy them from the release app, or run `Engine-Sources/fetch-sources.sh` then `rebuild-engine.sh`), then run `./Build.command` and `./Tests/run-tests.sh`.
- **License:** MIT for the app source. The bundled FFmpeg and LAME are LGPL-2.1-or-later; their exact source archives are attached to every release.
