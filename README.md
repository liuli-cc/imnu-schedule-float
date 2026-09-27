# 教务悬浮助手

以内蒙古师范大学课表为主的桌面悬浮球。点击一次即可查看今天、明天、本周、本学期的课程和上课时间，也可查询全部学期成绩、学分、绩点，并从个人信息入口打开教务官网。

当前版本 **1.1.1**。保留悬浮球、靠边隐藏、灰紫色透明面板与弹性展开；macOS 使用原生毛玻璃，Windows 11 22H2 及以上使用系统 Acrylic，较早的 Windows 使用半透明面板。

## 选择你的版本

无需安装开发工具。Windows 免安装包解压后运行 `IMNUScheduleFloat.exe`；Mac 解压后打开应用，或运行包内的安装脚本。

| 电脑 | 推荐下载 | 免安装 / 便携包 |
| --- | --- | --- |
| Mac · Apple M 系列 | [macOS Apple 芯片版 ZIP](https://github.com/liuli-cc/imnu-schedule-float/releases/download/v1.1.1/IMNU-Schedule-Float-macOS-arm64-1.1.1.zip) | 同左 |
| Mac · Intel | [macOS Intel 版 ZIP](https://github.com/liuli-cc/imnu-schedule-float/releases/download/v1.1.1/IMNU-Schedule-Float-macOS-x86_64-1.1.1.zip) | 同左 |
| Windows · Intel / AMD | [Windows x64 安装版](https://github.com/liuli-cc/imnu-schedule-float/releases/download/v1.1.1/IMNU-Schedule-Float-Windows-x64-1.1.1-Setup.exe) | [Windows x64 ZIP](https://github.com/liuli-cc/imnu-schedule-float/releases/download/v1.1.1/IMNU-Schedule-Float-Windows-x64-1.1.1.zip) |
| Windows · ARM / Snapdragon | [Windows ARM64 安装版](https://github.com/liuli-cc/imnu-schedule-float/releases/download/v1.1.1/IMNU-Schedule-Float-Windows-arm64-1.1.1-Setup.exe) | [Windows ARM64 ZIP](https://github.com/liuli-cc/imnu-schedule-float/releases/download/v1.1.1/IMNU-Schedule-Float-Windows-arm64-1.1.1.zip) |

[全部下载和更新说明](https://github.com/liuli-cc/imnu-schedule-float/releases/latest) · [SHA256 校验文件](https://github.com/liuli-cc/imnu-schedule-float/releases/download/v1.1.1/SHA256SUMS.txt)

### iPhone 课表小组件

[iPhone 小组件下载与说明](https://github.com/liuli-cc/imnu-schedule-float/releases/tag/iphone-widget-v1.0.0) · [手机源码与数据导出](Mobile/README.md)。通过免费的 Scriptable App 导入，支持主屏幕小、中、大号和锁屏入口；点击直接查看课表与成绩。该版本为小组件脚本，需导入自己的桌面课表，不是独立签名 IPA。公开包不含私人数据。

系统要求：macOS 14 及以上；Windows 10 / 11。Mac 可在“关于本机”查看芯片；Windows 在“设置 → 系统 → 系统信息”查看系统类型。Windows ARM64 包已检查架构，尚未经过 ARM 实机交互验收。

## 安装与使用

Mac 解压后先打开“教务悬浮助手.app”。运行“安装.command”可安装并启用登录后自动显示悬浮球；已有 `/Applications` 安装会原位更新，否则安装到当前用户的 Applications 文件夹。也可自己移动应用，然后在菜单栏勾选“登录后自动显示悬浮球”。不用管理员密码或 Python / Homebrew。

Windows 安装程序可选择目录。首次运行会显示悬浮球并启用登录后启动，右键托盘图标可关闭自动启动；免安装版请放在固定文件夹，避免开机启动路径失效。更新安装保留本机课表与官网会话，卸载安装版会移除自动启动项。

首次使用点击“授权登录”，在学校官方页面完成登录。随后点击悬浮球即可展开课表；拖到屏幕边缘可以收起，点击边缘入口一次即可展开。应用在后台每 45 分钟尝试同步，也会在网络恢复或电脑唤醒后刷新。

应用尚未购买 Apple 公证和 Windows 发布者证书。首次下载可能出现系统的开发者确认：Mac 可依照“系统设置 → 隐私与安全性”的提示允许打开；Windows 可在确认本仓库下载来源后按系统提示打开。无需关闭系统安全功能。

## 登录信息与离线缓存

- 复用学校官网的登录会话，不保存明文教务密码，也不收集扫码凭据。官方会话未失效时，关闭或重启后可继续使用；学校使会话过期后仍需重新授权。
- Mac 使用 WebKit 持久会话，并在系统允许时把会话备份到钥匙串。后台读取不会主动弹出钥匙串密码框；“允许钥匙串保存登录”是用户主动操作。若 macOS 询问“登录钥匙串”密码，通常是 Mac 登录/解锁密码。
- Windows 使用独立的持久浏览器会话。课表、成绩和个人信息保存在当前用户的本机应用数据目录，请保护好自己的系统账户。
- 断网保留已有课表和成绩。部分附加接口失败时保留对应缓存；官方空课表正常显示。教学周来自官网，跨周时按本地日期推进，不从首次打开日期猜测教学周。
- Github 源码和安装包不包含任何用户的账号、登录状态或私人课表。本应用是独立工具，并非学校官方客户端。

## 开发与发布

Mac 需要 Swift 6 / Xcode 16 或更新版本；Windows 需要 Node.js 22。

```sh
# macOS：编译当前电脑版本
./build.sh
# 数据与会话回归检查，使用隔离的合成数据
./Tests/run-data-regressions.sh
# 任一 Mac 架构的可分发 ZIP
bash Release/build-macos.sh arm64
bash Release/build-macos.sh x86_64
# 修改原生网页解析器后同步 Windows 版本
python3 Release/sync-portal-parser.py
```

```sh
cd windows
npm ci
npm test
npm run build -- --x64
npm run build -- --arm64
```

GitHub Actions 自动构建四种架构、六个下载包。Mac 的回归检查覆盖缓存、教学周、部分同步和钥匙串异步行为；Windows x64 启动打包后的真实 EXE，用隔离的演示数据验证悬浮球点击、课表、成绩、边缘展开与个人信息入口。校验全部产物后生成 SHA256SUMS 并发布 Release。合成检查不代表学校真实账号登录或同步验收。

维护者先更新 `VERSION`、Mac Info.plist 与 Windows package.json，再运行 `Build and release IMNU Schedule Float` 工作流并选中 publish，或推送对应 `v*` 标签。发布会绑定实际检查过的提交。
