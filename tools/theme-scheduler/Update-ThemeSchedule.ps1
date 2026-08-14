# Update-ThemeSchedule.ps1
# 根据日出/日落时间自动切换 Windows 深浅色模式(固定时间作为备用)
# 用法:
#   - 手动配置位置:修改下面的 $Latitude / $Longitude(留空则 IP 直连定位)
#   - IP 定位失败或算法异常:回退到 $FallbackLight / $FallbackDark 固定时间
# 计划任务:
#   Theme-Schedule-Update  每天 00:10 运行本脚本,更新当天切换时间
#   Theme-Light            日出时间执行(浅色)
#   Theme-Dark             日落时间执行(深色)

# ===== 配置 =====
$Latitude  = $null   # 例: 31.2304 (上海);留空则 IP 直连定位
$Longitude = $null   # 例: 121.4737
$FallbackLight = '07:00'   # 备用:浅色时间
$FallbackDark  = '19:00'   # 备用:深色时间
# ================

$ErrorActionPreference = 'Continue'
$LightTask = 'Theme-Light'
$DarkTask  = 'Theme-Dark'
$LogFile   = Join-Path $PSScriptRoot 'theme-scheduler.log'

function Write-Log
{
  param([string]$Message)
  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
  Write-Output $line
  Add-Content -LiteralPath $LogFile -Value $line -ErrorAction SilentlyContinue
}

# ---------- 获取经纬度(绕过代理直连,10 秒超时) ----------
function Get-Coordinates
{
  if ($Latitude -and $Longitude)
  {
    return [pscustomobject]@{ Lat = [double]$Latitude; Lon = [double]$Longitude; Source = 'config' }
  }
  try
  {
    $req = [System.Net.HttpWebRequest]::Create('https://ipinfo.io/json')
    $req.Proxy = $null
    $req.Timeout = 10000
    $req.UserAgent = 'curl/8.0'
    $req.Accept = 'application/json'
    $resp = $req.GetResponse()
    $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
    $json = $reader.ReadToEnd()
    $reader.Close()
    $resp.Close()
    $r = $json | ConvertFrom-Json
    $loc = ($r.loc -split ',')
    if ($loc.Count -eq 2)
    {
      return [pscustomobject]@{ Lat = [double]$loc[0]; Lon = [double]$loc[1]; Source = 'ip' }
    }
  } catch
  {
  }
  return $null
}

# ---------- NOAA 日出日落算法 ----------
function Get-SunTimes
{
  param([double]$Lat, [double]$Lon, [datetime]$Date = (Get-Date))

  $latRad = $Lat * [Math]::PI / 180
  $n  = $Date.DayOfYear
  $hour = $Date.Hour + $Date.Minute / 60
  $gamma = 2 * [Math]::PI / 365 * ($n - 1 + ($hour - 12) / 24)

  $eqtime = 229.18 * (0.000075 + 0.001868 * [Math]::Cos($gamma) - 0.032077 * [Math]::Sin($gamma) `
      - 0.014615 * [Math]::Cos(2 * $gamma) - 0.040849 * [Math]::Sin(2 * $gamma))
  $decl = 0.006918 - 0.399912 * [Math]::Cos($gamma) + 0.070257 * [Math]::Sin($gamma) `
    - 0.006758 * [Math]::Cos(2 * $gamma) + 0.000907 * [Math]::Sin(2 * $gamma) `
    - 0.002697 * [Math]::Cos(3 * $gamma) + 0.00148 * [Math]::Sin(3 * $gamma)

  $cosHa = ([Math]::Cos(90.833 * [Math]::PI / 180) / ([Math]::Cos($latRad) * [Math]::Cos($decl)) `
      - [Math]::Tan($latRad) * [Math]::Tan($decl))
  if ($cosHa -gt 1 -or $cosHa -lt -1)
  { return $null
  }  # 极昼/极夜

  $ha = [Math]::Acos($cosHa)
  $utcRise = 720 - 4 * ($Lon + $ha * 180 / [Math]::PI) - $eqtime
  $utcSet  = 720 - 4 * ($Lon - $ha * 180 / [Math]::PI) - $eqtime

  $offset = [TimeZoneInfo]::Local.GetUtcOffset($Date).TotalMinutes
  $rise = (Get-Date -Date $Date).Date.AddMinutes($utcRise + $offset)
  $set  = (Get-Date -Date $Date).Date.AddMinutes($utcSet  + $offset)
  return [pscustomobject]@{ Sunrise = $rise; Sunset = $set }
}

# ---------- 主流程 ----------
$coords = Get-Coordinates
if (-not $coords)
{
  Write-Log 'Location lookup failed, using fallback times.'
  $riseTime = [datetime]::Parse($FallbackLight)
  $setTime  = [datetime]::Parse($FallbackDark)
} else
{
  $sun = Get-SunTimes -Lat $coords.Lat -Lon $coords.Lon
  if ($null -eq $sun)
  {
    Write-Log 'Sun times unavailable (polar day/night), using fallback times.'
    $riseTime = [datetime]::Parse($FallbackLight)
    $setTime  = [datetime]::Parse($FallbackDark)
  } else
  {
    $riseTime = $sun.Sunrise
    $setTime  = $sun.Sunset
  }
}

Write-Log ('Location: {0} ({1}, {2})' -f $(if ($coords)
    { $coords.Source
    } else
    { 'fallback'
    }), $riseTime.ToString('HH:mm'), $setTime.ToString('HH:mm'))

# ---------- 更新计划任务时间(Set-ScheduledTask,无需密码) ----------
try
{
  $lightTrigger = New-ScheduledTaskTrigger -Daily -At $riseTime
  Set-ScheduledTask -TaskName $LightTask -Trigger $lightTrigger | Out-Null
  Write-Log ("Theme-Light -> {0}: OK" -f $riseTime.ToString('HH:mm'))
} catch
{
  Write-Log ("Theme-Light -> {0}: FAILED {1}" -f $riseTime.ToString('HH:mm'), $_.Exception.Message)
}
try
{
  $darkTrigger = New-ScheduledTaskTrigger -Daily -At $setTime
  Set-ScheduledTask -TaskName $DarkTask -Trigger $darkTrigger | Out-Null
  Write-Log ("Theme-Dark -> {0}: OK" -f $setTime.ToString('HH:mm'))
} catch
{
  Write-Log ("Theme-Dark -> {0}: FAILED {1}" -f $setTime.ToString('HH:mm'), $_.Exception.Message)
}
