# Android 正式签名（0.2.22 起）

这套密钥是 2026-11-18 新建的正式签名，供本仓库后续机器人直接导出并签名 Android 包。
**从 0.2.22 开始使用这张证书。** 它与 0.2.6–0.2.14 的旧正式证书不同：旧版安装需要先卸载再安装，否则系统会提示签名冲突（卸载会清除应用数据）。

## 文件

- 密钥库：`android/signing/tifa-yufu-release.keystore`（PKCS12）
- 环境变量：`android/signing/credentials.env`

## 凭据

- 别名（alias / `GODOT_ANDROID_KEYSTORE_RELEASE_USER`）：`tifa-yufu-release`
- 密钥库密码与密钥密码相同（`GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD`）：见同目录 `credentials.env`
- 算法：RSA 2048，SHA256withRSA，有效期 10000 天
- DN：`CN=蒂法玉腹沙盒, OU=zkr907999952-dev, O=zkr907999952-dev, C=CN`
- 包名：`com.zkr907999952.rouchang`
- 证书 SHA-256：`1C:08:10:C2:C1:65:F3:7F:42:9E:05:91:0A:BF:79:78:80:DE:25:16:A9:D5:AF:CC:29:7E:1B:72:C7:0C:BA:3D`

## 给后续机器人的导出步骤

不要把密码写进 `export_presets.cfg`，也不要提交 `build/` 或 `*.apk`。

1. `source /home/box/.godot-dev-env.sh`（或设置 `JAVA_HOME`、`ANDROID_HOME`）
2. `source android/signing/credentials.env`
3. 在仓库根目录执行：

```bash
mkdir -p build/android
LIBGL_ALWAYS_SOFTWARE=1 /home/box/bin/godot --headless --path . \
  --export-release Android build/android/蒂法玉腹沙盒-0.2.XX-android-arm64.apk
```

也可用 `android/signing/export-android-release.sh <versionName>`（例如 `0.2.22`）。脚本在导出后会用 `apksigner` 校验 v1 / v2 签名和正式证书指纹，失败则中止。

发布到 GitHub Releases：标签 `android-<version>`，资源名 `TifaYufuSandbox-<version>-android-arm64.apk`，并在说明里写明这是 0.2.22 起的新证书、旧版需先卸载。
