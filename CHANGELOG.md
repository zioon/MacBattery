# Changelog

本文件记录 MacBattery 的重要变更，格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

## [Unreleased]

## [1.0.3] - 2026-09-14

### 新增

- 在线自动更新：启动时自动查询 GitHub Releases，发现新版本后自动下载 DMG 到「下载」文件夹，并弹窗提示安装。
- 菜单栏新增「检查更新…」，设置面板新增当前版本号与「检查更新」按钮。

### 变更

- CPU 内环改为自基点（0.5）反向生长，与 RAM 的正向生长对称。

### 构建

- 发版时 CI 用 git tag 覆盖 `Info.plist` 版本号（此前为硬编码 `1.0.0`，会导致应用内更新比对失效）。
