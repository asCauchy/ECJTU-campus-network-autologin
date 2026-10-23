# 华东交通大学校园网自动登录

睡眠、关机唤醒后**自动完成 Dr.COM 校园网 Web 认证**，不用每次手动开浏览器登录。

## 适用对象

华东交通大学校园网用户（Dr.COM / 城市热点门户，`172.16.2.100`），支持三家运营商：

| 运营商 | 账号后缀 |
|--------|----------|
| 中国联通 | `@unicom` |
| 中国移动 | `@cmcc` |
| 中国电信 | `@telecom` |

## 功能特点

- **事件驱动，零轮询**：只在开机 / 登录 / 睡眠唤醒 / 网络接通这几个时刻启动，平时不跑、不弹窗、不耗电。
- **幂等**：已经在线就直接退出，重复运行无副作用。
- **密码加密**：DPAPI 加密后只存在本机，不落明文、不进仓库。
- **自动重试**：刚唤醒网络未就绪时最多重试 3 次，自动兜底。

## 环境要求

- Windows 10 / 11
- 系统自带的 PowerShell 5.1+（无需安装任何东西）

## 快速开始

1. 下载本仓库（`Download ZIP` 后解压，或 `git clone`）。
2. 双击 **`install.bat`**，弹出 UAC 时点「是」。
3. 按提示依次输入：**学号 → 密码（输两遍）→ 运营商序号**（`1` 联通 / `2` 移动 / `3` 电信）。
4. 完成。以后睡眠、关机唤醒后会自动登录。

> 脚本会顺带注册一个名为 `CampusNet-AutoLogin` 的计划任务。配置文件和日志都生成在**本文件夹内**。

## 文件说明

| 文件 | 作用 |
|------|------|
| `install.bat` | 双击安装入口（自提权 + 依次运行 setup、install-task） |
| `campus-setup.ps1` | 输入学号/密码/运营商，生成加密配置 `campus-config.json` |
| `campus-install-task.ps1` | 注册计划任务（三个事件触发器，需管理员权限） |
| `campus-login.ps1` | 登录脚本，幂等；已在线直接退出 |
| `campus-launch.vbs` | 无窗口启动包装器（避免 PowerShell 控制台闪窗） |
| `campus-verify.ps1` | 诊断工具：离线实测账号格式（见「常见问题」） |

## 原理（简述）

门户登录就是一次表单 POST：

```
POST http://172.16.2.100:801/eportal/?c=ACSetting&a=Login&...
表单: DDDDD=<账号>&upass=<密码>&R1=0&R2=0&R3=0&R6=0&para=00&0MKKey=123456
```

其中**账号不是纯学号**，而是三段拼接：

```
DDDDD = ,0, + 学号 + 运营商后缀
例：   ,0,学号@unicom
        ↑前缀 ↑学号 ↑运营商
```

计划任务用三个触发器覆盖所有需要登录的场景：

| 触发器 | 覆盖场景 |
|--------|----------|
| `AtLogOn` | 关机后开机 / 用户登录 |
| `Power-Troubleshooter` EventID=1 | 睡眠 / 休眠唤醒 |
| `NetworkProfile` EventID=10000「网络已连接」 | 网络恢复即登录 |

## 常见问题

**登录失败，日志里出现「失败页(_2)」** —— 账号格式或密码不对。先重跑 `install.bat` 重设密码/运营商；若仍失败，运行 `campus-verify.ps1` 离线实测账号格式（**会断网 1–3 分钟**，跑完自动恢复，不要在远程桌面里跑）。

**在网页上手动点「注销」后不会自动重登** —— 这是有意为之：手动注销时链路没断，系统认为网络仍在线，不会触发任何事件。需要重登就手动运行一次：

```powershell
Start-ScheduledTask -TaskName CampusNet-AutoLogin
```

**换电脑 / 换 Windows 账户 / 重装系统** —— DPAPI 密文解不开，重跑 `install.bat` 即可。

**想卸载** —— 管理员 PowerShell 里执行：

```powershell
Unregister-ScheduledTask -TaskName CampusNet-AutoLogin -Confirm:$false
```

**其他学校 / 门户地址变了** —— 编辑 `campus-login.ps1` 开头的默认值（`portal`、`wlanacname`），或直接改生成的 `campus-config.json`。账号格式各校不同，可参考 `campus-verify.ps1` 的判定思路自行适配。

## 隐私与安全

- 密码用 Windows DPAPI 加密，仅本机当前 Windows 账户可解密。
- `campus-config.json`（含加密密码与学号）和所有 `*.log` 已被 `.gitignore` 排除，**不会随仓库上传**。
- 本工具**非学校官方**，仅作便利用途。请遵守校园网使用规定，不要用于规避计费或不当目的。

## 免责声明

本项目仅供学习与个人便利使用。使用即表示你同意：因校园网政策变动、门户改版或使用本工具造成的任何后果，由使用者自行承担。
