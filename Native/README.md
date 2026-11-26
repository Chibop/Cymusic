# CyMusic 原生 iOS 版

打开 `Native/CyMusicNative.xcodeproj`，运行 `CyMusic` scheme。原生目标不依赖 Expo、React Native、Yarn 或 CocoaPods。界面使用 SwiftUI，音频使用 AVFoundation；JavaScriptCore 和原有 Objective-C 辅助代码用于兼容用户导入的音源脚本。最低 iOS 16.4；使用 Xcode 27 在本机构建。较新系统沿用系统导航栏、标签栏及玻璃迷你播放器，旧版有回退界面。

## 构建与验证

从仓库根目录运行：

```sh
# 只有修改工程配置或增加文件时才需要重新生成
xcodegen generate --spec Native/project.yml
bash Native/package.sh "$HOME/Downloads/CyMusic-Native"
bash Native/SourcesEngine/verify-engine.sh --live --example
sh Native/LegacyTests/run.sh
```

在 Xcode 的 iPhone 模拟器上运行 `CyMusic` scheme 的 Tests 检查界面导航。真机安装需要给主程序和分享扩展重新签名，二者须共用 App Group。不要卸载旧版来尝试迁移；测试覆盖升级前请备份。

## 数据与验证边界

- 旧版 `appPersistStatus` 库通过临时副本和官方 MMKV 2.4.0 读取；收藏、歌单、导入歌曲及可定位的本地文件合入新资料库，成功落盘后才记录迁移完成。仅在没有原生音源库时尝试恢复旧音源及其选择，不在迁移时运行脚本。
- 本地验收包括 iPhone Release 打包、iOS 27 中文导航、真实 MMKV 格式测试库的只读迁移与重启，以及查询榜单、曲目、专辑、歌手、歌词和示例音源协议。不是实际用户设备上的覆盖安装测试，也不保证所有第三方音源可用。原生音源不支持完整 Node 或浏览器 DOM 环境。
- 本次没有接入 Apple Music 系统资料库或增加批量离线下载。对照用的旧应用仍在原目录，旧版工程并非原生分支的构建入口。
