param([string]$ToolJavaHome='C:\Program Files\Android\Android Studio\jbr')
$ErrorActionPreference='Stop'
$classes=Join-Path $PSScriptRoot 'build\tests'
New-Item -ItemType Directory -Force -Path $classes | Out-Null
& (Join-Path $ToolJavaHome 'bin\javac.exe') --release 17 -encoding UTF-8 -d $classes (Join-Path $PSScriptRoot 'app\src\main\java\br\net\luciano\duo\SitePolicy.java') (Join-Path $PSScriptRoot 'tests\SitePolicyTest.java')
if($LASTEXITCODE -ne 0){throw 'Falha ao compilar testes Android'}
& (Join-Path $ToolJavaHome 'bin\java.exe') -cp $classes SitePolicyTest
if($LASTEXITCODE -ne 0){throw 'Falha nos testes Android'}

& node (Join-Path $PSScriptRoot 'tests\native-bridge.mjs')
if($LASTEXITCODE -ne 0){throw 'Falha na integração de exportação Android'}
