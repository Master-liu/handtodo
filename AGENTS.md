# HandTodo 项目约定

## 打包请求

用户要求给 HandTodo 打包、出安装包或准备发给朋友时，先读 [.agents/skills/handtodo-package/SKILL.md](.agents/skills/handtodo-package/SKILL.md)，使用项目 `package.sh` 执行对应流程。

- 默认双平台；明确指定时只打该平台。
- 默认读取 `VERSION`，不擅自修改版本号。
- 交付本次输出目录里的文件，以 `manifest.json` 中的验证结果为准。
- 打包本身不包含自动提交、推送或发布权限；保留会话中已有的明确授权。

修改打包工具后运行 `python3 -m unittest discover -s Distribution/tests -v`，并实际执行受影响的平台流程。不要把用户的本机内容或备份打进分发包。
