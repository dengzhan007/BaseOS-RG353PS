# 贡献指南 / Contributing

[简体中文](#简体中文) | [English](#english)

---

## 简体中文

感谢你愿意为 BaseOS RG353PS 做出贡献。本项目面向 **Anbernic RG353PS（Rockchip RK3566）**，欢迎围绕平台适配、系统服务、硬件功能、前端兼容性、构建流程、测试和文档提交改进。

### 开始之前

1. 阅读项目首页和 [RG353PS 平台文档](platforms/rg353ps/README.md)，了解当前系统结构、硬件状态和已知限制。
2. 检查现有 Issues 和 Pull Requests，避免重复工作。
3. 对涉及启动流程、分区布局、A/B 更新、USB 模式或硬件接口的重大改动，请先开 Issue 讨论设计和兼容性，再开始实现。
4. 请明确区分已经验证的行为、基于代码或日志的推断，以及尚未验证的实验性实现。

### 贡献范围

欢迎以下类型的贡献：

- RG353PS 专用硬件适配、设备树、内核配置和驱动问题修复。
- 启动流程、系统服务、存储挂载、前端发现和 A/B 更新机制改进。
- USB MTP、Mass Storage、USB 网络调试等功能的修复和测试。
- 前端启动适配与兼容性改进，但请保持 BaseOS 与前端各自的职责边界。
- 自动化测试、构建流程、故障诊断和技术文档改进。

### 开发与构建验证

项目的构建入口、脚本和依赖以仓库当前版本为准。请从仓库根目录运行对应的 RG353PS 构建脚本；提交前至少完成与改动相关的静态检查或自动化测试。

- Shell 脚本改动应通过 `sh -n` 语法检查。
- 涉及 USB 行为的改动，应运行对应 USB 测试脚本，并检查 GitHub Actions 结果。
- 涉及镜像、升级包或分区布局的改动，应验证构建产物和更新流程；不要仅以“脚本运行成功”代替产物验证。
- 涉及硬件的改动，尽可能在 RG353PS 实机上验证，并在 PR 中说明设备、系统版本、测试步骤和结果。
- 如果没有实机，请明确标注“未进行实机验证”，不要将构建成功描述为硬件功能已验证。

### 平台设计约定

- **平台隔离：** RG353PS 专用逻辑应放在对应的平台目录或清晰隔离的适配层中，避免无必要地影响其他 BaseOS 平台。
- **职责边界：** BaseOS 负责设备启动、系统服务、存储挂载和前端发现；游戏扫描、ROM 格式识别、游戏列表与游戏启动由前端负责。
- **存储布局：** 不要把某个前端当前的目录限制写成 BaseOS 对所有前端的通用要求。新增或调整前端适配时，应记录其实际存储根目录和跨卡行为。
- **用户数据安全：** 更新和启动流程不得无故格式化、覆盖或删除用户数据。涉及分区、挂载和升级的改动应说明失败场景及回滚行为。
- **文档同步：** 修改用户可见行为、默认配置、按键操作、安装方式或硬件支持状态时，应同步更新相关文档。

### Pull Request 要求

PR 请尽量包含以下信息：

1. **目的：** 要解决的问题或增加的能力。
2. **实现：** 主要修改点，以及涉及的脚本、服务、驱动或平台组件。
3. **验证：** 执行过的测试、构建任务和对应结果。
4. **实机状态：** 是否在 RG353PS 实机验证；若已验证，请提供测试条件和结果。
5. **兼容性与风险：** 对现有安装、用户数据、更新流程和其他前端的影响。
6. **文档：** 相关说明是否已同步更新。

请保持 PR 聚焦，避免将互不相关的重构、功能和格式化修改混在同一个提交中。

### Bug 报告

提交问题时，请尽可能提供：

- 设备型号（本项目目标设备为 RG353PS）。
- BaseOS 版本、构建来源或 Git commit。
- 使用的前端及其版本（如问题与前端有关）。
- 清晰的复现步骤、预期行为和实际行为。
- 相关日志、截图或测试结果。
- 是否能在全新安装或另一张 TF 卡上复现。

上传日志前请检查并删除 Wi-Fi 密码、密钥、个人网络信息及其他敏感数据。

### 文档与验证状态

文档中的功能状态应准确表达证据强度：

- **实机验证：** 已在 RG353PS 硬件上按明确步骤验证。
- **构建/自动化验证：** 已通过构建或自动化测试，但没有完成对应实机验证。
- **实验性/待验证：** 已实现或正在开发，尚未证明在目标设备上可靠工作。

不要将代码存在、设备树条目存在或构建成功等同于功能已经在实机可用。

---

## English

Thank you for your interest in contributing to BaseOS RG353PS. This project targets the **Anbernic RG353PS (Rockchip RK3566)**. Contributions are welcome in platform support, system services, hardware integration, frontend compatibility, build workflows, testing, and documentation.

### Before you start

1. Read the project README and the [RG353PS platform guide](platforms/rg353ps/README.md) to understand the system architecture, hardware status, and known limitations.
2. Check existing Issues and Pull Requests to avoid duplicate work.
3. For significant changes to boot flow, partition layout, A/B updates, USB modes, or hardware interfaces, open an Issue first to discuss the design and compatibility implications.
4. Clearly distinguish behavior verified on hardware from conclusions inferred from code or logs, and from experimental work that has not yet been verified.

### Areas of contribution

Useful contributions include:

- RG353PS hardware support, device-tree changes, kernel configuration, and driver fixes.
- Improvements to boot flow, system services, storage mounting, frontend discovery, and A/B updates.
- Fixes and tests for USB MTP, Mass Storage, and USB network debugging.
- Frontend launch adapters and compatibility improvements, while preserving the responsibility boundary between BaseOS and frontends.
- Automated tests, build workflows, diagnostics, and technical documentation.

### Development and build validation

Use the build entry points, scripts, and dependencies provided by the current repository revision. Run the relevant RG353PS build scripts from the repository root. Before submitting, complete static checks or automated tests related to your changes.

- Shell script changes should pass `sh -n` syntax checks.
- USB behavior changes should run the relevant USB test scripts, and the GitHub Actions results should be checked.
- Image, update-package, or partition-layout changes should include validation of the generated artifacts and update flow. A successful script exit alone is not artifact validation.
- Hardware-related changes should be tested on an RG353PS device whenever possible. Include the device, system version, test steps, and results in the PR.
- If you do not have the device, explicitly state that hardware testing was not performed. A successful build must not be presented as proof of hardware functionality.

### Platform design conventions

- **Platform isolation:** Keep RG353PS-specific logic in the corresponding platform directory or a clearly isolated adapter layer. Avoid unnecessary impact on other BaseOS platforms.
- **Responsibility boundary:** BaseOS handles device boot, system services, storage mounting, and frontend discovery. Game scanning, ROM identification, library presentation, and game launching belong to the frontend.
- **Storage layouts:** Do not turn a current frontend's directory constraint into a universal BaseOS requirement. When adding or changing an adapter, document its actual storage root and multi-card behavior.
- **User-data safety:** Boot and update flows must not format, overwrite, or delete user data without a clear requirement. Changes involving partitions, mounts, or updates should document failure cases and rollback behavior.
- **Documentation:** Update the relevant documentation when changing user-visible behavior, defaults, button operations, installation procedures, or hardware support status.

### Pull Request checklist

Please include the following where applicable:

1. **Purpose:** The problem being fixed or capability being added.
2. **Implementation:** Main changes and affected scripts, services, drivers, or platform components.
3. **Validation:** Tests and build jobs run, with their results.
4. **Hardware status:** Whether the change was tested on an RG353PS device; include conditions and results if tested.
5. **Compatibility and risk:** Impact on existing installations, user data, update flow, and other frontends.
6. **Documentation:** Whether related documentation has been updated.

Keep PRs focused. Avoid combining unrelated refactoring, features, and formatting changes in one submission.

### Bug reports

When reporting a bug, include as much of the following as possible:

- Device model (RG353PS is the target device for this project).
- BaseOS version, build source, or Git commit.
- Frontend and version, if the issue is frontend-related.
- Clear reproduction steps, expected behavior, and actual behavior.
- Relevant logs, screenshots, or test results.
- Whether the issue can be reproduced on a clean installation or another TF card.

Before uploading logs, remove Wi-Fi passwords, keys, personal network information, and other sensitive data.

### Documentation and validation status

Documentation should accurately communicate the strength of the available evidence:

- **Hardware verified:** Tested on RG353PS hardware using explicit steps.
- **Build/automated validation:** Build or automated tests passed, but the corresponding hardware behavior has not been verified.
- **Experimental/unverified:** Implemented or under development, but not yet demonstrated to work reliably on the target device.

The presence of code, a device-tree entry, or a successful build does not by itself mean that a feature is usable on real hardware.
