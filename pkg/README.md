# pkg —— 安装包目录

把适合本机架构的官方 `.msix` 安装包放在这里，**无需改名**。以下是自动下载时使用的文件名：

- `ChatGPT-x64.msix`（Intel/AMD 64 位机器）
- `ChatGPT-arm64.msix`（骁龙等 ARM 机器）

脚本优先选择当前架构的上述文件名，否则选择最近修改的 `.msix` 文件。建议只保留本次要安装的包。

也可以直接运行根目录的 `下载ChatGPT安装包.bat` 自动下载到这里。

`ChatGPT-License.xml` 是官方离线授权文件，用于整机预置（`Add-AppxProvisionedPackage`）。
缺失或 XML 损坏时，安装脚本会自动改用 `-SkipLicense` 方式；当前用户安装不受影响。

安装包已在 `.gitignore` 中排除，不会被提交到仓库。
