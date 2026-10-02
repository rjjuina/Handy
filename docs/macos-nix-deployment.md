# macOS Nix 部署指南

本方案把职责分成两层：Nix 构建未签名的 `Handy.app` 和固定哈希模型；nix-darwin 在每台 Mac 上复制应用，再用该机器用户 Keychain 中的独立身份签名。私钥不会进入 Git、SOPS 或 Nix store。

## 1. Apple 原生工具

安装 Xcode Command Line Tools：

```sh
xcode-select --install
```

完整 Xcode 不是本地 Whisper 部署的必需项。Microphone、Accessibility 和 Input Monitoring 属于 macOS TCC 权限，首次启动后必须在 System Settings 中手工授权。

## 2. 每台 Mac 创建独立签名身份

使用 Keychain Access，选择 **Certificate Assistant → Create a Certificate**，并设置：

- Name：为本机选择唯一名称，例如 `Handy Local Signing - rmini`
- Identity Type：`Self Signed Root`
- Certificate Type：`Code Signing`
- 勾选 `Let me override defaults`
- Keychain：当前用户的 login Keychain

不要导出私钥，也不要把私钥交给 SOPS。取得证书的公开 SHA-256 指纹：

```sh
security find-certificate -c 'Handy Local Signing - rmini' -Z
security find-identity -v -p codesigning
```

证书名称和公开指纹不是秘密，可以放入该机器的 Nix 配置。模块会在每次签名前核对指纹；名称匹配但指纹不一致时，激活会失败。

## 3. 接入 dotfiles

先将经过审核的 Handy commit 推送到个人 fork，再在 dotfiles 的 `flake.nix` 中加入固定输入：

```nix
{
  inputs.handy = {
    url = "github:rjjuina/Handy/<commit>";
    inputs.nixpkgs.follows = "nixpkgs";
  };
}
```

将模块加入所有目标 Apple Silicon Mac 共用的 nix-darwin modules：

```nix
inputs.handy.darwinModules.default
```

在每台机器自己的配置中启用，并填写该机器的身份：

```nix
{
  programs.handy = {
    enable = true;
    signingIdentity = "Handy Local Signing - rmini";
    signingCertificateSha256 = "<64-character-public-SHA-256-fingerprint>";
  };
}
```

不要给 Intel Mac 启用当前模块；首期仅构建 `aarch64-darwin`。

## 4. 应用配置

执行 dotfiles 的正常 nix-darwin rebuild。模块将：

1. 从固定源码构建 Handy；
2. 校验并部署 Whisper Large v3 F16；
3. 把应用复制到 `~/Applications/Handy.app`；
4. 使用当前用户 Keychain 身份签名并严格验证；
5. 通过用户 launchd agent 以 `--start-hidden` 启动；
6. 设置 `HANDY_DISABLE_UPDATER=1`。

本 fork 在 macOS 上的首次默认值已经设为：

- `command_right`
- `PushToTalk`
- `HandyKeys`
- Whisper Large v3 F16
- 自动识别语言
- 不翻译为英语
- 不启用 always-on microphone

这些是首次创建配置时的默认值。若机器上已经有 Handy 设置，应用会保留现有设置；需要在 Handy UI 中确认或删除旧设置后重新初始化。模块不会覆盖用户运行时设置。

## 5. 首次权限与验收

首次启动后，在 System Settings 中给 `~/Applications/Handy.app` 授予：

- Privacy & Security → Microphone
- Privacy & Security → Accessibility
- Privacy & Security → Input Monitoring（若系统要求）

验证签名和运行状态：

```sh
codesign --verify --deep --strict "$HOME/Applications/Handy.app"
codesign -dv --verbose=4 "$HOME/Applications/Handy.app"
launchctl print "gui/$(id -u)/org.nixos.handy"
```

最后分别在 TextEdit、浏览器、终端和编辑器中测试：按住右 Command 录音，释放后转录到原光标位置；同时确认左 Command 和右 Command 组合键不触发录音。

## 6. 升级与恢复

- 升级：更新 dotfiles 中 Handy input 的 commit 和 lock file，再执行正常 rebuild。
- 回滚：使用 dotfiles 已有的 nix-darwin rollback 流程。模型和应用均由对应 generation 引用。
- 签名身份丢失：在该机器新建身份，更新公开指纹并重新授予 TCC 权限。不要从另一台 Mac 复制私钥。
- 模型删除：下一次 rebuild 会重新建立指向 Nix store 模型的链接，不会通过 Handy 自行下载。
