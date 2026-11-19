# Segmeris 品牌资源

`assets/SegmerisLight.jpg` 和 `assets/SegmerisDark.jpg` 是两份独立原稿。桌面图标由原稿缩放生成。启动动画沿拟合的 Bézier 路径绘制，保留了亮版的圆头细线和暗版的带状轮廓。修改原稿后可用 Python 3.10+ 和 Pillow 运行 `python tools/generate_brand_assets.py`，在 `assets/brand/preview.png` 对照原图、矢量图和轮廓差异。几何变化还需同步到 Dart 与 Android 的路径，并运行品牌测试。

`SegmerisBootstrap` 在首帧后启动初始化。正常动效至少展示 500 毫秒，耗时较长时流线继续运动。减少动态效果时，启动页直接绘制完整图标，初始化完成即可进入首页。应用内品牌图形读取系统亮度，独立于用户为内容区选择的配色方案。

| 平台 | 显示位置与行为 |
| --- | --- |
| Android | 提供昼夜资源、adaptive icon 与 monochrome 图层。Android 12 起的原生启动页使用 AnimatedVectorDrawable。系统可缩短原生动效，桌面刷新和着色由 launcher 控制。[1][2] |
| iOS / iPadOS | 资源目录提供默认和 Dark 外观。主屏幕图标由支持版本上的用户外观设置决定。系统先显示静态 launch storyboard，Flutter 首帧开始矢量运动。[3][4] |
| Web | favicon、触屏图标和 manifest 跟随 prefers-color-scheme。已安装 PWA 的桌面图标刷新由浏览器管理。[5][6] |
| macOS | 运行中的 Dock 图标跟随 AppKit 外观。Finder 使用随应用分发的默认图标。[7] |
| Windows | 窗口创建和系统主题变更时通过 WM_SETICON 设置大小图标。Explorer 读取 EXE 的默认资源。[8] |
| Linux | GTK 窗口按当前 GTK 主题选择图标。便携包内的 share 目录包含桌面入口和 hicolor 资源，注册桌面入口时须确保 segmeris 可从 PATH 启动。[9][10] |

## 回归检查

```sh
python -m unittest discover -s test/branding -p '*_test.py'
node --test test/branding/web_brand_theme_test.cjs
flutter test test/app/brand_logo_test.dart test/app/startup_motion_test.dart
```

## 官方资料

1. [Android — Splash screens](https://developer.android.com/develop/ui/views/launch/splash-screen)（AVD 格式、尺寸、建议 ≤1000ms、提前跳过、动画时长不强制停留）。
2. [Android — Adaptive icons](https://developer.android.com/develop/ui/compose/system/icon_design_adaptive)（108dp layers、66dp 安全区、monochrome 与 launcher 控制的效果）。
3. [Apple — Configuring your app icon using an asset catalog](https://developer.apple.com/documentation/xcode/configuring-your-app-icon)（Single Size、Dark/Tinted、dark 透明前景）。
4. [Apple — Specifying your app’s launch screen](https://developer.apple.com/documentation/xcode/specifying-your-apps-launch-screen)（仅 UIKit、无代码连接／自定义类／runtime attributes）。
5. [MDN — prefers-color-scheme](https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/At-rules/@media/prefers-color-scheme)。
6. [MDN — Web app manifest icons](https://developer.mozilla.org/en-US/docs/Web/Progressive_web_apps/Manifest/Reference/icons)（支持 src、sizes、type、purpose）。
7. [Apple — NSApplication.applicationIconImage](https://developer.apple.com/documentation/appkit/nsapplication/applicationiconimage)。
8. [Microsoft — WM_SETICON](https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-seticon)。
9. [freedesktop.org — Desktop Entry recognized keys](https://specifications.freedesktop.org/desktop-entry/1.0/recognized-keys.html)（Icon 可用绝对路径或图标主题名称）。
10. [freedesktop.org — Icon Theme Specification](https://specifications.freedesktop.org/icon-theme/0.6/)（hicolor 回退、标准 apps 目录与安装机制）。
