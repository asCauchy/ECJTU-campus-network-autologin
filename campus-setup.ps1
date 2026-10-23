# campus-setup.ps1
# 校园网自动登录 —— 生成加密配置（不做任何持久化改动）
#
# 用法：
#   powershell -NoProfile -File campus-setup.ps1
#
# 说明：密码用 DPAPI 加密后写入 campus-config.json，只有本机当前 Windows 用户能解开，
#       不以明文落盘，也不需要管理员权限。
# 计划任务的注册请见 README.md —— 由你本人执行，脚本不会自动注册。

param(
    [switch]$Reconfigure    # 已存在配置时也重新输入账号密码
)

$ErrorActionPreference = 'Stop'

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptDir 'campus-config.json'

if ((Test-Path $ConfigPath) -and -not $Reconfigure) {
    Write-Host "配置已存在：$ConfigPath" -ForegroundColor Yellow
    Write-Host '如需重新设置账号密码，请加 -Reconfigure 参数运行。'
    exit 0
}

Write-Host ''
Write-Host '=== 校园网自动登录 · 生成配置 ===' -ForegroundColor Cyan
Write-Host '（密码只保存在本机，用当前 Windows 账户加密，不会写入日志）'
Write-Host ''

$username = Read-Host '请输入学号 / 工号'
if ([string]::IsNullOrWhiteSpace($username)) { throw '学号不能为空' }

$sec1 = Read-Host '请输入校园网密码' -AsSecureString
$sec2 = Read-Host '请再次输入密码确认' -AsSecureString

$p1 = [System.Net.NetworkCredential]::new('', $sec1).Password
$p2 = [System.Net.NetworkCredential]::new('', $sec2).Password
if ($p1 -ne $p2) { throw '两次输入的密码不一致，请重新运行。' }

# 华东交大门户 accountPrefix=1，PC 端账号固定带 ",0," 前缀（已实测确认，无需再问）
$prefix = ',0,'

# 运营商后缀：来自登录页 pc.js 的 ISP_select 选项；门户校验里"不选运营商不让提交"
Write-Host ''
Write-Host '请选择你的校园网运营商（即登录页的“选择运营商”）：'
Write-Host '  1) 中国联通   -> @unicom'
Write-Host '  2) 中国移动   -> @cmcc'
Write-Host '  3) 中国电信   -> @telecom'
$ispAns = Read-Host '输入序号 [1]'
$ispSuffix = switch ($ispAns) {
    '2'     { '@cmcc' }
    '3'     { '@telecom' }
    default { '@unicom' }
}

$cfg = [ordered]@{
    username          = $username
    passwordEncrypted = (ConvertFrom-SecureString $sec1)   # DPAPI，仅当前用户可解
    accountPrefix     = $prefix
    ispSuffix         = $ispSuffix
    wlanacname        = 'ecjtu_nic_ME60'
    portal            = '172.16.2.100'
}

$cfg | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8

Write-Host ''
Write-Host "✔ 配置已写入：$ConfigPath" -ForegroundColor Green
Write-Host "  提交账号：$prefix$username$ispSuffix" -ForegroundColor DarkGray
Write-Host ''
Write-Host '下一步：' -ForegroundColor Cyan
Write-Host '  1) 测试登录（会立即发起一次真实认证）：'
Write-Host "     powershell -NoProfile -File `"$(Join-Path $ScriptDir 'campus-login.ps1')`" -ShowOutput -Force"
Write-Host '  2) 注册计划任务实现自动登录：见 README.md 第 3 节（由你本人执行）'
Write-Host ''
