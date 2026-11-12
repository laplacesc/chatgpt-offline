# ChatGPT 桌面版离线安装工具

一套 Windows 小脚本，帮你在**不打开微软商店**的前提下，下载、安装、卸载 ChatGPT 桌面版（MSIX）。

全部操作双击 `.bat` 即可完成，不需要懂命令行。

> 适用场景：内网/离线机器、商店被禁用或登录不上、批量装机、安装卡住需要干净重来。

---

## 适用环境

| 项目         | 要求                                                                      |
| ---------- | ----------------------------------------------------------------------- |
| 操作系统       | Windows 10 Build 19041（2004 版）及以上 / Windows 11                          |
| CPU 架构     | x64 或 arm64（不支持 32 位）                                                   |
| 磁盘空间       | 建议至少预留 3 GB，实际需求随安装包版本变化                                                |
| 权限         | 含打包系统服务的版本必须以管理员身份安装；`.bat` 会自动请求管理员权限                                  |
| PowerShell | 安装/卸载使用系统自带的 Windows PowerShell 5.1；`.bat` 会自动选择，已安装 PowerShell 7 也不受影响 |

> 2026-11-11 实机测试：Windows 11 Build 26200 + Windows PowerShell 5.1，x64，安装 26.1103.7773.0 耗时约 54 秒。最低 Build 19041、arm64、自定义安装盘仍需对应环境实测；实际系统要求也受安装包清单约束。

---

## 快速开始

### 情况一：已经有 MSIX 安装包

1. 将适合本机架构的 `.msix` 安装包直接放进 `pkg\` 目录，**无需改名，脚本会自动识别**。
2. 双击 **`安装ChatGPT桌面版.bat`**，在 UAC 弹窗点「是」。
3. 等待 1–5 分钟，看到绿色的「安装成功」即可。按 Win 键搜索 `ChatGPT` 启动。

### 情况二：还没有安装包

1. 双击 **`下载ChatGPT安装包.bat`**，从 OpenAI 官方源下载；中断后重跑会重新完整下载，避免固定地址更新后拼接不同版本。
2. 再双击 **`安装ChatGPT桌面版.bat`**。

也可以通过下文的[微软官方下载页面或 Microsoft Store 链接生成器](#安装包来源与校验)手动获取安装包，下载后按「情况一」安装。

### 卸载

双击 **`卸载ChatGPT桌面版.bat`**。默认不主动删除 `%LOCALAPPDATA%\OpenAI` 和 `%USERPROFILE%\.codex`。Windows 会在卸载过程中管理打包应用数据目录，实测 `%LOCALAPPDATA%\Packages\OpenAI.Codex_*` 随卸载被删除，因此**不保证保留登录状态**；重要数据请先备份。

---

## 目录结构

```
chatgpt-offline/
├─ 安装ChatGPT桌面版.bat        ← 安装入口（自动请求管理员权限）
├─ 卸载ChatGPT桌面版.bat        ← 卸载入口（自动请求管理员权限）
├─ 下载ChatGPT安装包.bat        ← 下载入口（无需管理员）
├─ scripts/
│  ├─ common.ps1                 公共函数：环境检测、包解析、错误码翻译
│  ├─ launch-chatgpt-desktop.ps1  提权、等待子进程、核对结果并反馈失败
│  ├─ install-chatgpt-desktop.ps1
│  ├─ uninstall-chatgpt-desktop.ps1
│  └─ download-chatgpt-msix.ps1
├─ pkg/                          安装包与离线授权文件存放处
│  ├─ 任意文件名.msix            安装包无需改名（已在 .gitignore 中排除）
│  └─ ChatGPT-License.xml        离线授权文件，用于整机预置
└─ log/                          每次运行的完整日志，排查问题时看这里
```

---

## 安装脚本做了什么

1. **环境自检** — 系统版本、CPU 架构、管理员权限、磁盘余量，任一不满足就明确告诉你缺什么。
2. **校验安装包** — 直接读取 MSIX 内部的 `AppxManifest.xml`，确认包标识、版本、架构与本机匹配；体积异常（下载不全）会被拦下。
3. **校验数字签名和官方身份** — 签名必须有效，清单包名必须是 `OpenAI.Codex`，清单发布者和签名主体必须同时匹配下文的 OpenAI 发布者标识。查询已安装包时同时限定发布者和包族；`-Force` 不会跳过身份、签名或架构检查。
4. **处理旧版本** — 同版本跳过、低版本升级、高版本降级前先征求确认。降级使用 [`Add-AppxPackage -ForceUpdateFromAnyVersion`](https://learn.microsoft.com/en-us/powershell/module/appx/add-appxpackage?view=windowsserver2025-ps#-forceupdatefromanyversion) 就地部署，不预先卸载；宿主不支持时明确拒绝。降级只针对当前用户，跳过整机预置，不改变其他用户及已有预置版本。旧版应用对新版数据格式的兼容性由应用决定，降级前仍建议备份重要数据。
5. **开启旁加载** — 若系统策略禁止安装本地应用包，自动放行。
6. **安装** — 先给当前用户装好（立刻可用），再整机预置（新建的用户账户登录后也能直接用）。
7. **复查** — 确认包已注册、沙箱服务状态正常，并打印安装位置。

## 卸载脚本做了什么

除了常规卸载，还会清理标准卸载常留下的尾巴：

- 仅结束可执行文件路径位于已核实官方包目录内的后台进程；独立 Codex CLI、Chrome 和无法确认路径的进程会保留
- 管理员先取消整机预置，再移除**所有用户**的官方应用包；普通权限仅处理当前用户
- 确认目标应用包均已移除后，才清理残留的系统服务 `CodexSandboxService.OpenAI.Codex` 和当前用户失效的执行别名；包仍存在或状态无法确认时停止清理并返回失败
- 初始盘点及卸载后的服务查询都区分“服务不存在”和“查询失败”；`Get-Service` 没有返回对象时，必须由 `sc.exe query` 返回 `1060` 才能认定不存在。状态无法确认时返回失败，无包时也不会误报“无需卸载”
- 删除服务后复查其状态；拒绝访问、删除失败或仍等待删除均返回非零退出码，结果文件和入口会传播失败。普通权限不会修改共享服务；服务仍在时也会报告未完成，确认服务不存在时才可成功
- 保留 `-CleanFirewall` 参数兼容性，但不自动删除现有规则：本工具从未创建防火墙规则，也没有规则管理记录。即使程序路径、包身份、名称或 Allow/Block 类型匹配，也不能证明规则由本工具管理；用户自建及其他现有规则全部保留，并打印提示

---

## 参数用法（进阶）

`.bat` 后面跟的参数会传给 PowerShell 脚本；安装入口会先将 `-InstallDrive D:\` 规范化为 `D:`，避免尾随反斜杠与引号影响后续参数。也可以直接调用 `.ps1`。
安装与卸载脚本请使用 `powershell.exe`，不要使用 `pwsh`。直接从 PowerShell 7 运行 `.ps1` 时，脚本会提示正确的调用方式。

通过入口提权时，脚本会记录发起账户 SID，并在子进程部署或清理前核对。UAC 中输入其他管理员账户的凭据会被拒绝，避免给其他账户安装或删除其配置；请在发起账户本身具有管理员权限的环境中操作。自行在另一账户下启动的管理员终端按该终端账户执行。

### 安装

| 参数                   | 作用                              |
| -------------------- | ------------------------------- |
| `-PackagePath <路径>`  | 指定安装包位置，不从 `pkg\` 找             |
| `-InstallDrive <盘符>` | 安装到指定本地 NTFS 磁盘，如 `D:`；自动跳过整机预置 |
| `-Force`             | 跳过确认，强制覆盖安装；不会绕过官方身份、签名或架构校验    |
| `-SkipProvision`     | 只装给当前用户，不做整机预置                  |
| `-NoPause`           | 结束后不等待按键（适合脚本化/批量装机）            |

```powershell
# 静默装机
powershell -ExecutionPolicy Bypass -File scripts\install-chatgpt-desktop.ps1 -Force -NoPause

# 安装到 D 盘（在仓库目录打开终端执行）
.\安装ChatGPT桌面版.bat -InstallDrive D:
# D:\ 及带引号的盘根也合法；后续开关会继续传递
.\安装ChatGPT桌面版.bat -InstallDrive "D:\" -NoPause -Force
```

指定安装盘时，包目录由 Windows 管理，不能任意选择 `D:\Apps\ChatGPT` 这样的文件夹。脚本会检查目标盘的文件系统、联机状态和可用空间，首次使用该盘时自动创建应用卷。已有版本在其他盘时会尝试迁移；如果应用正在运行或 Windows 禁止移动该包，脚本会停止并显示错误。

选择安装盘只对本次当前用户安装生效；其他用户需要各自安装。脚本按目标盘检查约 3 GB 的包空间，Windows 部署服务仍可能使用系统盘和临时目录，C 盘完全满时需先清出必要空间。可用 `下载ChatGPT安装包.bat -OutDir D:\ChatGPT-pkg` 将下载文件放到其他盘，再通过 `-PackagePath D:\ChatGPT-pkg\ChatGPT-x64.msix` 指定安装包。

### 卸载

| 参数                 | 作用                                                        |
| ------------------ | --------------------------------------------------------- |
| `-Force`           | 跳过确认                                                      |
| `-RemoveUserData`  | 主动清理 `%LOCALAPPDATA%\OpenAI` 及打包数据残留；不加此参数也不保证打包数据或登录状态保留 |
| `-RemoveCliConfig` | 删除 `%USERPROFILE%\.codex`                                 |
| `-CleanFirewall`   | 兼容参数；本工具没有创建记录，保留全部现有防火墙规则并提示                             |
| `-NoPause`         | 结束后不等待按键                                                  |

```powershell
# 同时主动清理应用数据和 CLI 配置；现有防火墙规则保留
powershell -ExecutionPolicy Bypass -File scripts\uninstall-chatgpt-desktop.ps1 -Force -RemoveUserData -RemoveCliConfig -CleanFirewall
```

### 下载

| 参数                       | 作用                     |
| ------------------------ | ---------------------- |
| `-Arch auto\|x64\|arm64` | 目标架构，默认跟随当前系统          |
| `-OutDir <目录>`           | 输出目录，默认 `pkg\`         |
| `-Force`                 | 从固定地址重新下载当前资源；仍须通过全部校验 |

固定下载地址会滚动更新，本工具不对跨次运行的部分文件续传。下载内容先写入临时文件，通过长度（可获取时）、官方身份、架构和签名校验后才保存为 `.msix`。已有同长度文件也必须通过校验才会复用；损坏文件会在本次运行中重新完整下载。通过校验的旧包可能与远端新包同大小，默认复用不代表已检查更新，需要获取当前资源请加 `-Force`。更新失败时保留原有安装包。

离线授权文件也先下载到临时目录，通过 XML 完整性和 `License` 根元素检查后才替换。下载失败时保留原有有效授权；缺失或损坏的授权文件不会传给安装器，改用 `-SkipLicense` 方式预置。

---

## 安装包来源与校验

手动获取安装包可使用以下入口：

- [微软官方下载页面（Microsoft Store）](https://apps.microsoft.com/detail/9plm9xgg6vks)
- [Microsoft Store 链接生成器](https://store.rg-adguard.net/)（第三方工具）

下载适合本机架构（x64 或 arm64）的 `.msix` 文件后，直接放进 `pkg\` 目录即可，**不需要修改文件名**。目录内有多个安装包时，脚本优先选择 `ChatGPT-<当前架构>.msix`，否则选择最近修改的 `.msix` 文件；建议只保留本次要安装的包。

自动下载脚本使用以下 OpenAI 官方 CDN 地址，不做任何二次打包或修改：

- x64：`https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix`
- arm64：`https://persistent.oaistatic.com/codex-app-prod/ChatGPT-arm64.msix`
- 离线授权：`https://persistent.oaistatic.com/codex-app-prod/ChatGPT-License.xml`

2026-11-11 实机测试报告记录的 x64 安装包（历史验证样本，并非实时查询的最新版）：

| 项目      | 值                                                                  |
| ------- | ------------------------------------------------------------------ |
| 包标识     | `OpenAI.Codex`                                                     |
| 包族名称    | `OpenAI.Codex_2p2nqsd0c76g0`                                       |
| 包全名     | `OpenAI.Codex_26.1103.7773.0_x64__2p2nqsd0c76g0`                   |
| 显示名     | ChatGPT                                                            |
| 版本      | 26.1103.7773.0                                                     |
| 大小      | 约 1,012.3 MB（报告记录）                                                 |
| SHA256  | `C043C8032B7A1E6AB383252A910176405265AC3EDBC909218D875FB284DEA672` |
| 签名主体    | `CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B`（OpenAI 商店发布者标识）          |
| 商店签发 CA | Microsoft Marketplace CA G 022（报告记录，签名状态 Valid）                    |

自行核对：

```powershell
Get-FileHash .\pkg\ChatGPT-x64.msix -Algorithm SHA256
Get-AuthenticodeSignature .\pkg\ChatGPT-x64.msix | Format-List Status, SignerCertificate
```

> 版本会随官方更新而变化，历史 SHA256 不用于限制未来版本。`Status = Valid` 只能说明签名链受信任，还必须核对清单中的 `Name = OpenAI.Codex`、`Publisher = CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B`，以及签名主体与该发布者一致。安装和下载脚本均强制检查这些条件；已安装包查询还限定 `OpenAI.Codex_2p2nqsd0c76g0` 包族，`-Force` 不会放宽身份边界。

---

## 常见问题

**安装提示需要管理员权限（0x80073D28）？**
安装包包含系统服务组件，必须由管理员部署。请双击 `安装ChatGPT桌面版.bat`，在 UAC 弹窗确认；或右键选择「以管理员身份运行」。脚本会读取清单中的服务声明，在非管理员部署前给出提示；只有不含此类服务的旧包才可能按普通用户安装。`-SkipProvision` 仅跳过整机预置，不会取消系统服务的权限要求。

**通过 UAC 后窗口消失，安装似乎没有执行？**
入口会等待子进程并核对本次运行的结果文件；如果子进程没有写出结果、启动器被中断，或退出码不一致，原窗口会提示无法确认任务完成并返回非零退出码。请先检查 `log\`，再重试或右键选择「以管理员身份运行」。这种检测用于反馈失败，不能消除环境软件对进程的拦截；若外层窗口也被强制关闭，则无法在该窗口反馈。

**Windows 10 安装/卸载报 Appx 模块无法加载、`0x80131539`？**
旧入口会优先使用已安装的 PowerShell 7，而 Windows 10 的 Appx 模块在该环境可能无法加载。更新脚本后重新运行 `.bat`，入口会固定使用 Windows PowerShell 5.1。直接调用脚本时请使用 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\install-chatgpt-desktop.ps1`，卸载则换成对应的卸载脚本路径。

**C 盘空间不足，想安装到其他盘？**
使用 `安装ChatGPT桌面版.bat -InstallDrive D:`。目标盘需为本地固定磁盘、NTFS 格式，并留有足够空间；不要手动移动或修改 `WindowsApps` 下的文件。

**装完了，开始菜单里搜不到？**
按 Win 键直接输 `chatgpt`。若仍搜不到，注销一次再登录；整机预置的包需要重新登录才对已有账户生效。

**提示"应用正在使用中"（0x80073D02）**
ChatGPT 没完全退出。右下角托盘图标右键退出，或在任务管理器里结束 `ChatGPT.exe`，再重试。

**提示"无法安装此应用包"（0x80073CFD）**
系统禁止了旁加载。用管理员身份运行安装脚本，脚本会自动放行；也可手动到「设置 → 系统 → 开发者选项」打开"旁加载应用"。

**提示证书不受信任（0x800B0109）**
安装包在传输中损坏了。删掉 `pkg\` 里的 msix，重新运行下载脚本。

**下载到一半断了**
重新运行 `下载ChatGPT安装包.bat`，会重新完整下载。固定地址可能已经更新，旧片段不会与新版本拼接。长度或签名校验失败不会被当作完整包；普通重跑会重新下载。

**安装完成时提示"沙箱服务 [Stopped]"，是不是装坏了？**
正常。`CodexSandboxService.OpenAI.Codex` 由应用按需拉起，不是常驻运行，安装刚结束时处于停止状态是预期行为。

**卸载后服务还在**
脚本先确认应用包已经移除，才尝试删除残留服务。初始盘点和卸载后，服务查询报错或未返回对象都不会被当作“不存在”；只有独立的 `sc.exe query` 返回 `1060` 才确认不存在，否则本次失败并提示检查权限与日志。删除后也会复查；“已标记删除但尚未消失”表示需要释放服务句柄或重启后重试，本次仍返回失败。访问拒绝等实际错误会单独报告，不能假定重启必然解决。

**加了 `-CleanFirewall`，规则为何还在？**
本工具未创建防火墙规则，也没有可信的规则管理记录，因此此参数保留兼容性并提示，不自动删除任何现有规则。指向 ChatGPT 的自建 Block 或 Allow 规则同样保留；如需调整，请在 Windows 防火墙中自行检查。

**其他问题**
翻 `log\` 目录下对应时间的日志，里面有完整的执行记录和原始报错。
如果安装成功但启动后没有界面，请一并提供 `winver` 显示的系统版本、CPU 架构、安装日志，以及「事件查看器 → Windows 日志 → 应用程序」中启动时对应的错误（故障应用、故障模块和异常代码）。仅凭“打不开”无法区分注册问题与应用启动故障。

## 开发验证

在 Windows PowerShell 5.1 中运行全部隔离测试，无需安装真实应用或修改用户配置：

```powershell
powershell -NoProfile -File tests\run-regressions.ps1
```

总入口自动生成临时证据目录并打印路径，保存运行环境、各套件结果、子进程输出、异常类型/消息/内部异常/调用栈，以及下载小文件夹具。也可用 `-EvidenceDir C:\Temp\chatgpt-test-evidence` 指定目录。验证 PowerShell 7 时将命令换为 `pwsh`。各入口也可以无参数单独运行：

```powershell
powershell -NoProfile -File tests\source-validation.ps1
powershell -NoProfile -File tests\compatibility-regression.ps1
powershell -NoProfile -File tests\installer-regression.ps1
powershell -NoProfile -File tests\download-regression.ps1
```

安装回归使用临时包和模拟 Windows 接口，覆盖目标盘、已有版本迁移、服务权限，以及本轮的进程归属、卸载失败时保护组件、就地降级失败、官方发布者与包族、跨账户 SID、服务盘点/清理查询失败与删除结果，以及缺少管理记录时保留全部防火墙规则。模拟中有非空进程、服务和规则，包括指向官方包路径的自建 Block/Allow 规则、名称伪装或缺失及其他程序规则。Windows 下通过真实 `cmd.exe` 和 `powershell.exe` 执行完整 BAT，覆盖 `D:`、`D:\` 及带引号形式后的 `-NoPause -Force -SkipProvision` 和含空格/特殊字符的安装包路径。

下载回归在隔离子进程中运行真实脚本和真实 ZIP 清单解析，以确定性 HTTP/传输及签名边界模拟小文件，覆盖滚动地址旧片段、同大小损坏、校验失败后重跑、更新失败时保留旧包、授权下载中断或 XML 损坏时保留旧授权、三种下载引擎和 `-Force` 身份限制，不请求网络或下载大型 MSIX。失败用例还要证明命中了预期错误，不能只凭非零退出码通过。子进程结果经 UTF-8 JSON 文件传回，避免共享控制台编码影响中文断言；完整 BAT 在独立进程中运行，不修改后续测试的控制台代码页。跨账户测试按精确资源、删除调用栈和父子进程事件核对副作用，区分应用/CLI 数据与启动器自己的临时结果目录；TEMP 位于 AppData 下不能单独证明数据被删除。

源码检查验证 BOM、CRLF、解析及 PowerShell 5.1 语法边界。GitHub Actions 的 Windows PowerShell 5.1 和 PowerShell 7 两条腿均通过 `-File` 调用总入口，并保留诊断；配置存在不代表 CI 已通过。

2026-11-12 用户实机报告确认 Windows 11 x64 / Windows PowerShell 5.1 的 D1–D4 真实安装、启动、幂等、卸载、中断及取消 UAC 测试通过；报告同时记录了 D5–D7 的测试夹具与兼容问题。该历史结果不作为本轮改动的验收。此后本轮仅在 macOS PowerShell 7 上验证了隔离夹具；PS5.1 下载套件原有 9 项失败尚需新诊断在原生环境复核，不能宣称已定位或通过。双账户真实 UAC、MSIX 就地降级和失败恢复、实际服务查询权限与删除等待状态、原生下载引擎及本轮完整 BAT 隔离行为仍需对应环境验证。本工具不再查询或修改防火墙规则。

---

## 说明

- 本工具只负责**下载和部署**官方安装包，不修改、不破解、不绕过任何授权。使用 ChatGPT 仍需登录你自己的 OpenAI 账号。
- 与 OpenAI 无任何隶属关系，非官方项目。
- 实现思路参考自 [claude-code-desktop-offline](https://github.com/xqnode/claude-code-desktop-offline)。

## 许可

[CC BY-NC 4.0](LICENSE) — 可自由使用、修改、分享，但不得用于商业用途。
