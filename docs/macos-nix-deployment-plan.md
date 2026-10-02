# macOS Nix 部署实施计划

## 目标

通过个人 Handy fork 和 nix-darwin，在多台 Apple Silicon Mac 上从源码构建、安装和配置 Handy。所有语音转录均在本地完成，使用 Whisper Large v3 F16，并以右 Command 键实现按住录音、释放转录。

目标使用流程：

```text
应用 dotfiles
  → Nix 从固定源码构建 Handy.app
  → nix-darwin 安装并通过 launchd 启动 Handy
  → 使用固定哈希的 Whisper Large v3 F16
  → 按住右 Command 录音
  → 释放后在本地转录
  → 将英语或中文文本输入当前光标位置
```

## 约束

- 只使用 Nix 和 nix-darwin管理构建、安装、升级及回滚。
- 从个人 fork 的固定 Git revision 构建，不使用官方预编译 Handy 二进制。
- 首期只支持 `aarch64-darwin`。
- 使用 Whisper Large v3 F16 和 Metal 加速。
- 模型文件使用固定 URL 和 SHA-256，由 Nix 获取并校验。
- 禁用应用内更新和云端后处理。
- 不把录音、转录历史、API 密钥或其他秘密写入 Nix store。
- Microphone 和 Accessibility 权限仅在首次安装时由用户授权；普通 nix-darwin 配置不能绕过 macOS TCC。
- 每个阶段形成一个可独立构建、测试和回滚的原子提交。
- 代码功能修改遵循测试先行；Nix 和文档修改通过构建及静态检查验证。

## 安全基线

- `flake.lock` 固定 nixpkgs、bun2nix 和其他构建输入。
- Cargo 和 Bun 依赖必须来自锁文件，不允许构建期间使用未固定的网络输入。
- 运行时设置 `HANDY_DISABLE_UPDATER=1`。
- 默认关闭 post-processing，且不配置任何云端提供商的 API 密钥。
- 默认关闭 always-on microphone；仅在用户按住快捷键时录音。
- 模型使用仓库目录声明的 SHA-256：

  ```text
  文件：whisper-large-v3-F16.gguf
  大小：3,107,236,640 bytes
  SHA-256：e633ab1d74b0e98f4f57daedaee34291297dbbf01389bda3d890766600c1c584
  ```

- 每台 Mac 在本机生成并长期使用独立的自签名 Code Signing 身份；临时 ad-hoc 签名仅用于开发验证。
- 签名私钥只能保存在对应 Mac 的用户 Keychain，不得进入 SOPS、Git、dotfiles、Nix store 或 derivation 输入，也不得跨机器复制。
- dotfiles 只保存非秘密的证书名称、预期公开指纹和签名流程。
- 打包后执行 `codesign --verify --deep --strict`。

## 阶段 1：建立 macOS Nix 构建

**目标**：从当前仓库通过 Nix 生成可启动的 Apple Silicon `Handy.app`。

**工作内容**：

- 将 `aarch64-darwin` 加入 flake 支持矩阵。
- 将 Linux 与 macOS 的构建依赖、环境变量和 bundle 配置分开。
- 使用仓库锁定的 Rust、Cargo、Bun 和前端依赖。
- 生成完整 Tauri app bundle，而不是仅生成裸二进制。
- 在 macOS 构建中启用 Metal，并排除 Linux 专用依赖。
- 在应用启动环境中设置 `HANDY_DISABLE_UPDATER=1`。
- 保留开发用 ad-hoc 签名路径，为后续稳定签名预留明确接口。

**成功标准**：

- `nix build .#packages.aarch64-darwin.handy` 成功。
- 输出包含结构完整的 `Handy.app`。
- `Handy.app` 能启动且不会缺失图标、声音、VAD 模型或其他 Tauri resources。
- 应用识别 Metal backend。
- 应用内更新不可用。

**验证**：

```sh
nix build .#packages.aarch64-darwin.handy
codesign --verify --deep --strict result/Applications/Handy.app
```

**状态**：构建完成；最终启动验收等待阶段 5 的本机签名和 TCC 授权

## 阶段 2：声明式部署 Whisper Large v3 F16

**目标**：每台 Mac 使用由 Nix 固定并校验的最高精度 Whisper 模型。

**工作内容**：

- 为 `whisper-large-v3-F16.gguf` 创建独立 fixed-output derivation。
- 使用模型目录中的精确 SHA-256，不接受运行时下载替代路径。
- 通过稳定、只读的模型路径让 Handy 发现该模型。
- 将默认模型设置为 `whisper-large-v3` F16。
- 将识别语言设置为 `auto`，关闭“翻译为英语”。
- 避免每次应用升级重新复制 3.1 GB 模型。

**成功标准**：

- 模型哈希错误时 Nix 构建明确失败。
- 模型只在 Nix store 保存一份。
- Handy 启动后将模型显示为已安装并默认选中。
- 断网后仍能完成英语和普通话转录。
- 中文输出保持中文，不自动翻译成英文。

**验证**：

```sh
nix build .#packages.aarch64-darwin.whisper-large-v3-f16
nix-store --verify-path result
```

另做两段固定音频回归测试：一段英语、一段普通话。记录转录结果和耗时，作为后续升级基线。

**状态**：模型 derivation 与哈希验证完成；部署链接等待阶段 4 模块验收

## 阶段 3：右 Command 按住说话

**目标**：单独按住右 Command 开始录音，释放后停止录音并转录，同时不破坏正常 Command 组合键。

**工作内容**：

- 先为左右 Command 区分和按键生命周期添加失败测试。
- 使用 `HandyKeys` backend，而不是不支持 modifier-only 的 Tauri backend。
- 将 shortcut activation 设置为 `PushToTalk`。
- 检查快捷键录制、序列化、存储和恢复全过程是否保留“右侧”信息。
- 如果方向信息被 UI 转换丢失，修复单一数据路径，不增加兼容层。
- 确保右 Command 与其他键组合时不开始录音，也不吞掉系统快捷键。
- 覆盖 Secure Input、应用失焦、睡眠和异常释放场景，避免 Command 键卡住。

**成功标准**：

- 单独按下右 Command：开始录音。
- 保持右 Command：持续录音。
- 释放右 Command：停止录音并开始转录。
- 单独按下左 Command：不触发录音。
- `Right Command+C/V/Tab`：不触发录音，原系统行为正常。
- 快速按下并释放仍产生一次有效录音生命周期，不留下卡键状态。
- Secure Input 开启或关闭后行为明确且可恢复。

**测试**：

- 单元测试：左右修饰键解析、序列化和匹配。
- 状态机测试：press、repeat、release、lost-release、组合键。
- macOS 集成测试：TextEdit、浏览器、终端和代码编辑器。

**状态**：默认配置和回归测试已实现并成功编译；测试执行受 Nix 测试进程 ONNX 动态库路径阻塞，真实按键集成验收等待阶段 5

## 阶段 4：nix-darwin 与 dotfiles 集成

**目标**：一条 dotfiles rebuild 命令完成应用、模型和登录启动配置。

**工作内容**：

- 为 Handy 增加 nix-darwin 模块，不复用 Linux systemd 模块。
- 将 `Handy.app` 声明式安装到当前用户的 `~/Applications`，以便用用户 Keychain 身份签名。
- 创建 `launchd.user.agents` 登录启动项，默认隐藏窗口并保留菜单栏入口。
- 通过模块声明模型路径和非秘密默认设置。
- 在 dotfiles 中加入个人 fork 的 flake input，并固定 revision。
- 在共享 Darwin 配置中启用 Handy，避免逐台复制配置。
- 保留必要的按机器覆盖能力，仅用于真实硬件差异。

**成功标准**：

- 在任意目标 Mac 上执行 `sdr` 即可安装或升级 Handy。
- 登录后 Handy 自动运行，且只存在一个实例。
- 应用和模型均来自当前 nix-darwin generation。
- `darwin-rebuild --rollback` 能恢复上一版本。
- 新机器除 macOS TCC 授权外不需要手工复制文件或运行安装命令。

**验证**：

```sh
nix build .#darwinConfigurations.$(scutil --get LocalHostName).system --dry-run
sudo darwin-rebuild switch --flake .#$(scutil --get LocalHostName) --impure --show-trace
launchctl print gui/$(id -u) | rg handy
```

**状态**：Handy 仓库模块与接入文档已完成；实际 dotfiles 接入等待发布固定 commit 和各机器证书指纹

## 阶段 5：签名、安全检查与端到端验收

**目标**：得到可在多台个人 Mac 上长期升级、权限稳定、完全离线工作的部署。

**工作内容**：

- 在每台 Mac 本地生成独立、长期有效的自签名 Code Signing 身份，并让私钥只存在于该机器的用户 Keychain。
- 在 dotfiles 中声明该机器预期的证书名称和公开指纹；签名前校验实际身份与预期值一致。
- 在 Nix store 外复制应用并使用当前用户的 Keychain 身份签名；不得使用 `sudo codesign`。
- 验证重建后 designated requirement 稳定，避免反复丢失 Accessibility 授权。
- 检查应用启动和转录期间的网络活动。
- 检查模型、应用、launchd 配置和运行时设置的所有权及权限。
- 完成英语、普通话、应用切换和光标粘贴端到端测试。
- 编写首次安装、TCC 授权、升级、回滚和故障恢复说明。

**成功标准**：

- 同一签名身份的升级不要求重新授予 Accessibility 权限。
- 每台机器使用不同的签名私钥，且任何私钥均未进入 SOPS、Git、dotfiles 或 Nix store。
- Microphone 权限只授予 Handy。
- 断网状态下所有核心功能正常。
- Handy 不执行自更新，不调用云端转录或后处理 API。
- 转录文本进入触发录音前拥有焦点的输入框。
- `nix flake check`、Rust 测试、前端 lint、格式检查和相关集成测试全部通过。

**验证**：

```sh
nix flake check
bun run lint
bun run format:check
cargo test --manifest-path src-tauri/Cargo.toml
codesign --verify --deep --strict /Applications/Handy.app
codesign -dr - /Applications/Handy.app
```

**状态**：构建、模型与签名安装链路已实现并完成静态验证；等待本机身份创建、TCC 授权及端到端验收

当前验证说明：发布应用已经成功构建，且其 ONNX runtime 已内嵌并改写为 bundle 相对路径。两个 macOS 回归测试已成功编译，但隔离测试进程在执行断言前未找到 `libonnxruntime`；连续三次测试基础设施尝试后已按工程规则停止。后续应把测试专用动态库环境作为正式 flake check，而不是继续使用临时 override。

## 风险与应对

### Apple SDK 不完全由 Nix 管理

macOS 构建仍依赖宿主机的 Xcode Command Line Tools 和 Apple SDK。Nix 固定开源依赖和构建流程，但不应宣称最终产物在不同 Apple SDK 版本间完全可重现。目标机器应使用一致的受支持 Xcode Command Line Tools 版本。

### Apple 原生工具边界

- Xcode Command Line Tools 是必需项：提供 macOS SDK、`codesign`、`security` 等系统工具。
- 完整 Xcode 是可选项：仅开发 Apple Intelligence/FoundationModels 集成时需要；本部署明确使用本地 Whisper。
- Swift 编译器由 nixpkgs 固定，只编译无 Apple Intelligence 的 stub bridge。
- Keychain 保存每台机器独立的签名私钥；`codesign` 在 Nix store 外签署安装副本。
- Microphone、Accessibility 和 Input Monitoring 权限由用户首次在 System Settings 中授予，Nix 不绕过 TCC。

### F16 模型资源消耗

Large v3 F16 文件约 3.1 GB，推理还需要额外内存。首期以至少 16 GB 内存的 Apple Silicon Mac 为目标。若存在 8 GB 机器，应将其作为明确的硬件配置分支，选择 Large v3 Q8；不得静默 fallback。

### modifier-only 快捷键冲突

右 Command 是系统修饰键。验收重点不是“能够触发”，而是“仅单独使用时触发，并且不破坏组合键”。若底层 blocking 模式无法同时满足两者，应暂停该阶段并重新评估事件监听方式，不能交付会吞键的实现。

### TCC 无法普通声明式授权

没有 MDM/PPPC 时，Microphone 和 Accessibility 必须由用户首次确认。部署文档应明确这一步，不尝试绕过系统安全机制。

### 每台机器独立签名身份

每台 Mac 使用独立的自签名 Code Signing 证书和私钥。私钥在本机 Keychain 内生成并永久留在本机，不通过 SOPS 备份或分发。机器丢失或 Keychain 损坏后生成新身份，并重新授予该机器上的 Microphone 和 Accessibility 权限。签名发生在 Nix store 外，因此纯 Nix 构建产物与本机签名安装产物必须保持明确分层。

## 最终验收清单

- [ ] `sdr` 从个人 fork 构建并安装 Handy。
- [ ] Handy 登录后自动启动且只有一个实例。
- [ ] 运行版本来自当前 Nix generation。
- [ ] Whisper Large v3 F16 的 SHA-256 与声明一致。
- [ ] 断网可完成英语转录。
- [ ] 断网可完成普通话转录。
- [ ] 自动语言识别不会把中文翻译成英语。
- [ ] 按住右 Command 开始录音，释放后停止并转录。
- [ ] 左 Command 不触发录音。
- [ ] 右 Command 组合键行为正常。
- [ ] 文本进入原始光标位置。
- [ ] always-on microphone 已关闭。
- [ ] 应用内更新已禁用。
- [ ] 云端后处理已禁用且没有 API 密钥。
- [ ] 应用签名验证通过。
- [ ] 当前机器的签名证书公开指纹与 dotfiles 声明一致。
- [ ] 签名私钥仅存在于当前机器的用户 Keychain。
- [ ] 升级不破坏现有 TCC 授权。
- [ ] nix-darwin 回滚能够恢复上一版本。

## 未决问题

- 所有目标 Mac 是否均为 Apple Silicon，且至少配备 16 GB 内存？
- 是否要求在无网络环境完成首次部署？若是，需要增加二进制缓存或离线 closure 传输设计。
- 是否接受应用首次启动时手工授予 Microphone 和 Accessibility 权限？在没有 MDM 的情况下这是必要步骤。
