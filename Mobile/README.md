# 教务助手 · iPhone 小组件

使用 [Scriptable](https://scriptable.app/) 承载真实 iOS 主屏幕和锁屏小组件。小、中、大号显示当前或下一节课、时间、教室、当天课程数量；点击直接进入离线完整课表，可切换今天、明天、本周、学期，搜索课程并查询成绩。沿用灰紫色和系统字体，支持浅色与深色；锁屏颜色由 iOS 控制。

安装步骤见 [安装说明](安装说明.txt)。需要先从 App Store 安装免费 Scriptable。这是可导入的小组件脚本，不是独立签名的 iPhone App；AirDrop 负责传文件，不能使未签名 IPA 获得安装许可。小组件不跨应用悬浮，iOS 控制其刷新频率。

## 从自己的桌面数据生成专用包

Mac 缓存中的 Date 使用 Swift 的 2001 年参考纪元；导出器转成 ISO 日期并保留官网教学周锚点。Windows ISO 字符串同样支持。只复制明确允许的课程与成绩字段，不导出学生姓名、学号、Cookies 或登录凭据。

```sh
python3 Mobile/export-mobile.py \
  --cache "$HOME/Library/Application Support/IMNUScheduleFloat/schedule-cache.json" \
  --output "$HOME/Desktop/教务助手_iPhone小组件_专用包"
```

将生成的 `.scriptable` 文件发到自己的 iPhone，用 Scriptable 打开并添加；专用脚本带当前课表，首次运行不需要再挑数据文件。之后重新导出，使用手机界面底部的“导入电脑更新的课表”导入新的 JSON。更改周次、临时调课和成绩更新需要重新同步数据；日常跨周由脚本计算。

如果同一 Apple 账户已启用 Scriptable 的 iCloud Drive，可把新 JSON 存在 `iCloud Drive/Scriptable/IMNU-widget/schedule.json`。脚本每次运行读取该位置并与本地、嵌入数据比较导出时间，选择最新有效数据；iCloud 未启用或下载失败保留离线副本。此仓库不自动创建 iCloud 服务或登录会话。

## 公开源码和无私人数据的下载包

```sh
node Mobile/tests.cjs
python3 Mobile/export-mobile.py --generic --output release-out/IMNU-iPhone-Widget-1.0.1
```

`core.js` 处理 Asia/Shanghai 日期、官网周锚、单双周、课程时间、状态和刷新边界。`widget.js` 仅调用 Scriptable 官方 API，`panel.html` 为离线完整课表。`export-mobile.py` 将其拼成单文件，并生成备用 JS、说明和 SHA256。专用包只能放在忽略的输出目录或仓库外，禁止提交私人课表。

测试覆盖数据逻辑、隐私字段过滤、Scriptable API 调用、各尺寸输出以及 Python 实际打包后的打开课表流程；浏览器检查也使用真实打包产物生成的页面和合成数据。在目标 iPhone 上已确认专用包 AirDrop 接收、Scriptable 导入、课表与成绩打开、中号小组件预览，以及主屏幕小组件的课程显示和点击直接打开课表。锁屏布局与后台刷新仍需分别验证。

1.0.1 修复了专用包导出时误替换页面数据标记的问题。已导入 1.0.0 的用户请导入新的 `.scriptable` 文件。Scriptable 会给同名脚本追加数字；请运行最新导入的脚本，并在“编辑小组件”中重新选择它。

官方参考：[ListWidget 与刷新限制](https://docs.scriptable.app/listwidget/)、[WidgetStack](https://docs.scriptable.app/widgetstack/)、[WebView](https://docs.scriptable.app/webview/)、[Scriptable App Store](https://apps.apple.com/app/scriptable/id1405459188)、[Apple AirDrop](https://support.apple.com/119857)。
