# campus-verify.ps1
# 离线验证「账号格式」：注销 -> 逐个候选格式登录 -> 判定 -> 写回配置 -> 恢复在线
#
# 为什么要这个脚本：已在线时门户对任何登录请求都返回失败页，无法区分格式对错。
# 只有先注销、真正离线，才能用门户自己定义的成败标志（Dr.COMWebLoginID_3.htm）判定。
#
# 注意：运行时校园网会断开 1-3 分钟。跑完会自动恢复在线。
#
# 用法：
#   powershell -NoProfile -File campus-verify.ps1
#   powershell -NoProfile -File campus-verify.ps1 -SkipLogout   # 已经手动注销过

param(
    [switch]$SkipLogout
)

$ErrorActionPreference = 'Stop'

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptDir 'campus-config.json'
$LogPath    = Join-Path $ScriptDir 'campus-verify.log'

function Say {
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host $Message -ForegroundColor $Color
    try { Add-Content -Path $LogPath -Value ('{0} {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message) -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
}

# ---------------------------------------------------------------- 读配置
if (-not (Test-Path $ConfigPath)) { Say "找不到 $ConfigPath，请先运行 campus-setup.ps1" 'Red'; exit 2 }
$cfg = Get-Content -Raw $ConfigPath -Encoding UTF8 | ConvertFrom-Json

$PortalIp = if ($cfg.portal)     { [string]$cfg.portal }     else { '172.16.2.100' }
$AcName   = if ($cfg.wlanacname) { [string]$cfg.wlanacname } else { 'ecjtu_nic_ME60' }
$Prefix   = if ($null -ne $cfg.accountPrefix) { [string]$cfg.accountPrefix } else { ',0,' }
$Isp      = if ($null -ne $cfg.ispSuffix)     { [string]$cfg.ispSuffix }     else { '@unicom' }
$User     = [string]$cfg.username

try {
    $sec  = ConvertTo-SecureString $cfg.passwordEncrypted
    $Pass = [System.Net.NetworkCredential]::new('', $sec).Password
} catch { Say "密码解密失败：$($_.Exception.Message)" 'Red'; exit 2 }

# ---------------------------------------------------------------- 工具
function Get-Ip {
    try { return [string](Find-NetRoute -RemoteIPAddress $PortalIp -ErrorAction Stop | Select-Object -First 1).IPAddress }
    catch { return '' }
}
function Get-Mac {
    try {
        $a = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.MacAddress } | Sort-Object ifIndex | Select-Object -First 1
        return ([string]$a.MacAddress).ToUpper()
    } catch { return '00-00-00-00-00-00' }
}
function Test-Online {
    try {
        $r = Invoke-WebRequest 'http://connect.rom.miui.com/generate_204' -UseBasicParsing -TimeoutSec 6 -MaximumRedirection 0
        return ($r.StatusCode -eq 204)
    } catch { return $false }
}
function GB([byte[]]$b) { [System.Text.Encoding]::GetEncoding('GB18030').GetString($b) }

function Invoke-Logout {
    $ip = Get-Ip; $mac = Get-Mac
    $urls = @(
        "http://${PortalIp}:801/eportal/?c=ACSetting&a=Logout&ver=1.0",
        ("http://{0}:801/eportal/?c=ACSetting&a=Logout&wlanuserip={1}&wlanacip=null&wlanacname={2}&port=&hostname={3}&iTermType=1&session=&queryACIP=0&mac={4}" -f $PortalIp, $ip, $AcName, $PortalIp, $mac)
    )
    foreach ($u in $urls) {
        try { Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 12 -MaximumRedirection 0 | Out-Null } catch { }
    }
}

# 返回 @{ ok=$true/$false; marker='...' }
function Invoke-Login {
    param([string]$Account)
    $ip = Get-Ip; $mac = Get-Mac
    $q = @('c=ACSetting','a=Login','protocol=http:',"hostname=$PortalIp",'port=','iTermType=1',
           "wlanuserip=$ip",'wlanacip=null',"wlanacname=$AcName","mac=$mac","ip=$ip",
           'redirect=','session=','enAdvert=0','queryACIP=0','loginMethod=1') -join '&'
    $body = @(('DDDDD=' + [uri]::EscapeDataString($Account)),
              ('upass=' + [uri]::EscapeDataString($Pass)),
              'R1=0','R2=0','R3=0','R6=0','para=00','0MKKey=123456') -join '&'
    $text = ''
    try {
        $r = Invoke-WebRequest -Uri "http://${PortalIp}:801/eportal/?$q" -Method POST -Body $body `
                -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -TimeoutSec 20
        $text = GB $r.RawContentStream.ToArray()
    } catch { }

    $marker = '未识别'
    if     ($text -match 'Dr\.COMWebLoginID_3\.htm') { $marker = '成功页(_3)' }
    elseif ($text -match 'Dr\.COMWebLoginID_2\.htm') { $marker = '失败页(_2)' }
    elseif ($text -match 'Dr\.COMWebLoginID_1\.htm') { $marker = '注销页(_1)' }

    Start-Sleep -Seconds 3
    $online = Test-Online
    return @{ ok = $online; marker = $marker }
}

# ---------------------------------------------------------------- 候选格式
# 注意：无论配置里写的是什么，前缀的两种形态（带 ,0, / 不带）都要测一遍，
# 否则配置本身错了就永远测不出正确格式。
$suffixes = @($Isp, '@unicom', '@cmcc', '@telecom', '@lt', '@dx', '@xyw', '') | Select-Object -Unique
$candidates = @()
foreach ($suf in $suffixes) {
    $candidates += (',0,' + $User + $suf)   # 门户 PC 端公式：前缀 ,0,
    $candidates += ($User + $suf)           # AC 实际存储的 uid 形态
}

Say ''
Say '========================================' 'Cyan'
Say ' 校园网账号格式自检' 'Cyan'
Say '========================================' 'Cyan'
Say "学号：$User"
Say "候选格式（按可能性排序）："
for ($i = 0; $i -lt $candidates.Count; $i++) { Say ("  {0}) {1}" -f ($i + 1), $candidates[$i]) }
Say ''

if (Test-Online) {
    if ($SkipLogout) {
        Say '当前仍在线，但你指定了 -SkipLogout。请先手动注销后重跑。' 'Red'
        exit 1
    }
    Say '正在注销当前认证 ...' 'Yellow'
    Invoke-Logout
    $waited = 0
    while ((Test-Online) -and $waited -lt 25) { Start-Sleep -Seconds 2; $waited += 2 }
    if (Test-Online) {
        Say '注销失败，当前仍在线。' 'Red'
        Say '请用浏览器打开 http://172.16.2.100/ 点「注销」，然后重跑本脚本（加 -SkipLogout）。' 'Yellow'
        exit 1
    }
    Say "已离线（等待 ${waited}s）" 'Green'
} else {
    Say '当前已离线，直接开始测试' 'Green'
}

# ---------------------------------------------------------------- 逐个测试
$winner = $null
for ($i = 0; $i -lt $candidates.Count; $i++) {
    $acct = $candidates[$i]
    Say ''
    Say ("[{0}/{1}] 尝试：{2}" -f ($i + 1), $candidates.Count, $acct) 'Cyan'

    if ($i -gt 0) {
        # 上一次失败后可能残留半连接，注销一次确保干净
        Invoke-Logout
        $w = 0; while ((Test-Online) -and $w -lt 20) { Start-Sleep -Seconds 2; $w += 2 }
    }

    $res = Invoke-Login -Account $acct
    Say ("      服务端返回 {0} ；外网 {1}" -f $res.marker, $(if ($res.ok) { '已连通' } else { '不通' }))

    if ($res.ok) { $winner = $acct; Say "      => 成功！" 'Green'; break }
    Say '      => 失败' 'DarkYellow'
}

# ---------------------------------------------------------------- 结果
Say ''
Say '========================================' 'Cyan'
if ($winner) {
    Say "成功格式：$winner" 'Green'

    # 写回配置：直接记完整账号，避免拆分前缀/后缀出错
    $cfg | Add-Member -NotePropertyName loginAccount -NotePropertyValue $winner -Force
    $cfg | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8
    Say "已写回配置：$ConfigPath" 'Green'

    # 确保恢复在线
    if (-not (Test-Online)) {
        Say '正在恢复在线 ...' 'Yellow'
        $r2 = Invoke-Login -Account $winner
        if ($r2.ok) {
            Say ("恢复结果：{0} / 已连通" -f $r2.marker) 'Green'
        } else {
            Say ("恢复结果：{0} / 仍不通" -f $r2.marker) 'Red'
        }
    } else {
        Say '当前已在线' 'Green'
    }
} else {
    Say '所有候选格式都失败。' 'Red'
    Say '可能原因：密码不对（用 campus-setup.ps1 -Reconfigure 重设），' 'Yellow'
    Say '或该校要求先绑定 MAC / 有额外的 R3 运营商字段。' 'Yellow'
    if (-not (Test-Online)) { Say '当前处于离线状态，请手动登录或重跑 campus-login.ps1。' 'Red' }
}
Say '========================================' 'Cyan'
