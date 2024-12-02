# 大佐翻译官

一个优雅的 macOS 翻译工具，支持多种翻译服务和智能功能。

![版本](https://img.shields.io/badge/版本-1.0-blue.svg)
![平台](https://img.shields.io/badge/平台-macOS-lightgrey.svg)
![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)

<img width="929" alt="image" src="https://github.com/user-attachments/assets/289b7fa6-0a59-43ea-849a-1cc5d3af8ec0">

![QQ_1733133550883](https://github.com/user-attachments/assets/d3f97350-8a8c-492b-b7a1-35a4e0424141)

## 功能特性

### 核心功能
- 🌍 支持多种翻译服务
  - Google 翻译
  - DeepL 翻译（需要 API Key）
  - DeepSeek 翻译（需要 API Key）
- 🔄 自动语言检测
- ⌨️ 全局快捷键翻译
- 📋 快速复制翻译结果

### 智能功能
- 🧠 AI 理解分析（DeepSeek模式）
- 🎯 智能语言检测
- 📝 保持原文格式

### 界面特性
- 🌓 深色模式支持
- 🎨 优雅的用户界面
- ✨ 流畅的动画效果
- 🔄 实时翻译更新

## 系统要求
- macOS 13.0 或更高版本
- 约 50MB 可用存储空间

## 安装说明
1. 下载最新的 DMG 安装包
2. 打开 DMG 文件
3. 将应用程序拖入 Applications 文件夹
4. 首次运行时授予必要权限：
   - 辅助功能权限（用于全局快捷键）
   - 网络访问权限（用于在线翻译）

## 使用指南

### 基本使用
1. 选择翻译服务（Google/DeepL/DeepSeek）
2. 选择源语言和目标语言
3. 输入或粘贴要翻译的文本
4. 翻译结果会自动显示

### 快捷键
- `Command + Shift + T`: 翻译选中的文本
- `Command + C`: 复制翻译结果

### API 设置
如果使用 DeepL 或 DeepSeek 翻译服务：
1. 点击右上角设置图标
2. 在设置面板中输入对应的 API Key
3. 点击保存即可使用

## 隐私说明
- 本应用不会收集任何个人信息
- 翻译内容仅用于实时翻译，不会被保存
- API Key 仅保存在本地，用于访问翻译服务

## 作者
- 开发者：Achord Chen
- 联系方式：[achordchan@gmail.com](mailto:achordchan@gmail.com)

## 版本历史

### v1.0 (2024-12-2)
- 🎉 首次发布
- 支持多种翻译服务
- 实现全局快捷键
- 添加深色模式
- AI 理解分析功能

## 许可证
本项目采用 MIT 许可证。详见 [LICENSE](LICENSE) 文件。

## 致谢
感谢以下服务和框架的支持：
- SwiftUI
- Google Translate
- DeepL API
- DeepSeek API
