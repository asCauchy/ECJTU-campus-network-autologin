# campus-install-task.ps1
# 注册 / 更新计划任务 CampusNet-AutoLogin
#
# 需要管理员权限（写任务计划库需要提升权限）。
#
# 设计要点：
#   * 全部改为「事件驱动」，没有任何定时轮询。不需要登录时进程根本不启动，
#     所以既不闪窗也不耗电。
#   * 动作走 wscript.exe -> campus-launch.vbs，避免 powershell.exe 先建控制台
#     窗口再隐藏所导致的闪窗。

$ErrorActionPreference = 'Stop'

$TaskName = 'CampusNet-AutoLogin'
$Dir      = Split-Path -Parent $MyInvocation.MyCommand.Path
$Launcher = Join-Path $Dir 'campus-launch.vbs'
$Login    = Join-Path $Dir 'campus-login.ps1'

# ---------------------------------------------------------------- 前置检查
# 不预判"未提升就拒绝"——非管理员账户往往也能注册以本人身份运行的任务。
# 直接尝试，失败时再按真实错误给出补救办法。
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host ("当前进程已提升权限：{0}" -f $isAdmin) -ForegroundColor DarkGray

foreach ($f in @($Launcher, $Login)) {
    if (-not (Test-Path $f)) { throw "找不到必需文件：$f" }
}

Write-Host ''
Write-Host '=== 校园网自动登录 · 注册计划任务 ===' -ForegroundColor Cyan
Write-Host ''

# ---------------------------------------------------------------- 动作
# 用 wscript.exe（GUI 子系统，本身无控制台）启动 VBS，
# VBS 里 Shell.Run(..., 0, False) 在进程创建时就带 SW_HIDE，子进程控制台全程不可见。
$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}"' -f $Launcher)

# ---------------------------------------------------------------- 触发器
$triggers = @()
$cim      = Get-CimClass -Namespace Root/Microsoft/Windows/TaskScheduler -ClassName MSFT_TaskEventTrigger

# ① 开机 / 用户登录
$triggers += New-ScheduledTaskTrigger -AtLogOn
Write-Host '  [1] AtLogOn                                   开机 / 登录' -ForegroundColor Gray

# ② 睡眠 / 休眠唤醒
$t1 = New-CimInstance -CimClass $cim -ClientOnly
$t1.Enabled      = $true
$t1.Subscription = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''Microsoft-Windows-Power-Troubleshooter''] and EventID=1]]</Select></Query></QueryList>'
$triggers += $t1
Write-Host '  [2] Power-Troubleshooter EventID=1            睡眠 / 休眠唤醒' -ForegroundColor Gray

# ③ 网络接通 —— 取代原来的 2 分钟定时轮询
# 实测：最近 6 次睡眠唤醒，100% 都在 1-6 秒后触发此事件
$t2 = New-CimInstance -CimClass $cim -ClientOnly
$t2.Enabled      = $true
$t2.Subscription = '<QueryList><Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"><Select Path="Microsoft-Windows-NetworkProfile/Operational">*[System[Provider[@Name=''Microsoft-Windows-NetworkProfile''] and EventID=10000]]</Select></Query></QueryList>'
$triggers += $t2
Write-Host '  [3] NetworkProfile EventID=10000              网络接通（状态驱动）' -ForegroundColor Gray
Write-Host '      （已移除每 2 分钟的定时轮询）' -ForegroundColor DarkGray

# ---------------------------------------------------------------- 设置 / 身份
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive -RunLevel Limited

# ---------------------------------------------------------------- 注册
try {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers `
        -Settings $settings -Principal $principal -Force -ErrorAction Stop | Out-Null
} catch {
    Write-Host ''
    Write-Host ('× 注册失败：' + $_.Exception.Message) -ForegroundColor Red
    Write-Host ''
    Write-Host '若为「拒绝访问 (0x80070005)」，说明当前账户无权写任务计划库。' -ForegroundColor Yellow
    Write-Host '以管理员身份重跑本脚本，在普通 PowerShell 里执行下面这行：' -ForegroundColor Yellow
    Write-Host '  Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-NoExit","-File","$PSCommandPath"' -ForegroundColor DarkGray
    exit 1
}

# ---------------------------------------------------------------- 回读验证
Write-Host ''
$task = Get-ScheduledTask -TaskName $TaskName
Write-Host ("✔ 已注册：{0}  状态={1}" -f $task.TaskName, $task.State) -ForegroundColor Green
Write-Host ''
Write-Host '动作：' -ForegroundColor Cyan
Write-Host ('  {0} {1}' -f $task.Actions[0].Execute, $task.Actions[0].Arguments)
Write-Host ''
Write-Host '触发器数量：' -ForegroundColor Cyan
Write-Host ('  {0} 个（应为 3，且不含 TimeTrigger）' -f $task.Triggers.Count)
$task.Triggers | ForEach-Object { Write-Host ('  - ' + $_.CimClass.CimClassName) }
Write-Host ''

if ($task.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskTimeTrigger' }) {
    Write-Host '⚠ 仍然存在 TimeTrigger —— 轮询没有被移除干净。' -ForegroundColor Yellow
} else {
    Write-Host '✔ 确认：没有任何定时轮询触发器。' -ForegroundColor Green
}
Write-Host ''
