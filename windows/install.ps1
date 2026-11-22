# Installs the native Windows app built by windows\build.ps1 for the current user. No admin rights:
# everything goes into %LOCALAPPDATA%\Programs\PDF Studio, the user's Start menu, Desktop and registry (HKCU).
#   powershell -ExecutionPolicy Bypass -File windows\install.ps1 [-NoLaunch]
# Adds "Open with > PDF Studio" for PDF and Markdown files, a listing in Settings > Default apps and an entry in
# Settings > Apps > Installed apps for uninstalling. It replaces the browser-based install, if there is one.
param([switch]$NoLaunch)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src = if (Test-Path (Join-Path $here 'PDFStudio.exe')) { $here } else { Join-Path (Split-Path -Parent $here) 'dist\PDF-Studio-Windows' }
if (-not (Test-Path (Join-Path $src 'PDFStudio.exe'))) { throw "Build it first: powershell -ExecutionPolicy Bypass -File windows\build.ps1" }

$dest = Join-Path $env:LOCALAPPDATA 'Programs\PDF Studio'
$exe = Join-Path $dest 'PDFStudio.exe'
if (Get-Process PDFStudio -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe }) {
  throw 'PDF Studio is running. Close its windows, then run this again.'
}

# Files
if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
New-Item -ItemType Directory -Force (Join-Path $dest 'app') | Out-Null
foreach ($f in 'PDFStudio.exe', 'PDFStudio.exe.config', 'Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.WinForms.dll',
               'WebView2Loader.dll', 'uninstall.ps1', 'pdf-studio.ico') {
  $p = Join-Path $src $f
  if (Test-Path $p) { Copy-Item $p $dest }
}
Copy-Item (Join-Path $src 'app\PDF-Studio.html') (Join-Path $dest 'app')
Get-ChildItem $dest -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

# File types: "Open with" in Explorer, and the Default apps page in Settings
$open = '"' + $exe + '" "%1"'
$md = '.md', '.markdown', '.mdown', '.mkd', '.mkdn'
function Set-Key([string]$path, [hashtable]$values) {
  $k = 'HKCU:\Software\' + $path
  if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
  foreach ($name in $values.Keys) {
    if ($name -eq '') { Set-Item -Path $k -Value $values[$name] }
    else { New-ItemProperty -Path $k -Name $name -Value $values[$name] -PropertyType String -Force | Out-Null }
  }
}
foreach ($t in @(@{ Id = 'PDFStudio.pdf'; Name = 'PDF Document' }, @{ Id = 'PDFStudio.md'; Name = 'Markdown Document' })) {
  Set-Key "Classes\$($t.Id)" @{ '' = $t.Name; 'FriendlyTypeName' = $t.Name }
  Set-Key "Classes\$($t.Id)\DefaultIcon" @{ '' = "`"$exe`",0" }
  Set-Key "Classes\$($t.Id)\shell\open\command" @{ '' = $open }
}
Set-Key 'Classes\.pdf\OpenWithProgids' @{ 'PDFStudio.pdf' = '' }
foreach ($e in $md) { Set-Key "Classes\$e\OpenWithProgids" @{ 'PDFStudio.md' = '' } }
Set-Key 'Classes\Applications\PDFStudio.exe' @{ 'FriendlyAppName' = 'PDF Studio' }
Set-Key 'Classes\Applications\PDFStudio.exe\DefaultIcon' @{ '' = "`"$exe`",0" }
Set-Key 'Classes\Applications\PDFStudio.exe\shell\open\command' @{ '' = $open }
$supported = @{ '.pdf' = '' }; foreach ($e in $md) { $supported[$e] = '' }
Set-Key 'Classes\Applications\PDFStudio.exe\SupportedTypes' $supported
Set-Key 'PDF Studio\Capabilities' @{ 'ApplicationName' = 'PDF Studio'; 'ApplicationDescription' = 'Read and edit PDF files, and read Markdown files'; 'ApplicationIcon' = "`"$exe`",0" }
$assoc = @{ '.pdf' = 'PDFStudio.pdf' }; foreach ($e in $md) { $assoc[$e] = 'PDFStudio.md' }
Set-Key 'PDF Studio\Capabilities\FileAssociations' $assoc
Set-Key 'RegisteredApplications' @{ 'PDF Studio' = 'Software\PDF Studio\Capabilities' }

# Settings > Apps > Installed apps
$version = (Get-Item $exe).VersionInfo.ProductVersion
$size = [int]((Get-ChildItem $dest -Recurse -File | Measure-Object Length -Sum).Sum / 1KB)
$uninstall = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $dest 'uninstall.ps1') + '"'
$k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PDFStudio'
if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
$entries = @{ DisplayName = 'PDF Studio'; DisplayVersion = $version; DisplayIcon = "$exe,0"; InstallLocation = $dest;
              UninstallString = $uninstall; QuietUninstallString = "$uninstall -Quiet" }
foreach ($n in $entries.Keys) { New-ItemProperty -Path $k -Name $n -Value $entries[$n] -PropertyType String -Force | Out-Null }
foreach ($n in 'NoModify', 'NoRepair') { New-ItemProperty -Path $k -Name $n -Value 1 -PropertyType DWord -Force | Out-Null }
New-ItemProperty -Path $k -Name EstimatedSize -Value $size -PropertyType DWord -Force | Out-Null

# Tell Explorer the file types changed, so "Open with" shows PDF Studio straight away.
Add-Type -Namespace PdfStudioSetup -Name Shell -MemberDefinition '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int e, int f, System.IntPtr a, System.IntPtr b);'
[PdfStudioSetup.Shell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)

# The browser-based install (installers\windows-install.ps1) used %LOCALAPPDATA%\PDF Studio. Its shortcuts have the
# same names and are replaced below. That folder now also holds this app's settings, so only the old files go.
$old = Join-Path $env:LOCALAPPDATA 'PDF Studio'
foreach ($f in 'PDF-Studio.html', 'pdf-studio.ico', 'Uninstall PDF Studio.bat') {
  $p = Join-Path $old $f
  if (Test-Path $p) { Remove-Item $p -Force; Write-Host "  Removed the browser-based version: $p" }
}

# Shortcuts
$ws = New-Object -ComObject WScript.Shell
$made = @()
foreach ($dir in [Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Desktop')) {
  try {
    $lnk = Join-Path $dir 'PDF Studio.lnk'
    $s = $ws.CreateShortcut($lnk)
    $s.TargetPath = $exe
    $s.WorkingDirectory = $dest
    $s.IconLocation = "$exe,0"
    $s.Description = 'PDF Studio - read and edit PDF files'
    $s.Save()
    $made += $lnk
  } catch { Write-Host "  Could not create a shortcut in $dir : $($_.Exception.Message)" }
}

Write-Host "  Installed to: $dest"
foreach ($m in $made) { Write-Host "  Shortcut:     $m" }
Write-Host '  Open with:    right-click a PDF or .md file > Open with > PDF Studio'
Write-Host '  Uninstall:    Settings > Apps > Installed apps > PDF Studio'
if (-not $NoLaunch) { Start-Process -FilePath $exe }
