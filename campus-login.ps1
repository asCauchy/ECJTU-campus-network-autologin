# campus-login.ps1
# 校园网（Dr.COM / 城市热点）自动登录脚本 —— 华东交通大学
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File campus-login.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File campus-login.ps1 -ShowOutput -Force
#
# 特性：幂等（已在线直接退出）、门户未就绪自动重试、全程写日志。
# 退出码：0=已在线/登录成功  1=登录失败  2=配置或解密错误

param(
    [switch]$Force,        # 跳过"已在线"检测，强制发起一次登录
    [switch]$ShowOutput,   # 把日志同时打印到控制台
    [switch]$DryRun        # 只探测环境并拼接请求，不真正提交（排查用）
)

$ErrorActionPreference = 'Stop'

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptDir 'campus-config.json'
$LogPath    = Join-Path $ScriptDir 'campus-login.log'
$MaxAttempts = 3

# ---------------------------------------------------------------- 日志
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($ShowOutput) { Write-Host $line }
    try {
        if ((Test-Path $LogPath) -and ((Get-Item $LogPath).Length -gt 1MB)) {
            Remove-Item $LogPath -Force -ErrorAction SilentlyContinue
        }
        Add-Content -Path $LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
}

# ---------------------------------------------------------------- 读配置
if (-not (Test-Path $ConfigPath)) {
    Write-Log "找不到配置文件 $ConfigPath ，请先运行 campus-setup.ps1" 'ERROR'
    exit 2
}

try {
    $cfg = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Log "配置文件解析失败：$($_.Exception.Message)" 'ERROR'
    exit 2
}

$PortalIp      = if ($cfg.portal)     { [string]$cfg.portal }     else { '172.16.2.100' }
$WlanAcName    = if ($cfg.wlanacname) { [string]$cfg.wlanacname } else { 'ecjtu_nic_ME60' }
$AccountPrefix = if ($null -ne $cfg.accountPrefix) { [string]$cfg.accountPrefix } else { ',0,' }
$IspSuffix     = if ($null -ne $cfg.ispSuffix)     { [string]$cfg.ispSuffix }     else { '@unicom' }
$Username      = [string]$cfg.username

# 门户 JS 的最终账号公式：accountPrefix + 账号 + 运营商后缀
# 例如 ,0, + 学号 + @unicom
# 若 campus-verify.ps1 已实测出可用格式，优先采用它
$Account = if ($cfg.loginAccount) { [string]$cfg.loginAccount } else { $AccountPrefix + $Username + $IspSuffix }

if ([string]::IsNullOrWhiteSpace($Username) -or [string]::IsNullOrWhiteSpace($cfg.passwordEncrypted)) {
    Write-Log '配置缺少 username 或 passwordEncrypted，请重新运行 campus-setup.ps1' 'ERROR'
    exit 2
}

# 密码用 DPAPI 加密存储，只有本机当前 Windows 用户能解开
try {
    $sec      = ConvertTo-SecureString $cfg.passwordEncrypted
    $Password = [System.Net.NetworkCredential]::new('', $sec).Password
} catch {
    Write-Log "密码解密失败（是否更换了 Windows 用户或机器？）：$($_.Exception.Message)" 'ERROR'
    exit 2
}

# ---------------------------------------------------------------- 工具函数

# 是否已能访问外网。未认证时门户会劫持 HTTP，所以只认 204。
function Test-Online {
    $probes = @(
        'http://connect.rom.miui.com/generate_204'
        'http://connectivitycheck.platform.hicloud.com/generate_204'
        'http://wifi.vivo.com.cn/generate_204'
    )
    foreach ($p in $probes) {
        try {
            $r = Invoke-WebRequest -Uri $p -UseBasicParsing -TimeoutSec 6 -MaximumRedirection 0
            if ($r.StatusCode -eq 204) { return $true }
        } catch { }
    }
    # 兜底：HTTPS 能正常取到内容（门户无法伪造证书，被劫持时这里会报错）
    try {
        $r = Invoke-WebRequest -Uri 'https://www.baidu.com' -UseBasicParsing -TimeoutSec 8 -MaximumRedirection 0
        if ($r.StatusCode -eq 200 -and $r.RawContentLength -gt 1000) { return $true }
    } catch { }
    return $false
}

# 从一段 URL / HTML 里取出指定的查询参数
function Get-ParamValue {
    param([string]$Text, [string]$Name)
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $pattern = '(?:^|[?&])' + [regex]::Escape($Name) + '=([^&''"\s<>]*)'
    $m = [regex]::Match($Text, $pattern)
    if ($m.Success) {
        try { return [uri]::UnescapeDataString($m.Groups[1].Value) }
        catch { return $m.Groups[1].Value }
    }
    return $null
}

# 同上，但只接受合法 IPv4。门户页正文里含 JS 源码字面量 "&wlanuserip="，
# 不加这层校验会把空字符串/模板当成本机 IP。
function Get-IpParam {
    param([string]$Text, [string]$Name)
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $pattern = '(?:^|[?&])' + [regex]::Escape($Name) + '=((?:\d{1,3}\.){3}\d{1,3})'
    $m = [regex]::Match($Text, $pattern)
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

# 访问门户，从重定向 URL 中取本次认证需要的参数（IP 每次重连都会变）
function Get-PortalContext {
    foreach ($u in @("http://$PortalIp/", "http://$PortalIp/a70.htm")) {
        $loc = $null
        $body = ''
        try {
            $req = [System.Net.HttpWebRequest]::Create($u)
            $req.Method           = 'GET'
            $req.AllowAutoRedirect = $false
            $req.Timeout          = 8000
            $req.UserAgent        = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
            $resp = $req.GetResponse()
            $loc  = $resp.Headers['Location']
            if ([int]$resp.StatusCode -eq 200) {
                $sr   = New-Object System.IO.StreamReader($resp.GetResponseStream())
                $body = $sr.ReadToEnd()
                $sr.Close()
            }
            $resp.Close()
        } catch {
            continue
        }

        $hay = if ($loc) { [string]$loc } else { $body }
        if ([string]::IsNullOrEmpty($hay)) { continue }

        # 必须是真的认证跳转：wlanuserip 得是合法 IPv4。
        # 已登录时门户直接返回 200 的注销页，正文里没有任何真实参数，这里会 continue。
        $ip = Get-IpParam $hay 'wlanuserip'
        if (-not $ip) { continue }

        return @{
            ip         = $ip
            wlanacname = Get-ParamValue $hay 'wlanacname'
            wlanacip   = Get-IpParam   $hay 'wlanacip'
            redirect   = [string](Get-ParamValue $hay 'redirect')
            session    = [string](Get-ParamValue $hay 'session')
        }
    }
    return $null
}

# 本机用于访问门户的 IPv4 地址
function Get-LocalIp {
    param([string]$Target)
    try {
        $r = Find-NetRoute -RemoteIPAddress $Target -ErrorAction Stop | Select-Object -First 1
        if ($r -and $r.IPAddress -and $r.IPAddress -ne '0.0.0.0') { return [string]$r.IPAddress }
    } catch { }
    try {
        $c = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
             Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' } |
             Select-Object -First 1
        if ($c) { return [string]$c.IPAddress }
    } catch { }
    return $null
}

function Get-LocalMac {
    try {
        $a = Get-NetAdapter -ErrorAction Stop |
             Where-Object { $_.Status -eq 'Up' -and $_.MacAddress } |
             Sort-Object ifIndex | Select-Object -First 1
        if ($a) { return ([string]$a.MacAddress).ToUpper() }
    } catch { }
    return '00-00-00-00-00-00'
}

# ---------------------------------------------------------------- 主流程
for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {

    if (-not $Force -and (Test-Online)) {
        Write-Log "已在线（第 $attempt 次检测），无需登录"
        exit 0
    }

    # 门户跳转只用于补充参数；本机 IP 以系统路由为准（实测与门户的 wlanuserip 一致）
    $ctx = Get-PortalContext

    $userIp = if ($ctx -and $ctx.ip) { [string]$ctx.ip } else { Get-LocalIp -Target $PortalIp }
    if ([string]::IsNullOrEmpty($userIp) -or $userIp -eq '0.0.0.0') {
        Write-Log "第 $attempt/$MaxAttempts 次：无法确定本机 IP，稍后重试" 'WARN'
        Start-Sleep -Seconds 5
        continue
    }

    $acName   = if ($ctx -and $ctx.wlanacname) { [string]$ctx.wlanacname } else { $WlanAcName }
    $acIp     = if ($ctx -and $ctx.wlanacip)   { [string]$ctx.wlanacip }   else { 'null' }
    $redirect = if ($ctx) { [string]$ctx.redirect } else { '' }
    $session  = if ($ctx) { [string]$ctx.session }  else { '' }
    $mac      = Get-LocalMac

    # 门户 a70.htm 的 JS 逆向结果：c=ACSetting&a=Login，loginMethod=1（portal 协议）
    $query = @(
        'c=ACSetting'
        'a=Login'
        'protocol=http:'
        "hostname=$PortalIp"
        'port='
        'iTermType=1'
        ('wlanuserip=' + [uri]::EscapeDataString($userIp))
        ('wlanacip='   + [uri]::EscapeDataString($acIp))
        ('wlanacname=' + [uri]::EscapeDataString($acName))
        ('mac='        + [uri]::EscapeDataString($mac))
        ('ip='         + [uri]::EscapeDataString($userIp))
        ('redirect='   + [uri]::EscapeDataString($redirect))
        ('session='    + [uri]::EscapeDataString($session))
        'enAdvert=0'
        'queryACIP=0'
        'loginMethod=1'
    ) -join '&'

    $loginUrl = ('http://{0}:801/eportal/?{1}' -f $PortalIp, $query)

    # 表单 f0 的字段（取自门户 pc.js 中 f0 的 hidden input 默认值）
    $body = @(
        ('DDDDD=' + [uri]::EscapeDataString($Account))
        ('upass=' + [uri]::EscapeDataString($Password))
        'R1=0'
        'R2=0'
        'R3=0'
        'R6=0'
        'para=00'
        '0MKKey=123456'
    ) -join '&'

    Write-Log "第 $attempt/$MaxAttempts 次尝试登录：ip=$userIp mac=$mac ac=$acName"
    Write-Log "提交账号：$Account"

    if ($DryRun) {
        Write-Log "DryRun：门户跳转上下文=$(if ($ctx) { '已取得' } else { '未取得（改用本机 IP）' })"
        Write-Log "DryRun 请求 URL：$loginUrl"
        Write-Log ("DryRun 表单字段：" + (($body -split '&' | ForEach-Object { ($_ -split '=')[0] }) -join ','))
        exit 0
    }

    $respText = ''
    try {
        $resp = Invoke-WebRequest -Uri $loginUrl -Method POST -Body $body `
                    -ContentType 'application/x-www-form-urlencoded' `
                    -UseBasicParsing -TimeoutSec 20
        $respText = [string]$resp.Content
    } catch {
        Write-Log "登录请求异常：$($_.Exception.Message)" 'WARN'
    }

    Start-Sleep -Seconds 4

    # 门户自己定义的成败标志（取自注销页配置）：
    #   authsuccess='Dr.COMWebLoginID_3.htm'   authfail='Dr.COMWebLoginID_2.htm'
    $marker = '未识别'
    if     ($respText -match 'Dr\.COMWebLoginID_3\.htm') { $marker = '成功页(_3)' }
    elseif ($respText -match 'Dr\.COMWebLoginID_1\.htm') { $marker = '注销页(_1)' }
    elseif ($respText -match 'Dr\.COMWebLoginID_2\.htm') { $marker = '失败页(_2)' }

    if (Test-Online) {
        Write-Log "登录成功（第 $attempt 次尝试，ip=$userIp，服务端返回 $marker）"
        exit 0
    }

    Write-Log "登录未生效（服务端返回 $marker）" 'WARN'
    if ($marker -eq '失败页(_2)') {
        Write-Log '_2 是门户定义的登录失败页：多为账号格式（前缀 / 运营商后缀）或密码不对' 'WARN'
    }
    if ($respText) {
        $snippet = ($respText -replace '\s+', ' ')
        if ($snippet.Length -gt 200) { $snippet = $snippet.Substring(0, 200) }
        Write-Log "响应片段：$snippet" 'WARN'
    }
}

Write-Log "自动登录失败（已尝试 $MaxAttempts 次）" 'ERROR'
exit 1
