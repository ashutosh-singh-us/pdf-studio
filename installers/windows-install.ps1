# PDF Studio - per-user installer for Windows. Needs no admin rights:
# everything goes into %LOCALAPPDATA%, the Start Menu and the Desktop of the current user.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$dest = Join-Path $env:LOCALAPPDATA 'PDF Studio'

New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item (Join-Path $here 'app\PDF-Studio.html') $dest -Force
$iconSrc = Join-Path $here 'app\pdf-studio.ico'
if (Test-Path $iconSrc) { Copy-Item $iconSrc $dest -Force }
Copy-Item (Join-Path $here 'Uninstall on Windows.bat') (Join-Path $dest 'Uninstall PDF Studio.bat') -Force
Get-ChildItem $dest | Unblock-File -ErrorAction SilentlyContinue

function Find-Browser {
  foreach ($exe in 'msedge.exe', 'chrome.exe', 'brave.exe') {
    foreach ($root in 'HKCU:', 'HKLM:') {
      try {
        $v = (Get-ItemProperty -Path "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$exe" -ErrorAction Stop).'(default)'
        if ($v) { $v = $v.Trim('"'); if (Test-Path $v) { return $v } }
      } catch {}
    }
  }
  $paths = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
  )
  foreach ($p in $paths) { if ($p -and (Test-Path $p)) { return $p } }
  return $null
}

$html = Join-Path $dest 'PDF-Studio.html'
$url = ([System.Uri]$html).AbsoluteUri
$browser = Find-Browser
$iconFile = Join-Path $dest 'pdf-studio.ico'

function New-AppShortcut([string]$path) {
  $ws = New-Object -ComObject WScript.Shell
  $s = $ws.CreateShortcut($path)
  if ($browser) {
    $s.TargetPath = $browser
    $s.Arguments = "--app=`"$url`""
  } else {
    $s.TargetPath = $html
  }
  $s.WorkingDirectory = $dest
  if (Test-Path $iconFile) { $s.IconLocation = "$iconFile,0" }
  $s.Description = 'PDF Studio - read and edit PDF files'
  $s.Save()
}

$made = @()
foreach ($dir in @([Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Desktop'))) {
  try {
    if ($dir) { $lnk = Join-Path $dir 'PDF Studio.lnk'; New-AppShortcut $lnk; $made += $lnk }
  } catch { Write-Host "  Could not create shortcut in $dir : $($_.Exception.Message)" }
}

Write-Host "  Installed to: $dest"
foreach ($m in $made) { Write-Host "  Shortcut:     $m" }
if ($browser) { Write-Host "  Opens in:     $browser (app window)" } else { Write-Host '  Opens in:     your default browser' }
Write-Host ''
Write-Host '  Done! Launching PDF Studio...'

if ($browser) { Start-Process -FilePath $browser -ArgumentList "--app=`"$url`"" } else { Start-Process $html }
