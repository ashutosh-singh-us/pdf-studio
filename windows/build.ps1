# Builds the native Windows app (a WebView2 window with document tabs around PDF-Studio.html) into dist\.
# Uses the C# compiler that is part of Windows (.NET Framework 4.8). No Visual Studio, SDK or admin rights.
#   powershell -ExecutionPolicy Bypass -File windows\build.ps1 [-DebugBuild] [-Html path\to\PDF-Studio.html]
# The HTML defaults to dist\PDF-Studio\app\PDF-Studio.html from "npm run build".
# -DebugBuild builds dist\PDF-Studio-Windows-Debug with the developer tools turned on (right-click > Inspect).
# The only download is Microsoft's WebView2 SDK package from nuget.org. It is checked against a pinned
# SHA-256 and its DLLs must carry a valid Microsoft signature. For an offline build, put the .nupkg in vendor\.
param([string]$Html, [switch]$DebugBuild)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $Html) { $Html = Join-Path $root 'dist\PDF-Studio\app\PDF-Studio.html' }
if (-not (Test-Path $Html)) { throw "Missing $Html. Run ""npm run build"" first, or pass -Html path\to\PDF-Studio.html." }
$version = (Get-Content (Join-Path $root 'package.json') -Raw | ConvertFrom-Json).version
if ($version -notmatch '^\d+\.\d+\.\d+$') { $version = '1.0.0' }

$wvVersion = '1.0.4314.35'
$wvSha256 = '90778DEB1B77E36292828B4B5833C9255C27533F40E0DDD55891AE718944EDC4'
$pkg = Join-Path $root "vendor\microsoft.web.webview2.$wvVersion.nupkg"
if (-not (Test-Path $pkg)) {
  New-Item -ItemType Directory -Force (Split-Path $pkg) | Out-Null
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Write-Host "Downloading the WebView2 SDK $wvVersion from nuget.org..."
  Invoke-WebRequest "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$wvVersion/microsoft.web.webview2.$wvVersion.nupkg" -OutFile $pkg -UseBasicParsing
}
if ((Get-FileHash $pkg -Algorithm SHA256).Hash -ne $wvSha256) {
  Remove-Item $pkg -Force
  throw "The WebView2 SDK package failed its checksum and was deleted. Run the build again to download it again."
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('pdfstudio-build-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmp | Out-Null
try {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [IO.Compression.ZipFile]::ExtractToDirectory($pkg, (Join-Path $tmp 'wv'))
  $core = Join-Path $tmp 'wv\lib\net462\Microsoft.Web.WebView2.Core.dll'
  $winforms = Join-Path $tmp 'wv\lib\net462\Microsoft.Web.WebView2.WinForms.dll'
  $loader = Join-Path $tmp 'wv\runtimes\win-x64\native\WebView2Loader.dll'
  foreach ($f in $core, $winforms, $loader) {
    $sig = Get-AuthenticodeSignature $f
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
      throw "$(Split-Path $f -Leaf) is not signed by Microsoft ($($sig.Status))."
    }
  }

  $name = if ($DebugBuild) { 'PDF-Studio-Windows-Debug' } else { 'PDF-Studio-Windows' }
  $out = Join-Path $root "dist\$name"
  if (Test-Path $out) { Remove-Item $out -Recurse -Force }
  New-Item -ItemType Directory -Force (Join-Path $out 'app') | Out-Null

  $versionCs = Join-Path $tmp 'Version.cs'
  @"
[assembly: System.Reflection.AssemblyTitle("PDF Studio")]
[assembly: System.Reflection.AssemblyProduct("PDF Studio")]
[assembly: System.Reflection.AssemblyDescription("PDF reader and editor, and Markdown reader")]
[assembly: System.Reflection.AssemblyVersion("$version.0")]
[assembly: System.Reflection.AssemblyFileVersion("$version.0")]
"@ | Set-Content -Path $versionCs -Encoding UTF8

  $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
  if (-not (Test-Path $csc)) { throw "The C# compiler of .NET Framework 4.8 was not found at $csc." }
  $cscArgs = @('/nologo', '/target:winexe', '/platform:x64', '/utf8output', '/warn:4', '/nowarn:0168,0219',
    "/out:$(Join-Path $out 'PDFStudio.exe')",
    "/win32manifest:$(Join-Path $root 'windows\app.manifest')",
    "/reference:$core", "/reference:$winforms",
    '/reference:System.dll', '/reference:System.Core.dll', '/reference:System.Drawing.dll',
    '/reference:System.Windows.Forms.dll', '/reference:System.Web.Extensions.dll')
  $icon = Join-Path $root 'assets\pdf-studio.ico'
  if (Test-Path $icon) { $cscArgs += "/win32icon:$icon" }
  if ($DebugBuild) { $cscArgs += '/define:DEBUG', '/debug:full' } else { $cscArgs += '/optimize+', '/debug-' }
  $cscArgs += (Join-Path $root 'windows\PDFStudio.cs'), $versionCs
  & $csc @cscArgs
  if ($LASTEXITCODE -ne 0) { throw "The C# compiler reported errors (exit code $LASTEXITCODE)." }

  Copy-Item $core, $winforms, $loader $out
  Copy-Item (Join-Path $root 'windows\PDFStudio.exe.config') $out
  Copy-Item $Html (Join-Path $out 'app\PDF-Studio.html')
  if (Test-Path $icon) { Copy-Item $icon $out }
  foreach ($f in 'install.ps1', 'uninstall.ps1', 'Install PDF Studio.bat') {
    $text = (Get-Content (Join-Path $root "windows\$f") -Raw) -replace "`r?`n", "`r`n"
    [IO.File]::WriteAllText((Join-Path $out $f), $text, (New-Object Text.UTF8Encoding $true))
  }
  Write-Host "Built $(Join-Path $out 'PDFStudio.exe') (version $version)"
} finally {
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
