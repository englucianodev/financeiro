param(
    [switch]$Release,
    [string]$AndroidSdk = "$env:LOCALAPPDATA\Android\Sdk",
    [string]$ToolJavaHome = 'C:\Program Files\Android\Android Studio\jbr',
    [string]$BuildToolsVersion = '36.0.0',
    [int]$Api = 36
)
$ErrorActionPreference = 'Stop'
$project = $PSScriptRoot
$build = Join-Path $project 'build\standalone'
$output = Join-Path $project 'build\outputs'
$tools = Join-Path $AndroidSdk "build-tools\$BuildToolsVersion"
$platform = Join-Path $AndroidSdk "platforms\android-$Api\android.jar"
$java = Join-Path $ToolJavaHome 'bin\java.exe'
$javac = Join-Path $ToolJavaHome 'bin\javac.exe'
$jar = Join-Path $ToolJavaHome 'bin\jar.exe'
$keytool = Join-Path $ToolJavaHome 'bin\keytool.exe'
foreach ($required in @($platform,$java,$javac,$jar,$keytool,(Join-Path $tools 'aapt2.exe'),(Join-Path $tools 'lib\d8.jar'),(Join-Path $tools 'lib\apksigner.jar'))) {
    if (!(Test-Path -LiteralPath $required)) { throw "Ferramenta não encontrada: $required" }
}
function Run([string]$Program,[string[]]$NativeArgs) {
    & $Program @NativeArgs
    if ($LASTEXITCODE -ne 0) { throw "Falha ao executar $Program (código $LASTEXITCODE)" }
}
foreach ($dir in @($build,$output,(Join-Path $build 'gen'),(Join-Path $build 'classes'),(Join-Path $build 'dex'))) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}
# Build metadata is generated here; the Gradle project supplies the same metadata normally.
[xml]$manifest = [System.IO.File]::ReadAllText((Join-Path $project 'app\src\main\AndroidManifest.xml'))
$androidNs = 'http://schemas.android.com/apk/res/android'
$manifest.manifest.SetAttribute('package','br.net.luciano.duo')
$manifest.manifest.SetAttribute('versionCode',$androidNs,'1') | Out-Null
$manifest.manifest.SetAttribute('versionName',$androidNs,'1.0.0') | Out-Null
# Compatible with Windows PowerShell 5.1 (no ternary operator).
$debuggable = if ($Release) { 'false' } else { 'true' }
$manifest.manifest.application.SetAttribute('debuggable',$androidNs,$debuggable) | Out-Null
$uses = $manifest.CreateElement('uses-sdk')
$uses.SetAttribute('minSdkVersion',$androidNs,'26') | Out-Null
$uses.SetAttribute('targetSdkVersion',$androidNs,"$Api") | Out-Null
$manifest.manifest.PrependChild($uses) | Out-Null
$manifestPath = Join-Path $build 'AndroidManifest.xml'
$manifest.Save($manifestPath)
Run (Join-Path $tools 'aapt2.exe') @('compile','--dir',(Join-Path $project 'app\src\main\res'),'-o',(Join-Path $build 'resources.zip'))
Run (Join-Path $tools 'aapt2.exe') @('link','-o',(Join-Path $build 'base.apk'),'-I',$platform,'--manifest',$manifestPath,'--java',(Join-Path $build 'gen'),(Join-Path $build 'resources.zip'))
$configDir = Join-Path $build 'gen\br\net\luciano\duo'
New-Item -ItemType Directory -Force -Path $configDir | Out-Null
[System.IO.File]::WriteAllText((Join-Path $configDir 'BuildConfig.java'),('package br.net.luciano.duo; public final class BuildConfig { public static final boolean DEBUG = '+$debuggable+'; }'))
$sources = @([System.IO.Directory]::GetFiles((Join-Path $project 'app\src\main\java'),'*.java',[System.IO.SearchOption]::AllDirectories)) + @([System.IO.Directory]::GetFiles((Join-Path $build 'gen'),'*.java',[System.IO.SearchOption]::AllDirectories))
Run $javac (@('--release','17','-encoding','UTF-8','-classpath',$platform,'-d',(Join-Path $build 'classes')) + $sources)
Run $jar @('--create','--file',(Join-Path $build 'classes.jar'),'-C',(Join-Path $build 'classes'),'.')
Run $java @('-cp',(Join-Path $tools 'lib\d8.jar'),'com.android.tools.r8.D8','--min-api','26','--lib',$platform,'--output',(Join-Path $build 'dex'),(Join-Path $build 'classes.jar'))
$unsigned = Join-Path $build 'unsigned.apk'
Copy-Item -LiteralPath (Join-Path $build 'base.apk') -Destination $unsigned -Force
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::Open($unsigned,[System.IO.Compression.ZipArchiveMode]::Update)
try {
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,(Join-Path $build 'dex\classes.dex'),'classes.dex',[System.IO.Compression.CompressionLevel]::NoCompression) | Out-Null
} finally { $archive.Dispose() }
$aligned = Join-Path $build 'aligned.apk'
Run (Join-Path $tools 'zipalign.exe') @('-f','4',$unsigned,$aligned)
$signing = Join-Path $project '.local-signing'
New-Item -ItemType Directory -Force -Path $signing | Out-Null
$apk = Join-Path $output 'Duo-Android.apk'
if ($Release) {
    $keystore = Join-Path $signing 'duo-release.p12'
    $passwordPath = Join-Path $signing 'duo-release-password.txt'
    if ((Test-Path -LiteralPath $keystore) -xor (Test-Path -LiteralPath $passwordPath)) { throw 'Assinatura de release incompleta. Restaure a chave e a senha do backup.' }
    if (!(Test-Path -LiteralPath $passwordPath)) {
        $bytes = New-Object byte[] 32
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
        $secret = -join ($bytes | ForEach-Object { $_.ToString('X2') })
        [System.IO.File]::WriteAllText($passwordPath,$secret)
    }
    $previousPassword = $env:DUO_SIGNING_PASSWORD
    try {
        $env:DUO_SIGNING_PASSWORD = [System.IO.File]::ReadAllText($passwordPath).Trim()
        if (!(Test-Path -LiteralPath $keystore)) {
            Run $keytool @('-genkeypair','-keystore',$keystore,'-storepass:env','DUO_SIGNING_PASSWORD','-keypass:env','DUO_SIGNING_PASSWORD','-alias','duorelease','-keyalg','RSA','-keysize','2048','-validity','10000','-dname','CN=Duo Android, O=Duo, C=BR','-storetype','PKCS12')
        }
        Run $java @('-jar',(Join-Path $tools 'lib\apksigner.jar'),'sign','--ks',$keystore,'--ks-pass','env:DUO_SIGNING_PASSWORD','--key-pass','env:DUO_SIGNING_PASSWORD','--ks-key-alias','duorelease','--out',$apk,$aligned)
    } finally { $env:DUO_SIGNING_PASSWORD = $previousPassword }
} else {
    $keystore = Join-Path $signing 'duo-development.jks'
    if (!(Test-Path -LiteralPath $keystore)) {
        Run $keytool @('-genkeypair','-keystore',$keystore,'-storepass','android','-keypass','android','-alias','androiddebugkey','-keyalg','RSA','-keysize','2048','-validity','10000','-dname','CN=Duo Development, O=Duo, C=BR','-storetype','JKS')
    }
    Run $java @('-jar',(Join-Path $tools 'lib\apksigner.jar'),'sign','--ks',$keystore,'--ks-pass','pass:android','--key-pass','pass:android','--ks-key-alias','androiddebugkey','--out',$apk,$aligned)
}
Run $java @('-jar',(Join-Path $tools 'lib\apksigner.jar'),'verify','--verbose',$apk)
Run (Join-Path $tools 'zipalign.exe') @('-c','4',$apk)
Write-Output "APK gerado: $apk"
Get-FileHash -LiteralPath $apk -Algorithm SHA256
