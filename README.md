# CodeBiSync（Flutter 桌面版）

一个面向开发者的本地 ↔ 远程代码目录双向同步 GUI 工具，基于 Flutter/Dart 构建，依赖 SSH 与 rsync 工作。

## 核心特性

- 双向同步闭环：基于 mtime/size 的简单差异合并；默认以“较新的修改时间”一侧覆盖。
- 一键操作：Up（启动/恢复会话）、Status（查看当前会话状态）、诊断（快速自检常见问题）。
- 远程目录浏览：通过 rsync `--list-only` 快速列目录，支持关键字筛选与选择作为远程根目录。
- SSH 配置集成：可从 `~/.ssh/config` 导入 Host、端口、私钥、ProxyJump、Compression、ForwardAgent 等。
- 私钥自动发现：优先使用 SSH 配置中的 `IdentityFile`；否则回退 `~/.ssh/id_ed25519`、`~/.ssh/id_rsa`。
- 本地/远程文件面板：展示条目与简单同步状态（已同步/待同步/失败）。

## 同步架构概览

- Endpoint：`LocalEndpoint`（本地）与 `RsyncEndpoint`（远程，基于 ssh+rsync 推送/拉取）。
- Watcher：`FsWatcher` 基于文件系统事件监听 + 去抖动，收集变更子树并驱动快速增量同步。
- Differ：`SimpleDiffer` 双向合并与冲突收集（当前采用时间优先策略）。
- Stager：`SimpleStager` 将 Alpha→Beta 变更打包为“元数据 + 字节块”。
- Transport：`LocalTransport`（当前用于本机内传递数据）。
- StateStore：`FileStateStore` 基线存储于 `<local>/.codebisync/baseline.json`。

目录结构参考：

- `lib/ui/*`：界面与交互（主页、远程浏览器）。
- `lib/services/*`：SSH/rsync 服务与会话入口。
- `lib/sync/*`：同步内核（watcher/differ/stager/endpoint/transport/state）。

## 环境依赖

- 本机：`ssh` 与 `rsync` 可用（macOS 自带；Linux 通常自带；Windows 建议安装或通过 WSL 提供）。
- 远程：目标服务器安装 `rsync` 并支持 SSH 访问。
- Flutter SDK（启用桌面支持）。仓库已包含 `macos` 目标工程。

安全提示：为简化连接，当前 `ssh/rsync` 调用使用了 `-o StrictHostKeyChecking=no` 与 `UserKnownHostsFile=/dev/null`，适合开发环境。生产环境建议开启严格主机校验并根据需要调整参数。

## 快速开始

```bash
flutter pub get
flutter run -d macos   # 或按需启用你的桌面目标
```

应用中：

- 选择本地目录。
- 填写远程 `user@host`、端口与远程目录；或使用“从 SSH 配置导入”与“选择目录（远程浏览器）”。
- 点击“Up”启动同步；用“Status”查看状态；用“诊断同步”排查常见问题（路径存在、条目数量、基线文件等）。

## 现状与路线图

- 已实现最小可用的双向同步闭环；冲突处理与 UI 提示将持续完善。
- 本地侧已启用监听驱动的增量扫描；远程端仍通过 `rsync --list-only` 浏览，后续按需补充监听/推送能力。
- Windows/Linux 桌面目标可通过 `flutter config --enable-windows-desktop` / `--enable-linux-desktop` 启用后生成工程。
- 已移除遗留的 Mutagen 探测逻辑，统一到 ssh/rsync 路径与提示。

## 免责声明

本项目仍在积极开发中，建议在重要数据上启用前做好备份与演练。
