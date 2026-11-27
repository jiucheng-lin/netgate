# 贡献指南

感谢你考虑为 NetGate 做贡献。

## 开始前

NetGate 的定位是一个**通用**的应用联网管理工具。为了保持这个定位，请遵守：

- 不添加任何软件厂商/产品专属的规则名单、绕过逻辑或例外处理
- 不添加任何用于规避软件授权、版权保护机制的功能
- 不添加默认开启的遥测或数据上传
- 新增功能应对所有程序一视同仁，由使用者自己决定目标

## 开发环境

- Windows 8 / PowerShell 5.1 以上
- 无需安装额外依赖

## 代码约定

- PowerShell 脚本保持纯 ASCII 内容，避免 Windows PowerShell 5.1 读 UTF-8 无 BOM 时的乱码问题（说明文档可用 UTF-8）
- 不使用 PowerShell 7 专有语法（`??`、`?.`、三元运算符等）
- Windows 防火墙规则名只允许 `[A-Za-z0-9 _-]`，不要包含 `|`、`\` 等分隔符
- 规则统一使用 `NG-` 前缀，原路径存 Description 字段

## 提交流程

1. Fork 本仓库
2. 创建分支：`git checkout -b feature/你的功能`
3. 修改并自测
4. 提交：`git commit -m "简短说明"`
5. Push 到你的 Fork
6. 提 Pull Request，说明改了什么、为什么

## 报告问题

提 Issue 时请包含：

- Windows 版本
- PowerShell 版本（`$PSVersionTable.PSVersion`）
- 复现步骤
- 相关截图或日志（注意隐去你不想公开的本地路径）

## 行为准则

友善、尊重、就事论事。不接受任何形式的骚扰或歧视。
