<p align="center">
  <img src="docs/screenshots/app-icon.png" width="128" alt="WonderBox 图标">
</p>

<h1 align="center">WonderBox</h1>

<p align="center">
  一个对你的 Mac 说实话的原生系统工具箱。<br>
  内存优化真能让"已压缩"降下来，空间清理找的是几十 GB 的大头，每一个数字都能在活动监视器里对得上。
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
  <img alt="SwiftUI" src="https://img.shields.io/badge/UI-SwiftUI-0A84FF">
  <img alt="Apple Silicon 与 Intel" src="https://img.shields.io/badge/arch-Apple%20Silicon%20%7C%20Intel-555">
  <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-green">
</p>

<p align="center">
  <a href="README.md">English</a> · 简体中文
</p>

![WonderBox 概览页，显示 CPU、内存、磁盘、网络、电池与运行时间](docs/screenshots/overview.png)

> 所有扫描与分析都在本机完成，不上传任何数据。

## 为什么是 WonderBox

多数"Mac 清理工具"给你一个漂亮的绿色大数字，然后指望你别去核对。WonderBox 反过来做：

- **内存优化真正作用于已压缩内存。** `purge` 只会丢弃文件缓存，所以依赖它的工具永远动不了"已压缩"那一栏。WonderBox 的 root helper 发出的是 macOS 自己在内存紧张时使用的内核级内存压力广播：每个运行中的 App 都会收到通知并释放缓存，缓存背后的压缩页也随之释放。完成后按类别给出前后对比，并点名哪些 App 做出了响应。
- **按 App 归因的内存占用，可以直接下手。** 子进程会合并到宿主 App（Chrome 的 40 个渲染进程只显示一行），并估算每个 App 有多少内存正躺在压缩器或交换空间里。同一行即可退出或强制退出。
- **空间清理找的是几十 GB，不是几十 MB。** 包管理器缓存、Chromium/Electron 网页缓存、沙盒容器缓存、模拟器与 DeviceSupport 文件——这些才是真正塞满开发者硬盘的地方。
- **诚实的数字。** 体积统计超时的项目以 `≥` 标注为下界。结果只说实际发生了什么，没变化就直接说没变化。
- **靠结构保证安全。** 每一次删除都要通过按类别定义的根目录白名单与路径形状校验。用户数据（聊天记录数据库、文档、Docker 虚拟磁盘、工具链）从一开始就不在候选范围内。不是可重建缓存的东西一律移入废纸篓。

## 功能

### 内存

![内存页：活动监视器同款分类、内存压力等级、按 App 的物理占用排行](docs/screenshots/memory.png)

- 与活动监视器一致的分类——App 内存、联动内存、已压缩、缓存文件、可用——外加交换空间用量与内核内存压力等级
- 按 App 汇总的物理占用排行，标注每个 App 已压缩或交换的份额，支持退出与强制退出
- 一键优化：系统级内存压力广播 → 文件缓存清理，输出逐类别的前后对比报告
- 概览页的健康横幅同时反映内存压力，而不只是温控状态

### 空间清理

![深度清理，显示包管理缓存与浏览器缓存](docs/screenshots/cleaner-deep.png)

**标准扫描** — 用户缓存（含沙盒 App 容器）、日志、Xcode DerivedData、超过 7 天的安装包、废纸篓。

**深度清理** 额外覆盖：

| 类别 | 覆盖范围 |
| --- | --- |
| 包管理缓存 | npm、pnpm、yarn、bun、uv 及其他 `~/.cache` 下的工具、Cargo registry、Go modules、Gradle、Maven、CocoaPods——只删下载缓存，工具链与已安装版本绝不触碰 |
| 浏览器与 Electron 缓存 | 任意 Profile 或 Electron 用户数据目录中的 Chromium `Cache`、`Code Cache`、`GPUCache`、Service Worker `CacheStorage` 等；对应 App 运行中时自动跳过 |
| 开发深层缓存 | 模拟器缓存、iOS/watchOS/tvOS DeviceSupport、文档缓存、Previews 模拟器设备 |
| 应用残留 | 已卸载 App 遗留的数据（90 天阈值 + bundle id 启发式判断） |
| 设备备份、未完成下载 | 本机 iPhone/iPad 备份；超过 7 天的 `.download`/`.crdownload`/`.part` 文件 |

每个类别都能展开到具体项目，保留这个工具的缓存、删掉那个工具的：

![包管理缓存类别内的逐项选择](docs/screenshots/cleaner-detail.png)

### 应用卸载

![应用卸载与关联文件](docs/screenshots/applications.png)

盘点 `/Applications` 与 `~/Applications`，从 Spotlight 读取体积、安装日期与最近使用时间；大型/久未使用筛选；逐 App 列出关联的缓存、偏好设置、容器与保存状态；全部移入废纸篓，随时可恢复。

### 磁盘分析

![磁盘分析，按大小列出主目录下的子项](docs/screenshots/storage.png)

逐层深入任意文件夹，体积并行计算；按大小/名称/日期排序，在 Finder 中显示或将所选项目移入废纸篓。云同步目录不参与体积统计，扫描绝不会触发下载。

### 风扇控制、保持唤醒、菜单栏

<table>
  <tr>
    <td width="50%"><img src="docs/screenshots/fan.png" alt="风扇页：实时转速仪表与控制模式"></td>
    <td width="50%"><img src="docs/screenshots/awake.png" alt="保持唤醒页：时长与显示器选项"></td>
  </tr>
</table>

![菜单栏面板：CPU、内存、磁盘、风扇转速、保持唤醒与快捷操作](docs/screenshots/menubar.png)

- 从 AppleSMC 读取实时风扇转速；在开放了风扇写入的机型上提供静音/均衡/强劲/自定模式（含 Apple Silicon 的 `Ftst` 解锁），随时可恢复自动
- 保持唤醒支持 30 分钟 / 1 小时 / 2 小时 / 持续，可选同时保持显示器点亮，基于公开的 IOKit 断言接口
- 菜单栏面板：CPU、内存、磁盘、风扇转速、唤醒开关、内存优化与一键清理，不用打开主窗口
- 跟随系统 / 浅色 / 深色外观，四种强调色，登录时启动

![设置页：外观、菜单栏、登录启动与权限状态](docs/screenshots/settings.png)

## 安装

运行要求：macOS 14 或更新。编译要求：Xcode 16 或更新。

```bash
git clone https://github.com/jasonwong1991/WonderBox.git
cd WonderBox
swift build
swift test
./scripts/package_app.sh
open build/WonderBox.app
```

Swift Package 会构建 `WonderBox` 主程序与两个 helper。`package_app.sh` 生成本地签名的 `build/WonderBox.app`，内含生成的图标与打包好的 helper。

## 多语言

WonderBox 内置英文与简体中文，默认跟随系统语言；也可以在「设置 › 语言」中单独为本应用指定。所有文案集中在一个字符串目录 `Sources/WonderBox/Resources/Localizable.xcstrings`，源语言为英文。

新增一种语言：

1. 用 Xcode 的 String Catalog 编辑器打开 `Localizable.xcstrings`（以及 `InfoPlist.xcstrings`），或直接编辑 JSON，为每个 key 的 `localizations` 添加新的语言代码。
2. 把语言代码加进 `scripts/sync_localization.py` 的 `LANGUAGES`，以及 `Sources/WonderBox/Core/Localization.swift` 中的 `AppLanguage` 枚举，这样它会出现在设置页的选择器里。
3. 运行 `scripts/sync_localization.py --check`，存在未翻译的 key 时会失败；`swift test` 也会检查同样的内容以及格式占位符是否一致。

不带参数运行 `scripts/sync_localization.py` 会让编译器列出源码中所有可本地化的字符串并把新 key 写入目录，不需要手工维护 key 列表。

## 权限

WonderBox 只在你第一次用到某个功能时，索取那个功能刚好需要的权限：

| 功能 | 权限 | 时机 |
| --- | --- | --- |
| 系统监测、保持唤醒、应用盘点、标准清理 | 无 | — |
| 废纸篓容量与清空 | 自动化（Finder） | 第一次清理扫描 |
| 完整主目录扫描 | 完全磁盘访问（可选，用户自行控制） | 引导页或设置页 |
| 风扇控制、内存优化 | 管理员密码，仅一次，用于安装 helper 守护进程 | 第一次写入风扇或优化内存 |
| `/Library/Caches` 清理 | 每次执行输入管理员密码 | 选中该类别时 |

helper 守护进程是一个固定指令服务，通过 root 持有的 Unix socket 通信，只接受 `version`、`status`、`set-auto`、`set-rpm`、`optimize-memory` 五条指令；只有当 App 内置的 helper 版本更新时才会重新安装（弹一次授权）。

## 发行档位

核心监测与保持唤醒功能只用公开 API。应用与清理操作使用公开的 Foundation API，但对用户 Library 的广泛访问受 App Sandbox 限制。

- **Direct**（`package_app.sh` 产出）：内置 `WonderFanHelper`；helper 守护进程（协议 v4）负责风扇写入与内存压力广播/缓存清理。可一次性开启完全磁盘访问以进行广泛的本机扫描。
- **App Store**：启用 `WonderBox-AppStore.entitlements`，剔除 fan helper 与 CSMC 源码，保留用户选择的文件访问权限。广泛的清理类别必须改用文件夹选择 + 安全作用域书签，或直接禁用。

能力矩阵与发布检查清单见 [`docs/DISTRIBUTION.md`](docs/DISTRIBUTION.md)。

## 品牌素材来源

WonderBox 的应用图标与菜单栏图标均为原创几何图形，完全由本仓库中的 `scripts/generate_icon.swift` 与 `MenuBarAppIcon` 生成，不包含任何第三方 Logo、素材库图片或复制的图像资源。SF Symbols 仅作为原生 macOS 界面符号在应用内使用。截图中出现的第三方应用图标归各自所有者所有。

## 许可证

[MIT](LICENSE)
