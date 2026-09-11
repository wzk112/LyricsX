# LyricsX

> 面向 macOS 26/27 的原生 Swift 歌词播放器。保留 LyricsX 的菜单栏、搜索、导入导出和播放器控制，同时重做播放同步、缓存、悬浮窗和设置界面。

<p>
  <img src="docs/img/icon.png" width="128" alt="LyricsX 图标">
</p>

## 功能

- 支持 Apple Music、Spotify，以及 MediaRemote 能识别的其他播放器。
- Apple Music 读取当前歌曲、封面、播放进度和内嵌歌词；Spotify 和系统媒体通知提供封面回退。
- 同时搜索 LRCLIB、网易云音乐、QQ 音乐、酷狗和 Musixmatch，并支持来源排序；自动搜索补查歌名关键词、跨语言别名、副标题与 `feat.` 等写法，再选择最佳版本，搜索结果标记逐字与双语版本。
- “双语优先”“逐字优先”和“严格匹配”开关：核对歌名和歌手，时长只作辅助参考；关闭严格匹配后可选用歌手信息不完整但标题可信的同步歌词。歌词提前结束不会导致准确的歌名、歌手匹配被拒绝。
- 原生液态玻璃悬浮窗：锁定、解锁、点击穿透、鼠标悬停显示、隐藏和自由拖动。
- 悬浮窗位置、大小、字号、透明度、翻译和下一句显示方式会被保存；无可显示歌词或纯音乐时使用紧凑的封面、歌名和歌手卡片。
- Apple Music 风格的歌词切换、模糊淡入淡出、逐字高亮和响应式布局。
- 暂停、跳转和切歌时会保留有效播放状态；单次播放器读取失败不会闪出“未识别到播放源”提示。
- 菜单栏播放控制、歌词偏移、搜索、重新搜索、Finder 定位、错误歌词停用、资料库和 Apple Music 写入。
- “设置 → 通用”可分别隐藏 Dock 图标、菜单栏图标和菜单栏歌词；隐藏后仍能使用 ⌥⌘O 打开主窗口。
- 联网搜索结果默认保存为 `.lrcx`，保留逐字时间和来源附加信息；仍可导入、读取 `.lrc` 和纯文本歌词。

## 歌词搜索

搜索页会逐步展示所有已取得的结果，并分别显示每个来源的数量、搜索进度和异常。匹配、逐字、双语和来源顺序决定排序与自动选择，不会把其他版本从手动搜索中删除。不同来源及不同版本 ID 的结果分别保留。

自动搜索每个来源、每个查询最多下载 40 个候选；手动搜索最多 80 个，LRCLIB 保留接口直接返回的可用记录。搜索当前歌曲时，同时使用完整信息、歌名及经过验证的跨语言别名；搜索其他关键词时尊重输入内容。下载按完成顺序显示，同一来源最多并发 4 个歌词下载。自动搜索在约 1 秒的初次收集后先显示可靠歌词，并继续查找更好的版本。可靠结果取得后即写入临时缓存，切歌返回或重启可立即复用，同时继续补搜；完成搜索后再确认最终版本。某来源已找到准确且满足当前逐字、双语偏好的版本时，停止该来源的额外查询；最高优先级来源满足条件后，提前结束自动搜索。未满足条件时，后台仍可深入搜索最多 24 秒；手动深度搜索最多 40 秒。加载期间显示“正在加载歌词”或“正在加载更多版本”；超时保留已有结果，重试时也保留同一查询的上次结果。

逐字标签依据实际可用的时间标记；允许零时长字符、未标记的标点和重叠时间，不会因为其中一个异常字符移除整句动画。普通 LRC 不会凭空生成逐字时间。网易云逐字歌词也会合并对应翻译。

## 安装

从 [Releases](https://github.com/wzk112/LyricsX/releases) 下载最新的 `LyricsX-2.0.8.zip`，解压后将 `LyricsX.app` 拖到 `/Applications`。

本次包使用本机 ad-hoc 签名，没有 Developer ID 公证票据。首次打开时如果 macOS 提示无法验证开发者：

1. 在 Finder 中双击一次 LyricsX。
2. 打开“系统设置 → 隐私与安全性”，点击“仍要打开”。
3. 如果系统仍提示应用已损坏，重新下载并解压；必要时执行：

   ```sh
   xattr -dr com.apple.quarantine /Applications/LyricsX.app
   ```

完整的安装、签名和版本说明见 [`docs/releases/v2.0.8.md`](docs/releases/v2.0.8.md)。

## 播放器权限

第一次读取 Apple Music 或 Spotify 时，macOS 可能要求允许 LyricsX 自动化控制播放器。允许后重启 LyricsX 即可。也可以在“系统设置 → 隐私与安全性 → 自动化”中检查权限。

如果自动模式没有找到正在播放的歌曲，可在“设置”中选择 Apple Music 或 Spotify。Apple Music 的本地歌曲还会读取文件位置和内嵌歌词；没有内嵌歌词时会继续使用联网搜索。

## 缓存和歌词格式

默认缓存目录是 `~/Music/LyricsX`，可以在“设置”中选择已有目录。应用会优先读取磁盘中的现有 `.lrcx`、`.lrc` 文件，选择另一份搜索结果后会更新原文件，不产生重复缓存。

2.0.8 起，尚未完成搜索的可靠结果也会写入同一缓存文件，以一个临时标记记录搜索状态，歌词正文、翻译和逐字时间不变。重新进入歌曲时立即显示并继续搜索；手动选择和已确认的缓存不会被临时结果覆盖。

2.0.1 起，新缓存恢复使用 `.lrcx`。它会保留逐字时间、翻译、偏移和来源附加信息；普通 `.lrc` 继续支持导入和读取。

如需重新获取所有歌词，可关闭应用后删除 `~/Music/LyricsX` 中的缓存文件，再启动 LyricsX 搜索或播放歌曲。

## 从源码构建

需要 macOS 26 或更高版本以及 Swift 6.2+：

```sh
swift test
./scripts/build.sh release
open build/LyricsX.app
```

`scripts/build.sh release` 会构建 App、复制 MediaRemote 组件、生成图标、使用 ad-hoc 签名并执行严格签名校验。默认签名身份为 `-`；正式公开分发应在本机配置 Developer ID、Hardened Runtime 和 notarization。

## 项目结构

```text
Sources/LyricsXCore       播放快照、歌词模型、时间轴和身份校验
Sources/LyricsXServices   播放器桥接、歌词搜索、缓存和编码
Sources/LyricsXApp        SwiftUI 主窗口、设置、菜单栏和悬浮窗
Vendor/LyricsKit          包含来源修复的 LyricsKit 固定源码和原许可证
Tests/                    时间轴、缓存、来源优先级、播放器和窗口回归测试
Legacy/LyricsX            原 LyricsX 项目
Legacy/LyricsXPackage     原 LyricsXPackage 项目
```

## 验证

回归测试覆盖播放进度、暂停时缺失进度的快照、切歌旧请求隔离、通知补读、严格/宽松匹配、跨语言别名、超时保留结果、逐字/双语优先、LRCX 缓存、封面、悬浮窗拖动、点击穿透和紧凑卡片切换时的位置恢复。联网搜索与原生窗口截图验证可按需启用，详见版本说明。

详细修复记录见 [`docs/modernization/REGRESSION_FIXES_2026-09-11.md`](docs/modernization/REGRESSION_FIXES_2026-09-11.md)。

## 致谢和许可证

歌词解析和媒体组件基于 [LyricsKit](https://github.com/MxIris-LyricsX-Project/LyricsKit) 与 [mediaremote-adapter](https://github.com/MxIris-LyricsX-Project/mediaremote-adapter)。原项目代码和本重构版均遵循仓库中的 [MPL-2.0 LICENSE](LICENSE)。

歌词内容的版权归其权利人所有。
