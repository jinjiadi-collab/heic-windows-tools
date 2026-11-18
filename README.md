# Windows HEIC 图片支持工具

提供两个独立版本，按需要选择，不必都安装。

| 版本 | 用途 | 下载 |
|---|---|---|
| **V3｜微软扩展安装版** | 安装微软 HEIF、HEVC 扩展，附带刷新和检测功能 | [下载 V3](https://github.com/jinjiadi-collab/heic-windows-tools/releases/download/v3.0.0/HEIC-Microsoft-Extensions-v3.zip) |
| **V4｜10 位 HEIC 兼容修复版** | 针对安装微软扩展后仍打不开的部分图片，使用 WicHeic 替代解码器；不改原文件，显示为普通 8 位画面 | [下载 V4](https://github.com/jinjiadi-collab/heic-windows-tools/releases/download/v4.0.0/HEIC-10bit-Compatibility-v4.zip) |

## 怎么选

- 电脑缺少 HEIF、HEVC 扩展：先使用 **V3**。
- 已安装微软扩展，部分 10 位 HEIC 仍打不开：使用 **V4**。
- V4 是针对部分图片的兼容方案，不代表所有 10 位 HEIC 都需要修复，也不保证支持所有 HEIC 变体。

面向 Intel/AMD 64 位 Windows 10 1809（17763）及以上、Windows 11。未对所有系统版本逐一实测。

## V3｜微软扩展安装版

包含微软 HEIF 图片扩展 **1.2.65.0**。厂商版 HEVC 按系统内部版本自动选择：低于 **26200** 使用 **2.4.149.0**，**26200 及以上**使用 **2.5.48.0**；已正常安装的同版或新版会跳过。

1. 下载并全部解压。
2. 先结束文件复制、移动操作，关闭看图程序。
3. 双击 **一键安装.cmd**。

安装后会刷新缩略图并重启文件资源管理器。也可以单独使用包内的刷新、检测入口。。

微软原始安装包未修改、未重新签名，安装脚本会检查文件哈希及微软数字签名。

## V4｜10 位 HEIC 兼容修复版

使用第三方 **WicHeic 1.1.16** 接入 Windows 图片接口，不需要先将原图转成 JPG。

1. 下载并全部解压。
2. 使用日常看照片的 Windows 账户，运行 **1-一键安装修复.cmd**。
3. 退出原来的看图窗口，再右键 HEIC → **打开方式 → 照片**。

其他入口：

- **2-用Windows照片查看器打开.cmd**：选择原图，使用旧版查看器打开。
- **3-撤销修复.cmd**：恢复本工具修改前的注册信息。
- **4-只检测原图.cmd**：检查 Windows 是否能够完整解码所选图片。

V4 保留微软 HEIF/HEVC 扩展，不修改原始 HEIC，不改变原有默认看图程序。普通运行安装到当前账户；管理员运行会写机器范围注册信息，撤销时也需要相应权限。推荐普通运行并使用同一账户安装、撤销。

**显示限制：**V4 显示普通 8 位画面，不提供 HDR 显示。原文件中的高位深和 HDR 数据不会被修改；显示效果不保证与支持 HDR、完整色彩管理的软件相同。

**验证范围：**V4 已在一台 Win10 电脑上验证原始 10 位 HEIC 的完整解码，并确认“照片”可以打开；安装、撤销和重新安装也已验证。旧版 Windows 照片查看器已打开，并经用户验证可以打开图片。

## 来源与文件

- 微软：[HEIF 图片扩展](https://apps.microsoft.com/detail/9PMMSR1CGPWG)、[来自设备制造商的 HEVC 视频扩展](https://apps.microsoft.com/detail/9N4WGH0Z6VHQ)。
- WicHeic：[项目仓库](https://github.com/prsyahmi/wic_heic)、[1.1.16 官方发布](https://github.com/prsyahmi/wic_heic/releases/tag/v1.1.16)。第三方许可证保存在 V4 的 `licenses` 中，组件未修改。
- 本仓库中的 `versions/v3`、`versions/v4` 分别保存脚本、清单和说明；完整运行组件请下载上方发布包。`src/Verify.cpp` 是 V4 图片验证工具的源码。
- 发布包内的 `自检样本.heic` 是人工色彩图案，不含个人照片。
