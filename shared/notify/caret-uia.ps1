# UIA caret helper for anchor-locator.
#
# Why this exists: in this environment only a PowerShell host gets Chromium's
# full accessibility tree. The same UIAutomationClient queried from a plain .NET
# exe (anchor-locator) or from AutoHotkey returns just two Panes for
# Chrome_WidgetWin_1 and no TextPattern at all, while PowerShell gets ~1200
# descendants and the real Edit caret. So the locator shells out to this helper
# when its in-process paths fail.
#
# Contract (stdout, one line each, flushed):
#   CARET|<x>|<y>|<height>|<source>   caret bottom-left in screen pixels
#                                     source: text-caret | value-caret
#   NOCARET|<reason>                  no insertion point found
#
# ASCII only on purpose: PowerShell 5.1 parses BOM-less files as ANSI.

param(
  [long]$Hwnd = 0,
  [switch]$Watch,
  [switch]$Serve,
  [switch]$Debug,
  [string]$LogPath = '',
  [string]$OutPath = '',
  [int]$Attempts = 3,
  [int]$DelayMs = 200,
  [int]$IntervalMs = 150,
  [int]$DurationMs = 1200,
  [int]$ServeMs = 900000,
  [int]$MaxAttempts = 5
)

$ErrorActionPreference = 'Continue'
if ($LogPath -ne '') {
  function Write-Diag([string]$text) {
    try { Add-Content -LiteralPath $LogPath -Value $text -Encoding UTF8 } catch { }
  }
} else {
  function Write-Diag([string]$text) { }
}
Write-Diag ("start hwnd=" + $Hwnd + " pid=" + $PID + " cwd=" + (Get-Location).Path)

try {
  Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, WindowsBase
  Write-Diag "add-type ok"
} catch {
  Write-Diag ("add-type failed: " + $_.Exception.Message)
}

# UIA_ValuePatternValuePropertyId is 30045.
$VALUE_PROPERTY = 30045

function Get-TextCaret($element) {
  # 1) TextPattern selection (Chromium exposes the collapsed caret here).
  try {
    $obj = $null
    if ($element.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$obj)) {
      $pattern = [System.Windows.Automation.TextPattern]$obj
      $ranges = $pattern.GetSelection()
      if ($ranges -and $ranges.Count -gt 0) {
        $rects = $ranges[0].GetBoundingRectangles()
        if ($rects -and $rects.Count -gt 0) {
          $best = $null
          foreach ($r in $rects) { if ($r.Height -gt 0) { $best = $r } }
          if ($best) {
            return [pscustomobject]@{
              X = [int]$best.Left
              Y = [int]($best.Top + $best.Height)
              H = [int]$best.Height
              Source = 'text-caret'
            }
          }
        }
      }
    }
  } catch { }

  # 2) ValuePattern with a selection inside a form field.
  try {
    $vobj = $null
    if ($element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vobj)) {
      $vp = [System.Windows.Automation.ValuePattern]$vobj
      $sel = $vp.GetSelection()
      if ($sel -and $sel.Count -gt 0) {
        $value = $vp.Current.Value
        $start = $sel[0].Start
        if ($value -ne $null -and $start -ge 0 -and $start -le $value.Length) {
          $len = $value.Length
          if ($len -gt 0) {
            $idx = [Math]::Min($start, $len - 1)
            $range = $vp.DocumentRange.Clone()
            $range.MoveEndpointByRange(
              [System.Windows.Automation.TextPatternRangeEndpoint]::Start,
              $range,
              [System.Windows.Automation.TextPatternRangeEndpoint]::Start)
            $tail = $vp.DocumentRange.Clone()
            $tail.MoveEndpointByRange(
              [System.Windows.Automation.TextPatternRangeEndpoint]::Start,
              $range,
              [System.Windows.Automation.TextPatternRangeEndpoint]::End)
            $rects = $tail.GetBoundingRectangles()
            $best = $null
            foreach ($r in $rects) { if ($r.Height -gt 0) { $best = $r } }
            if ($best) {
              return [pscustomobject]@{
                X = [int]$best.Left
                Y = [int]($best.Top + $best.Height)
                H = [int]$best.Height
                Source = 'value-caret'
              }
            }
          }
        }
      }
    }
  } catch { }

  return $null
}

function Find-CaretElement($hwnd) {
  $root = $null
  if ($hwnd -le 0) {
    # 
    try { $root = [System.Windows.Automation.AutomationElement]::FocusedElement } catch { }
  } else {
    try { $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$hwnd) } catch { }
  }
  if (-not $root) {
    if ($Debug) { Write-Output "DBG|fromHandle=null" }
    return $null
  }

  # Prefer a form field / document inside THIS window. Do not depend on the
  # global focused element: another window may have the focus.
  $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $queue = New-Object System.Collections.Queue
  $queue.Enqueue($root)
  $fallback = $null
  $visited = 0
  $textishSeen = 0
  $textPatternSeen = 0
  while ($queue.Count -gt 0 -and $visited -lt 400) {
    $node = $queue.Dequeue()
    $visited++
    $ct = $null
    try { $ct = $node.Current.ControlType } catch { }
    $isTextish = $false
    if ($ct) {
      if ($ct -eq [System.Windows.Automation.ControlType]::Edit) { $isTextish = $true }
      elseif ($ct -eq [System.Windows.Automation.ControlType]::Document) { $isTextish = $true }
    }
    $hasText = $false
    $probe = $null
    try { $hasText = $node.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$probe) } catch { }
    if ($isTextish) { $textishSeen++ }
    if ($hasText) { $textPatternSeen++ }
    if ($isTextish -and $hasText) {
      $focus = $false
      try { $focus = $node.Current.HasKeyboardFocus } catch { }
      if ($focus) {
        if ($Debug) { Write-Output "DBG|found-focused-edit visited=$visited" }
        return $node
      }
      if (-not $fallback) { $fallback = $node }
    }
    $child = $null
    try { $child = $walker.GetFirstChild($node) } catch { }
    while ($child) {
      $queue.Enqueue($child)
      try { $child = $walker.GetNextSibling($child) } catch { break }
    }
  }
  if ($Debug) { Write-Output "DBG|visited=$visited textish=$textishSeen textPattern=$textPatternSeen fallback=$([bool]$fallback)" }
  return $fallback
}

function Get-CaretOnce($hwnd) {
  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    $element = Find-CaretElement $hwnd
    if ($element) {
      $caret = Get-TextCaret $element
      if ($caret) { return $caret }
    }
    # The focused element itself is often enough when the tree is already warm.
    try {
      $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
      if ($focused) {
        $caret2 = Get-TextCaret $focused
        if ($caret2) { return $caret2 }
      }
    } catch { }
    if ($attempt -lt $Attempts) { Start-Sleep -Milliseconds $DelayMs }
  }
  return $null
}

# Serve mode publishes one line atomically. Use pure .NET: PowerShell cmdlets
# leak error text into redirected stdout, and Move-Item -Force cannot overwrite.
function Write-Atom([string]$path, [string]$line) {
  try {
    $tmp = $path + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    if ([System.IO.File]::Exists($path)) { [System.IO.File]::Delete($path) }
    [System.IO.File]::Move($tmp, $path)
  } catch { }
}

# Only two modes exist. The one-shot mode was removed: nothing called it
# (the key handler uses -Serve, the follow fallback uses -Watch).
if (-not $Serve -and -not $Watch) {
  Write-Output 'NOCARET|mode-required'
  exit 2
}

if (-not $Serve -and $Hwnd -le 0) {
  Write-Output 'NOCARET|no-hwnd'
  exit 2
}

# --- serve mode -------------------------------------------------------
# Keep one PowerShell process alive and publish the caret to a file, so the
# key handler only reads a file (no PowerShell cold start on the hot path).
# Line format: T|<tickcount>|CARET|x|y|h|source
if ($Serve) {
  if ($OutPath -eq '') {
    Write-Output 'NOCARET|no-outpath'
    exit 2
  }
  Write-Diag ("serve start hwnd=" + $Hwnd + " out=" + $OutPath + " ms=" + $ServeMs)

  $serveDeadline = (Get-Date).AddMilliseconds($ServeMs)
  $lastLine = ''
  while ((Get-Date) -lt $serveDeadline) {
    $caret = $null
    # 
    $target = $Hwnd
    if ($target -le 0) { $target = 0 }
    for ($attempt = 1; $attempt -le $MaxAttempts -and -not $caret; $attempt++) {
      if ((Get-Date) -ge $serveDeadline) { break }
      $caret = Get-CaretOnce $target
      if (-not $caret -and $attempt -lt $MaxAttempts) { Start-Sleep -Milliseconds $DelayMs }
    }
    #  AHK/PowerShell  ""TickCount A_TickCount 
    $stamp = [Environment]::TickCount
    if ($caret) {
      $line = ("T|{0}|CARET|{1}|{2}|{3}|{4}" -f $stamp, $caret.X, $caret.Y, $caret.H, $caret.Source)
    } else {
      $line = ("T|{0}|NOCARET|no-insertion-point" -f $stamp)
    }
    Write-Atom $OutPath $line
    Start-Sleep -Milliseconds $IntervalMs
  }
  Write-Atom $OutPath ("T|" + [Environment]::TickCount + "|END|serve-timeout")
  exit 0
}

$deadline = (Get-Date).AddMilliseconds($DurationMs)
$lastLine = ''
$sent = $false
$failures = 0
while ((Get-Date) -lt $deadline) {
  $caret = $null
  # In watch mode keep the per-probe retry small: the loop itself is the retry.
  for ($attempt = 1; $attempt -le $MaxAttempts -and -not $caret; $attempt++) {
    if ((Get-Date) -ge $deadline) { break }
    $caret = Get-CaretOnce $Hwnd
    if (-not $caret -and $attempt -lt $MaxAttempts) { Start-Sleep -Milliseconds $DelayMs }
  }
  if ($caret) {
    $line = ("{0}|{1}|{2}|{3}" -f $caret.X, $caret.Y, $caret.H, $caret.Source)
    if ($line -ne $lastLine) {
      Write-Output ("CARET|" + $line)
      $lastLine = $line
      $sent = $true
    }
    $failures = 0
  } else {
    $failures++
    if ($failures -eq 1) { Write-Output 'NOCARET|no-insertion-point' }
  }
  if ((Get-Date) -ge $deadline) { break }
  Start-Sleep -Milliseconds $IntervalMs
}

if ($sent) { Write-Output 'END|watched' } else { Write-Output 'END|no-caret' }
exit 0
