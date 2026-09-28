![platform](https://img.shields.io/badge/Platform-Android%20%7C%20iOS%20%7C%20Windows%20%7C%20MacOS%20%7C%20Linux-brightgreen)
![last-commit](https://img.shields.io/github/last-commit/bingxizhe/JHenTai)
![star](https://img.shields.io/github/stars/bingxizhe/JHenTai)
[![issue](https://img.shields.io/badge/chat-issue-brightgreen)](https://github.com/bingxizhe/JHenTai/issues/new)

# JHenTai (Fork)

[English](README.md) | 简体中文 | [한국어](README_kr.md)

本项目是 [JHenTai](https://github.com/jiangtian616/JHenTai) 的 Fork，一个支持 Android、iOS、Windows、MacOS 和 Linux 的 E-Hentai 多端漫画阅读器。

此 Fork 侧重于**强化下载管理**、**本地画廊管理**和**批量化操作**。所有改动均设计为非侵入式，与上游代码库兼容，并定期合并上游更新。

## Fork 功能

### 1. 画廊版本链管理

上游仅存储单跳父版本 URL。本 Fork 将其扩展为完整祖先链，即使中间版本已删除也能识别跨多跳的版本关系。

- **完整祖先链**：`oldVersionGalleryUrl` 以 JSON 数组形式存储完整祖先链（父版本 → 祖父版本 → ……，最多 20 层）。下载新画廊时后台自动爬取并持久化祖先链，若祖先版本本地已存在则短路追加。
- **批量删除历史版本**（`eh_delete_history_versions_dialog.dart`）：按祖先链对已下载画廊分组，默认预选除每组最新版本外的所有版本，一键批量删除。支持"深度扫描"发现本地未记录的版本关联，24 小时内扫描结果可复用，双站点（e-hentai/exhentai）回退。
- **获取历史版本链接**（`eh_fetch_old_version_urls_dialog.dart`）：联网递归爬取所有已下载画廊的完整祖先链，双站点回退。自动将旧格式单链接记录升级为完整祖先链。
- **域名无关匹配**：按 gid+token 匹配版本关系，忽略域名差异，处理 e-hentai.org 与 exhentai.org URL 混用情况。

### 2. 下载恢复健壮性

- **延迟恢复**：下载恢复不再在应用启动时执行，改为首次进入下载页时通过 `ensureRestored()` 触发，避免大目录（数千画廊）阻塞应用启动。
- **恢复进度横幅**：下载页顶部分阶段显示恢复进度（"正在解析画廊数据 x/y"、"正在加载画廊 x/y"）。
- **批量恢复模式**：恢复 3000+ 画廊时抑制单画廊 `update()` 调用，改为按间隔批量刷新 UI。
- **异步 I/O 恢复**：恢复任务改用异步文件 I/O 替代同步 `listSync`/`readAsStringSync`，避免阻塞 UI 线程。
- **跳过已加载画廊**：通过目录名提取 gid 跳过已从 DB 加载的画廊的元数据解析。
- **元数据一致性校验**（`verifyDownloadedGalleriesMetadata`）：扫描下载目录修复 sanitizedTitle 不匹配、图片路径过期、重复目录振荡等问题，并恢复被先前 verify 错误重置为 paused 的已下载画廊（curCount=0 但封面文件存在）。
- **孤儿目录清理**：删除画廊时若 sanitizedTitle 不匹配磁盘目录名，按 gid 前缀匹配删除，避免成为孤儿目录被 verify 重新导入。

### 3. 收藏批量下载

- **一键批量下载**：一键下载指定分组的所有收藏，自动跳过已下载（普通下载或归档下载）的画廊。
- **断点续传**：支持 30 分钟内断点续传。加载失败或下载失败后记录进度，顶部横幅显示倒计时和"继续"按钮。
- **下载前对话框**：批量下载前选择目标下载分组和是否下载原图。
- **进度横幅**：顶部显示"正在加载所有收藏 x"和"正在批量下载 x/y"进度。
- **重试机制**：页面加载和单个画廊入队均有 5 次重试，重试间隔分别为 2 秒和 500ms。
- **增量持久化**：收藏列表每 5 页保存一次而非每页保存，降低大规模收藏的 O(n²) 序列化开销。

### 4. 本地画廊管理

- **延迟扫描**：本地画廊扫描不再阻塞应用启动，改为首次进入下载页时通过 `ensureScanned()` 触发。
- **扫描进度显示**：扫描时显示"已扫描目录数/总目录数"和"已发现画廊数"。
- **加载状态指示**：本地画廊页使用 `LoadingStateIndicator` 显示扫描加载状态与进度文本。
- **整目录删除**：删除本地画廊时始终删除整个目录（包括非图片文件和元数据），避免遗留空文件夹或半删除状态。
- **异步扫描重构**：扫描逻辑改为 async/await 结构配合进度回调，替代嵌套 Completer 模式。

### 5. UI/UX 改进

- **响应式下载图标**：画廊卡片下载图标改为响应式，监听 `GalleryDownloadService` 和 `ArchiveDownloadService` 的状态变化，下载/归档完成后立即更新图标（原先基于一次性 `downloaded` 判断，不会随状态变化更新）。
- **文本溢出修复**：评论作者名、dashboard 卡片、下载列表上传者名、画廊卡片时间等长文本使用 `Flexible` + `maxLines:1` + `overflow:ellipsis` 修复溢出。
- **第三方查看器错误判断**：`openThirdPartyViewer` 仅按非零退出码判断错误，避免 Chromium/Electron 类查看器的 stderr 日志噪音（如 GPU 缓存失败）被误报为错误。

### 6. 性能与工程优化

- **启动性能日志**：记录每个 `JHLifeCircleBean.initBean` 的耗时，超过 50ms 的输出 trace 日志，并记录总耗时。
- **数据库 WAL 模式**：启用 `PRAGMA journal_mode = WAL` 和 `busy_timeout = 5000`，提升并发读写性能。
- **图片插入或替换**：`insertImage` 改为 `InsertMode.insertOrReplace`，修复重复插入冲突。
- **最近画廊分组数量限制**：最近画廊分组数量限制不超过 10 个。
- **自定义插入时间**：`GalleryDownloadRequest` 新增 `insertTime` 字段，供批量收藏下载错开时间让优先级调度器逐个下载。
- **新版本 URL 选择优化**：`newVersionGalleryUrl` 改为按 updateTime 排序选择最新的子版本，而非简单取最后一个。

## 下载与安装

从 [GitHub Releases](https://github.com/bingxizhe/JHenTai/releases) 下载最新版本（Android APK 和 Windows ZIP）。

从源码构建：

1. 你需要自己管理安卓签名文件，见 https://docs.flutter.dev/deployment/android#signing-the-app
2. 使用 IDEA 或 VSCode 直接运行即可。

## 主要 Dart 依赖

- [get](https://pub.flutter-io.cn/packages/get): 依赖管理、状态管理、国际化、NoSQL
- [dio](https://pub.flutter-io.cn/packages?q=dio): 网络
- [extendedImage](https://pub.flutter-io.cn/packages/extended_image): 图片
- [drift](https://pub.flutter-io.cn/packages/drift): 数据库

## 借鉴与感谢

- [JHenTai](https://github.com/jiangtian616/JHenTai) - 原项目
- [FEhviewer](https://github.com/honjow/FEhViewer) - 布局样式参考
- [EHPanda](https://github.com/tatsuz0u/EhPanda) - 布局样式参考
- [EhTagTranslation](https://github.com/EhTagTranslation/Database) - 标签翻译
