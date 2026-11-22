# Removes PDF Studio for Windows (installed by install.ps1). Settings > Apps > Installed apps runs this.
#   powershell -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\Programs\PDF Studio\uninstall.ps1" [-Quiet]
# Removes the app, its shortcuts, its file types and its data (settings and saved signatures).
param([switch]$Quiet)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
function Show-Message([string]$text) { if (-not $Quiet) { [void][System.Windows.Forms.MessageBox]::Show($text, 'PDF Studio') } }

$dest = Join-Path $env:LOCALAPPDATA 'Programs\PDF Studio'
$exe = Join-Path $dest 'PDFStudio.exe'
if (Get-Process PDFStudio -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe }) {
  Show-Message 'PDF Studio is running. Close its windows, then uninstall again.'
  exit 1
}

# Shortcuts that point to this app
$ws = New-Object -ComObject WScript.Shell
foreach ($dir in [Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Desktop')) {
  $lnk = Join-Path $dir 'PDF Studio.lnk'
  if ((Test-Path $lnk) -and ($ws.CreateShortcut($lnk).TargetPath -eq $exe)) { Remove-Item $lnk -Force }
}

# File types and registration
foreach ($k in 'Classes\PDFStudio.pdf', 'Classes\PDFStudio.md', 'Classes\Applications\PDFStudio.exe', 'PDF Studio',
               'Microsoft\Windows\CurrentVersion\Uninstall\PDFStudio') {
  $p = 'HKCU:\Software\' + $k
  if (Test-Path $p) { Remove-Item $p -Recurse -Force }
}
Remove-ItemProperty -Path 'HKCU:\Software\RegisteredApplications' -Name 'PDF Studio' -ErrorAction SilentlyContinue
$owp = @{ '.pdf' = 'PDFStudio.pdf' }
foreach ($e in '.md', '.markdown', '.mdown', '.mkd', '.mkdn') { $owp[$e] = 'PDFStudio.md' }
foreach ($e in $owp.Keys) {
  Remove-ItemProperty -Path "HKCU:\Software\Classes\$e\OpenWithProgids" -Name $owp[$e] -ErrorAction SilentlyContinue
}
Add-Type -Namespace PdfStudioSetup -Name Shell -MemberDefinition '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int e, int f, System.IntPtr a, System.IntPtr b);'
[PdfStudioSetup.Shell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)

# Files: the app, then its data (WebView2 profile with saved signatures, window size)
Set-Location $env:TEMP
foreach ($d in $dest, (Join-Path $env:LOCALAPPDATA 'PDF Studio')) {
  if (Test-Path $d) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}
Show-Message 'PDF Studio was removed.'
