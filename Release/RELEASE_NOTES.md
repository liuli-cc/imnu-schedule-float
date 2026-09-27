教务悬浮助手 1.1.0 将当前悬浮球版本整理成 Mac / Windows 完整下载包。

- 点击一次即可展开课表；登录后自动显示悬浮球，可从菜单栏/托盘关闭自动启动。
- 灰紫色玻璃面板与弹性展开；Mac 使用原生毛玻璃，Windows 11 22H2 及以上使用 Acrylic，较早 Windows 保留半透明效果。
- 今天、明天、本周、本学期课表，上课时间、全部学期成绩、学分、绩点和官网个人信息入口。
- 复用官方登录会话；Mac 后台钥匙串读取保持安静，不保存明文学校密码。官方会话过期后仍需重新授权。
- 断网和部分附加接口失败保留缓存，接受官方空课表，修正教学周跨周和零分成绩。
- 提供 Apple 芯片 Mac、Intel Mac、Windows x64、Windows ARM64，Windows 同时提供安装 EXE 和完整免安装 ZIP。

选择版本：Mac 的“关于本机”查看芯片，Windows 的“系统 → 系统信息”查看系统类型。下载名称中的 arm64 对应 Apple M / Windows ARM，x86_64 对应 Intel Mac，x64 对应 Intel / AMD Windows。

Mac 要求 macOS 14 或更新；Windows 要求 Windows 10 / 11。Mac ZIP 内含应用、安装/卸载脚本和说明，Windows ZIP 必须完整解压后运行 IMNUScheduleFloat.exe。

验证：Mac 原生数据/钥匙串异步回归、Mac 与 Windows 网页解析器一致性、Windows 缓存/教学周回归、Windows x64 打包后真实 EXE 的隔离界面启动检查、四种架构与六个产物检查、SHA256 校验。界面检查使用合成数据，未冒用真实学校账号；Windows ARM64 未经过 ARM 实机交互验收。

安装包不包含用户账户、登录状态或私人课表。应用尚无 Apple 公证和 Windows 商业发布者证书，首次打开可能需要按系统提示确认开发者。完整说明与各平台直达链接见仓库首页。
