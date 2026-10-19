---
name: handtodo-package
description: 为 HandTodo（掌上待办）执行可复用的 Mac、Windows 或双平台打包，生成安装包、验证记录与校验码。用户说“打包”“出安装包”“发给朋友”“打 Mac/Windows 包”且上下文属于 HandTodo 时使用。
---

# HandTodo 打包

使用项目内的 `package.sh` 和 `Distribution/package.py`，不临时拼装构建命令。这个 Skill 只处理 HandTodo，不用于其他项目。

## 定位与选路

项目根目录需包含 `VERSION`、`package.sh`、`Sources/` 与 `Windows/`。当前目录为父目录时检查 `HandTodo/`；本机已知项目位于 `/Users/master/Documents/Achoo/HandTodo`，使用前验证文件存在。

- 用户只说“打包”：`./package.sh all`。
- 只要 Mac：`./package.sh macos`。
- 只要 Windows：`./package.sh windows`。
- 用户明确给版本：追加 `--version x.y.z`；否则读取 `VERSION`，不擅自升版。
- 用户只要查看流程：`./package.sh --dry-run`；只检查环境：`./package.sh --check`，这两个操作不构建、不联网。

首次执行或修改流程后，先读 `Distribution/打包流程.md`；普通重复打包无需重读整个实现。

## 执行与验证

1. 运行所选命令，等待本次任务结束；不要因为脚本暂时无输出就启动第二个打包任务。
2. Windows 默认验证策略：Windows 本机原生检查；Mac 交叉构建后读取或触发 GitHub Actions 对同一提交的原生检查。只有 `manifest.json` 写明 `passed` 才报告已验证。云端验证需干净且已同步的提交。
3. 云端验证不能成立时，说明具体原因。只有用户明确接受未验证包时才用 `--windows-test skip`，并在交付中明确说明；不得把交叉编译成功说成 Windows 已运行通过。
4. 读取脚本返回的本次输出目录、`manifest.json`、`SHA256SUMS.txt`；确认请求的平台都在其中。失败任务不更新 `latest.json`，因此失败时不能拿旧 latest 当本次成果。
5. 交付本次文件的绝对路径链接，简述适用平台、安装方式和真实签名状态。安装包不包含个人待办或涂画。

## 边界

打包不等于发布：脚本不会提交、推送 Git、创建 Release 或上传安装包。仅在用户已授权相应操作时另行执行；不要把 Skill 本身当作推送或发布授权。

不要修改图案、业务交互或用户数据来“顺便优化”打包。流程失败时检查本次 `logs/` 和错误记录，修复对应问题后重跑；不要绕过失败的验证或无限重跑远程任务。
