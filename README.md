# Shot

一个 macOS 菜单栏截图工具。没有网络代码，没有第三方依赖，源码很短，可以自己读完再用。

## 功能

- 全局快捷键（默认 ⌃⌥A 选区、⌃⌥W 窗口、⌃⌥S 全屏），可在 Settings 里修改
- 截图后屏幕冻结，在原位置框选；选区固定后可用手形工具移动，拖动四角和四边的手柄调整大小
- 窗口截图：鼠标移到窗口上即高亮，点一下选中
- 标注：矩形、椭圆、直线、箭头、画笔、荧光笔、文字（回车换行，⌘回车或 Esc 结束）、序号（自动递增的圆圈数字）、马赛克
- 标注可拖动、可删除；粗细分 S/M/L 三档，样式可选实线、虚线、填充；选中标注时改粗细和样式会直接作用到它
- 画笔和荧光笔：按住 ⇧ 拖动，笔迹锁成水平或竖直的直线
- ⌘Z 撤销、⌘⇧Z 重做；方向键微调选中的标注（没有选中标注时微调选区），⇧加方向键一次 10 点
- 复制到剪贴板，或保存到自选文件夹（默认 `~/Pictures/Shot`）；格式可选 PNG、JPG、HEIC，文件名可用模板（`{date}`、`{time}`、`{n}` 序号）
- 工具栏里的拖出图标：把截图直接拖进聊天窗口、Finder、文档，不用先复制
- 贴图（Pin）：点工具栏的图钉，选区（含标注）变成浮在所有窗口上面的小窗，位置不变。拖动移动、滚轮缩放、双击或 Esc 关闭、右键可复制、保存、调透明度；菜单栏有「Close All Pins」
- 延时截图：快捷键（默认 ⌃⌥D）按 Settings 里选的时长（3、5、10 秒，默认 5）倒计时，结束后冻结屏幕并自动选中上次的选区（还没有记录时是普通选区），倒计时中按数字键 0 到 9 可从该秒数重新倒计时（0 为 10 秒），再按一次快捷键、按 Esc 或点倒计时可取消；菜单栏「Other Delays」可单次选别的时长。用来截菜单、悬浮提示
- 「Repeat Last Region」快捷键（默认 ⌃⌥R）：冻结屏幕后直接选中上次确认的区域，适合在同一位置反复截图
- 可选：复制后若干秒自动清空剪贴板、开机自启、隐藏菜单栏图标（再打开一次 App 即可呼出设置）
- 默认保留 Retina 分辨率；Settings 里可改用 1x 以降低内存

## 构建与安装

需要 Xcode 命令行工具（Swift 5.9+），macOS 13+。

```sh
./build.sh                      # 生成 Shot.app（本机临时签名）
cp -R Shot.app /Applications/
```

首次截图时 macOS 会请求「屏幕录制」权限。因为是临时签名，每次重新构建后权限会失效，需要在系统设置里重新授权。

## 项目结构

```
Sources/Shot/
  main.swift            程序入口、菜单栏图标和菜单
  Capture.swift         抓屏流程：冻结屏幕、检测窗口
  Countdown.swift       延时截图的倒计时
  Pin/PinWindow.swift   贴图窗口与管理
  Annotation.swift      标注的数据模型、绘制与点击检测
  Overlay/
    Overlay.swift       覆盖层窗口的创建、复用与关闭
    OverlayView.swift   框选、移动与拉伸选区、标注、工具栏
    OverlayLayers.swift 截图图层与标注图层
    Handle.swift        选区四角和四边的手柄
    DragHandle.swift    把截图拖出覆盖层的图标
  Shortcuts.swift       全局快捷键的保存与注册
  SettingsWindow.swift  设置窗口
  Preferences.swift     保存目录、Retina 等设置项
  Clipboard.swift       复制到剪贴板与自动清除
  Output.swift          保存格式、文件名模板、不重名
icon/                   图标脚本与图标素材
tools/leak-check.sh     内存回归测试
build.sh                构建并签名 Shot.app
```

## 实现说明

- 抓屏使用系统自带的 `/usr/sbin/screencapture`（只用来抓一张整屏图，选区、窗口检测与标注都是 Shot 自己做的）。
- 图标由 `icon/make-icon.swift` 绘制，`build.sh` 会调用它并用 `iconutil` 合成 `.icns`。`icon/` 里还有浅色/深色预览和分层素材。
- 覆盖层的窗口和视图全程只创建一个，每次截图往里装图、关闭时释放。原因是这个系统版本的 AppKit 会让创建过的视图一直保持可达，每次新建都会把整屏截图留在内存里（约 22 MB/次）。

## 测试

`tools/leak-check.sh` 把「框选、拉伸、标注、导出、关闭」整套流程重复 40 次，检查内存有没有持续增长（限额 6 MB）。改动覆盖层相关代码后建议运行一次，需要图形界面的登录会话。

```sh
./tools/leak-check.sh        # 默认 40 轮；也可以传入轮数
```

## 许可证

[MIT](LICENSE)
