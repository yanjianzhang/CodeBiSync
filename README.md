# CodeBiSync (Flutter Edition)

A GUI tool for bidirectional local ↔ remote synchronization of code projects, using Flutter + Dart.

## 功能（当前版本）

- Up（启动或恢复同步会话）  
- Status（查看 mutagen sync list 输出）  

## 依赖

- mutagen 可执行程序需在系统 PATH 中可用  
- SSH / rsync 在本地 / 远程环境支持  
- Flutter SDK + 桌面支持开启

## 运行

```bash
flutter pub get
flutter run -d windows  # 或 macos / linux