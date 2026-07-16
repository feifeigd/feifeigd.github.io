---
title: "uni-app 离线 SDK 打包 Android APK 完整指南"
date: 2026-07-16T12:00:00+08:00
draft: false
tags: ["uni-app", "android", "hbuilderx", "mobile-development", "sdk"]
categories: ["Tech"]
description: "基于 HBuilderX 离线 SDK（5.15 版本）手动构建 uni-app Android APK 的完整流程，从编译资源到签名安装"
---

> 本文记录了 uni-app 项目通过 HBuilderX 离线 SDK 打包 Android APK 的全过程。适用于 5.15 版本 SDK，内容包括环境准备、Gradle 工程搭建、资源编译、签名配置、APK 构建及调试安装。如果你习惯 CLI 而非 GUI 打包，这篇就是为你准备的。

{/* truncate */}

---

## 背景

uni-app 官方提供了两种打包方式：

- **云端打包** — 在 HBuilderX 里点「发行 → 原生App-云打包」，省事但依赖网络、排队慢、不能自定义原生层代码
- **离线打包** — 下载 Android 离线 SDK，本地构建 APK，速度快、可定制、适合 CI/CD

本文围绕后者展开。离线打包的核心思路并不复杂：HBuilderX 只负责编译前端资源（WXML/WXSS/JS → app-service.js / app-view.js），然后把这些产物塞进一个标准的 Android Gradle 工程中，跟离线 SDK 提供的 AAR 基座一起编译出 APK。

---

## 环境

| 工具 | 路径 |
|------|------|
| HBuilderX CLI | `G:\HBuilderX\cli.exe` |
| 离线 SDK | `Android-SDK@5.15.82650_20260710.zip` |
| 签名证书 | `gala.jks` (alias: Gala, 密码: gala123) |
| ADB | `G:\Android\Sdk\platform-tools\adb.exe` |

离线 SDK 从 [官方下载页](https://nativesupport.dcloud.net.cn/AppDocs/usesdk/android.html) 获取，下载后解压到任意目录即可。

### 项目配置

| 配置项 | 值 |
|--------|-----|
| AppID | `__UNI__7AFEA31` |
| 包名 | `best.win365.games777` |
| 应用名 | Luckyspin777 |
| AppKey | `7aa06e6e03531b5772584d6b069bbaaf` |
| 版本 | 1.3.6 (code: 37) |

---

## 工程结构一览

离线打包工程是一个标准的 Android Gradle 项目，其核心结构如下：

```
android_project/
├── build.gradle                  # 根 build 配置
├── settings.gradle               # include ':simpleDemo'
├── gradle.properties             # android.useAndroidX=true
├── gradlew / gradlew.bat         # Gradle Wrapper
├── gradle/                       # Wrapper 依赖
└── simpleDemo/                   # App 模块
    ├── build.gradle              # 模块 build 配置（含签名、依赖）
    ├── gala.jks                  # 签名证书
    ├── proguard-rules.pro        # 混淆规则
    ├── libs/                     # 离线 SDK AAR（从 SDK 包提取）
    └── src/main/
        ├── AndroidManifest.xml   # 含 dcloud_appkey
        ├── res/
        │   ├── drawable/icon.png
        │   └── values/strings.xml
        └── assets/
            ├── data/
            │   ├── dcloud_control.xml    # appid 配置
            │   └── dcloud_properties.xml # 功能模块注册
            └── apps/
                └── __UNI__7AFEA31/
                    └── www/              # HBuilderX 编译产物
```

工程的精髓在 `libs/` 和 `assets/apps/` 两个目录：

- **`libs/`** — 离线 SDK 的基座运行时，包含 30+ 个 AAR 文件
- **`assets/apps/__UNI__7AFEA31/www/`** — uni-app 的前端编译产物

---

## 构建步骤

### 第 1 步：编译项目资源

```bash
G:\HBuilderX\cli.exe publish app \
    --project I:\game\rus-game\rus-client \
    --type appResource \
    --platform app
```

这条命令把 uni-app 项目编译为原生可用的静态资源。产物输出到 `unpackage/resources/__UNI__7AFEA31/www/` 目录，主要文件包括：

- `manifest.json` — 应用配置
- `app-service.js` — 逻辑层代码
- `app-view.js` — 视图层代码
- `view.umd.min.js` — UMD 视图运行时
- `static/` — 静态资源目录

### 第 2 步：复制资源到 Android 工程

```bash
rm -rf android_project/simpleDemo/src/main/assets/apps/
mkdir -p android_project/simpleDemo/src/main/assets/apps/__UNI__7AFEA31/www/
cp -r unpackage/resources/__UNI__7AFEA31/www/* \
      android_project/simpleDemo/src/main/assets/apps/__UNI__7AFEA31/www/
```

这步的本质是：把 HBuilderX 的编译输出「装进」Android 工程的 assets 目录里，让 native 层能通过路径加载前端资源。

### 第 3 步：构建 APK

```bash
cd android_project
gradlew.bat clean assembleRelease
```

产物路径：`simpleDemo/build/outputs/apk/release/simpleDemo-release.apk`，大小约 33MB。

`clean` 不是必须的，但建议每次都跑一下，避免缓存污染导致莫名其妙的构建问题。

### 第 4 步：安装运行

```bash
adb install -r -d simpleDemo/build/outputs/apk/release/simpleDemo-release.apk
adb shell am start -n best.win365.games777/io.dcloud.PandoraEntry
```

`-r` 覆盖安装，`-d` 允许降级（版本号比已安装的低时也能装）。启动 Activity 是 `io.dcloud.PandoraEntry`，这个是 5+ Runtime 的主入口。

---

## 关键文件详解

### 1. `simpleDemo/build.gradle`

模块级构建配置，核心内容：

```groovy
namespace 'best.win365.games777'
applicationId "best.win365.games777"

// 签名配置
keyAlias 'Gala'
keyPassword 'gala123'
storeFile file('gala.jks')
storePassword 'gala123'

// 5.15 SDK 专用依赖
implementation "com.facebook.fresco:fresco:3.4.0"
implementation "com.facebook.fresco:animated-gif:3.4.0"
```

> **特别注意**：Fresco 的版本必须与离线 SDK 版本匹配。5.15 要求 fresco `3.4.0`，版本不对会导致运行时崩溃。

### 2. `AndroidManifest.xml`

必须包含以下声明：

```xml
<!-- AppKey -->
<meta-data android:name="dcloud_appkey"
           android:value="7aa06e6e03531b5772584d6b069bbaaf"/>

<!-- 主入口 Activity -->
<activity android:name="io.dcloud.PandoraEntry"
          android:configChanges="orientation|keyboardHidden|screenSize"
          android:hardwareAccelerated="true"
          android:theme="@style/TranslucentTheme">
    <intent-filter>
        <action android:name="android.intent.action.MAIN"/>
        <category android:name="android.intent.category.LAUNCHER"/>
    </intent-filter>
</activity>

<!-- 内部跳转 Activity -->
<activity android:name="io.dcloud.PandoraEntryActivity"/>

<!-- Application -->
<application android:name="io.dcloud.application.DCloudApplication">
```

### 3. `dcloud_control.xml`

声明 appid 和版本号，HBuilder 原生层据此加载对应资源：

```xml
<hbuilder>
<apps>
    <app appid="__UNI__7AFEA31" appver="1.3.6"/>
</apps>
</hbuilder>
```

### 4. `dcloud_properties.xml`

注册 5+ Runtime 的功能模块。这个文件缺失或不完整会导致运行时提示「未添加 XX 模块」。需要声明的典型模块包括：

- **File** — 文件系统操作
- **Camera** — 相机拍照
- **Downloader** — 文件下载
- **OAuth** — 第三方登录
- **Maps** — 地图服务
- **Webview** — Webview 增强

---

## 离线 SDK 结构

从官方下载的 SDK 包解压后结构如下：

```
Android-SDK@5.15.82650_20260710.zip
│
├── SDK/libs/                     → 基座运行时（复制到 simpleDemo/libs/）
│   ├── lib.5plus.base-release.aar   核心 5+ Runtime
│   ├── uniapp-v8-release.aar        uni-app V8 渲染引擎
│   ├── breakpad-build-release.aar   崩溃捕获
│   ├── android-gif-drawable-1.2.29.aar
│   ├── oaid_sdk_1.0.25.aar          OAID 设备标识
│   ├── utsplugin-release.aar        UTS 插件运行时
│   ├── weex_*.aar / media*.aar     各功能模块（共 40+ 个）
│   └── ...
│
├── HBuilder-HelloUniApp/         → Demo 工程模板（参考用）
│   ├── app/build.gradle           参考依赖版本
│   ├── app/libs/                  参考 AAR 完整列表
│   ├── app/src/main/AndroidManifest.xml
│   └── ...
│
└── __MACOSX/                     （忽略）
```

| 子目录 | 用途 | 工程对应位置 |
|--------|------|-------------|
| `SDK/libs/` | 基座运行时（AAR 库），全部复制 | `simpleDemo/libs/` |
| `HBuilder-HelloUniApp/app/libs/` | 参考清单，与 SDK/libs 内容一致 | 同上 |
| `HBuilder-HelloUniApp/app/build.gradle` | 参考依赖版本 | `simpleDemo/build.gradle` |
| `HBuilder-HelloUniApp/app/src/main/` | 参考清单与资源结构 | `simpleDemo/src/main/` |

> **基座**就是 `SDK/libs/` 目录。`lib.5plus.base-release.aar` 是核心运行时，`uniapp-v8-release.aar` 是渲染引擎，其余 AAR 是功能插件。所有 AAR 必须全部复制到 `libs/`，然后在 `dcloud_properties.xml` 中声明要启用的模块。

---

## 常见踩坑

**1. Fresco 版本不匹配**

```
java.lang.NoClassDefFoundError: Failed resolution of: Lcom/facebook/drawee/...
```

解：检查 `build.gradle` 中的 `fresco` 版本是否与 SDK 版本匹配。

**2. dcloud_properties.xml 缺失模块**

```
未添加 Camera 模块
未添加 File 模块
```

解：对照 `HBuilder-HelloUniApp` 中的 `dcloud_properties.xml`，把需要的模块声明补全。

**3. 资源未正确复制**

APK 装上去白屏或页面空白，说明 `www/` 目录下的资源没复制对。

解：确认 `assets/apps/__UNI__7AFEA31/www/` 下有 `manifest.json` 和 `app-service.js` 这两个关键文件。

**4. AppKey 未正确配置**

启动闪退，日志显示 `appkey is invalid`。

解：检查 `AndroidManifest.xml` 中的 `dcloud_appkey` meta-data 是否与 AppID 匹配 — AppKey 是根据 AppID 在 HBuilder 开发者后台申请的，不对应就会闪退。

---

## 参考资源

- [官方离线打包文档](https://nativesupport.dcloud.net.cn/AppDocs/usesdk/android.html)
- [HBuilderX CLI 文档](https://hx.dcloud.net.cn/cli/publish-APP-appResource)
