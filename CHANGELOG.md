# 变更日志

本项目所有重要变更均记录于此文件。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，并遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

## [1.0.0] - 2026-06-25

首次发布 🎉

### ✨ 核心功能

- 🔔 **Windows 原生通知**：通过 [BurntToast](https://github.com/Windos/BurntToast) 模块发送系统 Toast 通知
- 🖱️ **一键跳转回终端**：点击通知按钮直接激活 Windows Terminal（最小化、藏后台均可唤回）
- 🎯 **三种智能通知场景**，精准区分、按需打扰：
  - 🔴 **需要你的输入** —— Claude 正在提问（`AskUserQuestion`）
  - ⏳ **等待输入** —— Claude 问完了，等你回答
  - ✅ **任务完成** —— Claude 干完活了，回来看结果
- 📡 **`claudewt://` 自定义协议**：注册到 `HKCU`，点击通知即拉起终端

### 🛠️ 技术特性

- 🪟 **无闪窗激活链**：`claudewt://` 协议 → VBS 无窗口包装 → Win32 API（`SetForegroundWindow` + 模拟 Alt 键绕过前台锁定），点击丝滑置前、无 PowerShell 闪窗
- 🛡️ **健壮安装**：`settings.json` 预检前置到所有写操作之前，解析失败立即中止，绝不残留半安装状态
- 🔖 **会话级状态隔离**：按 `session_id` 区分不同会话，多开 Claude Code 时通知互不串台、不被覆盖
- 🔄 **零配置自动部署**：首次触发通知即自动注册协议、部署脚本、生成 VBS 包装，无需手动改注册表
- 📉 **优雅降级**：协议注册失败时自动退回基础通知，保证不哑火
- ⚡ **高频 hook 零抖动**：注册表校验加 24h TTL 缓存，跳过 PowerShell 冷启动，避免 `--mark-ask` 等高频事件的额外开销
- 🌐 **全平台兼容**：PowerShell 5.1 中文无乱码（脚本带 UTF-8 BOM）、WSL 路径精准部署（`wslpath` 转 UNC）、兼容 BurntToast 1.0+ / Node.js 12+ / Windows 10 (1903+) / Windows 11

### 🧪 工程质量

- ✅ **单元测试**：覆盖会话 ID 解析优先级、特殊字符清洗、超长截断及回归用例
- 🛡️ **协议注册表二次校验**：防止 marker 失效而协议已被覆盖的隐性故障
- ♻️ **安全卸载**：仅清理本项目文件，目录为空才删；写配置前自动备份 `.bak`
- 📖 **完整文档**：README 使用说明、技术设计文档、常见问题 FAQ
