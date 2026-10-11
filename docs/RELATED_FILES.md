# 应用关联文件：覆盖范围与依据

扫描使用标识符、精确产品名、组件元数据或签名声明，不使用公司名模糊匹配，也不为单个应用添加路径白名单。以下为 2026-10-11 查阅文档及上游源码后的覆盖矩阵。

| 数据布局 | 关联依据 | 默认选择 |
| --- | --- | --- |
| 用户/系统 Application Support、Caches、Logs、Preferences；ByHost、Cookies、HTTPStorages、WebKit、Saved Application State | 应用标识符；适用位置上的精确原始/本地化/运行时名称 | 主应用直接关联选中 |
| `~/Library/<产品名>` 自定义目录、名称型日志与偏好设置 | 精确名称；排除共用 Library 根目录 | 选中 |
| Containers（含 UUID 目录）、Group Containers、Application Scripts、应用组偏好设置 | 标识符或容器所有者元数据；应用组来自代码签名 | 独立组件/共享组待确认 |
| Application Support 厂商子目录 | 精确产品叶子目录；不选择整个厂商目录 | 待确认 |
| 内嵌 Helper、XPC、扩展、登录项、QuickLook/Spotlight 插件的数据 | 选中应用内的组件标识符 | 待确认 |
| LaunchAgents、LaunchDaemons、PrivilegedHelperTools | 标识符、声明的 helper 或程序路径指向应用内部 | 共享 helper 待确认 |
| Darwin 用户临时/缓存目录 | 应用或组件标识符 | 组件待确认 |
| Electron 旧版本迁移目录 | 有界读取根包元数据与启动代码中的明确迁移引用 | 待确认 |
| **新增** 最近文档元数据 `.sfl` / `.sfl2` / `.sfl3` | sharedfilelist 的 ApplicationRecentDocuments 子目录下，精确应用标识符文件；不删除引用的原文档或全局数据库 | 主应用选中 |
| **新增** `~/Library/Autosave Information/<名称或标识符>` | 精确应用叶子目录；可能包含未保存的文档 | 待确认 |
| **新增** `~/.config`、`~/.cache`、`~/.local/share`、`~/.local/state` | 默认 XDG 根目录下的精确应用/运行时名称或标识符；可能被命令行版本共用 | 待确认 |
| **新增** Sparkle / SentryCrash / KSCrash 共用缓存目录中的产品叶子 | 精确产品/标识符路径探测；不枚举 SDK 子目录或选择共用根目录 | 待确认 |
| **新增** 用户/系统 QuickLook、Spotlight、Services、PreferencePanes、Internet Plug-Ins、Screen Savers、音频 Components/VST/VST3/CLAP | 独立插件 Info.plist 的标识符必须精确等于主应用或已发现组件标识符；文件名相似不构成归属 | 待确认 |

## 性能和确认行为

- 列表发现不递归遍历应用数据。SDK 缓存使用精确路径探测，插件只读有界 Info.plist（小于 1 MiB），最多检查 512 个插件；达到上限会显示列表可能不完整。组件标识符检查与目录/元数据缓存复用，不执行应用或插件代码。
- 仍沿用单 worker、每应用合计 60 ms / 1,500 项的自动大小预算。大小未测量与已测量为零不同；部分大小标记 `≥`，完整大小按需统计。
- 未勾选项目在详情底栏显示数量和已统计大小，卸载确认再次提示这些项目将保留。确认按钮明确仅移除所选项目；「返回检查」只关闭确认，不改变选择。共享/恢复数据不会因提示而被自动全选。
- 未勾选数量按关联根项目计算，不是内部文件数。无法读取的位置会提示不完整，不把权限错误当作目录为空。刷新和卸载会清空会话缓存。

## 不作为普通关联文件删除的内容

- 不根据应用名扫描或删除 Documents、Desktop、照片、云盘文档；不读取文档内容来猜测归属。
- 不删除 Keychains、TCC 权限库、后台项目 BTM 数据库、全局 sharedfilelist、安装收据或共用 SDK/厂商根目录。
- 不直接移除驱动、内核/系统扩展、HAL 音频驱动或系统域内容；这类软件需使用其卸载流程或系统服务注销接口。
- 不跟随符号链接、不展开任意深度/任意环境变量配置的目录、不扩大到任意产品名前缀。未有明确归属证据的历史目录仍可能遗漏；本矩阵不是零残留保证。

## 调研来源

1. [Apple：macOS Library Directory Details](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/MacOSXDirectories/MacOSXDirectories.html) — Library 数据用途、自动保存和插件位置。
2. [Apple：File System Overview](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemOverview/FileSystemOverview.html) — 区分应用数据、用户文档和系统域。
3. [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir/latest/) — 用户配置、缓存、数据、状态的默认目录。
4. [Pearcleaner：Locations.swift](https://github.com/alienator88/Pearcleaner/blob/main/Pearcleaner/Logic/Locations.swift) — 对照遗漏的最近文档、共享 SDK 缓存和插件布局；不照搬宽泛名称匹配、用户文档扫描或全盘深搜。
5. [Sparkle：SPULocalCacheDirectory.m](https://github.com/sparkle-project/Sparkle/blob/2.x/Sparkle/SPULocalCacheDirectory.m) — 当前 Sparkle 优先按应用标识符分隔缓存，已有常规缓存规则覆盖；补充兼容共享缓存根下的精确产品叶子。
6. [Sentry Cocoa：SentryCrash.m](https://github.com/getsentry/sentry-cocoa/blob/main/Sources/SentryCrash/Recording/SentryCrash.m) — SentryCrash 按 bundleName 建立子目录；仅对已知默认布局做精确探测，不猜测自定义 basePath。
7. [Apple：Updating helper executables from earlier versions of macOS](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos) — 服务生命周期与共享系统记录不应等同于直接删除文件。

验证：`RelatedFileCoverageTests` 覆盖多产品布局、近似名称/兄弟应用/用户文档/驱动反例、symlink、插件预算、权限失败、缓存失效和非递归发现；`RelatedFileSelectionTests` 覆盖全选/未全选、大小未知/下限、路径去重、饱和加法、已在废纸篓应用及紧凑布局。原有身份、Electron、卸载和性能测试继续运行。
