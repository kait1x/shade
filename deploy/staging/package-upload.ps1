# Shade v2 STAGING upload packaging (рабочая машина, Windows).
# Собирает каталог upload для deploy/staging/staging-deploy.sh (или ручной
# установки shade-staging). НИКОГДА не включает: .env, секреты, ключи (.jks,
# key.properties), сертификаты, node_modules, данные (data/, *.enc),
# production-конфиги (client/config/production.json, google.local.json),
# тестовые БД и build-артефакты Android.
#
# Usage:
#   pwsh -File deploy/staging/package-upload.ps1 [-Out <dir>] [-SkipWebBuild]
# Результат: <Out>/server, <Out>/client/web, <Out>/client/build/web-alpha,
# <Out>/shade-staging.service, <Out>/Caddyfile.staging-block, <Out>/README.txt
# env заполняет ВЛАДЕЛЕЦ на сервере (staging.env.example -> staging.env).
param(
  [string]$Out = "$PWD\build\staging-upload",
  [switch]$SkipWebBuild
)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$client = Join-Path $root 'client'
$server = Join-Path $root 'server'

if (-not $SkipWebBuild) {
  $env:PATH = "C:\src\flutter\bin;$env:PATH"
  Push-Location $client
  try { python tools/build_web_alpha.py } finally { Pop-Location }
}
$webAlpha = Join-Path $client 'build\web-alpha'
if (-not (Test-Path (Join-Path $webAlpha 'main.dart.js'))) {
  throw 'web-alpha build missing; run without -SkipWebBuild'
}

if (Test-Path $Out) { Remove-Item $Out -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Out | Out-Null

# server: исходники + package manifests; без node_modules/data/.env/certs/build.
$dstServer = Join-Path $Out 'server'
New-Item -ItemType Directory -Force -Path $dstServer | Out-Null
Get-ChildItem $server -File | Where-Object {
  $_.Name -match '\.(mjs|js|json)$' -and $_.Name -notmatch '\.env'
} | ForEach-Object { Copy-Item $_.FullName $dstServer }
foreach ($sub in 'multidevice', 'tools', 'test', 'admin') {
  $src = Join-Path $server $sub
  if (Test-Path $src) {
    Copy-Item $src (Join-Path $dstServer $sub) -Recurse
  }
}
# Чистка запрещённого в скопированных подкаталогах (ОТНОСИТЕЛЬНЫЕ пути:
# абсолютный путь назначения может содержать \build\ и не должен влиять).
Get-ChildItem $dstServer -Recurse -File | Where-Object {
  $rel = $_.FullName.Substring($dstServer.Length)
  $_.Name -match '\.env$|\.pem$|\.key$|\.crt$|\.enc$|\.jks$' -or
  $rel -match '\\data\\|\\node_modules\\|\\build\\'
} | Remove-Item -Force
Get-ChildItem $dstServer -Recurse -Directory | Where-Object {
  $_.Name -in @('node_modules', 'data', 'build')
} | Remove-Item -Recurse -Force

# client/web (alpha shell/protocol/sw) и web-alpha build.
New-Item -ItemType Directory -Force -Path (Join-Path $Out 'client') | Out-Null
Copy-Item (Join-Path $client 'web') (Join-Path $Out 'client\web') -Recurse
New-Item -ItemType Directory -Force -Path (Join-Path $Out 'client\build') | Out-Null
Copy-Item $webAlpha (Join-Path $Out 'client\build\web-alpha') -Recurse
# В client/web не должно быть секретов/локальных конфигов.
Get-ChildItem (Join-Path $Out 'client') -Recurse -File | Where-Object {
  $_.Name -match '\.env$|\.pem$|\.key$|\.jks$|production\.json|google\.local\.json'
} | Remove-Item -Force

# Сервис + Caddy-блок (шаблоны; env НЕ включается).
Copy-Item (Join-Path $PSScriptRoot 'shade-staging.service.example') (Join-Path $Out 'shade-staging.service')
Copy-Item (Join-Path $PSScriptRoot 'Caddyfile.staging.example') (Join-Path $Out 'Caddyfile.staging-block')
Copy-Item (Join-Path $PSScriptRoot 'staging.env.example') (Join-Path $Out 'staging.env.example')
Copy-Item (Join-Path $PSScriptRoot 'staging-deploy.sh') (Join-Path $Out 'staging-deploy.sh')
Copy-Item (Join-Path $PSScriptRoot 'smoke-staging.sh') (Join-Path $Out 'smoke-staging.sh')
Copy-Item (Join-Path $PSScriptRoot 'admin-update-challenge.sh') (Join-Path $Out 'admin-update-challenge.sh')
# Bake the exact package commit into the shipped switch script (fail-closed
# placeholder otherwise); MANIFEST.meta records the same HEAD.
$head = git -C $root rev-parse HEAD
$shipped = Join-Path $Out 'admin-update-challenge.sh'
(Get-Content $shipped -Raw) -replace '__SET_AT_PACK_TIME__', $head | Set-Content $shipped -Encoding UTF8 -NoNewline
Copy-Item (Join-Path $PSScriptRoot 'make-manifest.py') (Join-Path $Out 'make-manifest.py')

@"
Shade v2 staging upload (generated $(Get-Date -Format s)).
Runtime user: shade-staging (owner request 17.11.2026).
staging-deploy.sh в этом пакете использует именование shade-alpha (ранняя
сессия) — ПЕРЕД запуском согласовать именование с владельцем либо выполнить
ручную установку по deploy/staging/setup-staging.sh + shade-staging.service.
env: владелец заполняет staging.env.example -> /var/lib/shade-staging/staging.env
на сервере (путь задаёт systemd-юнит; новые секреты, отдельный OAuth-клиент).
Никаких секретов в пакете нет.
Состав: server/ (исходники, npm ci на сервере), client/web/, client/build/web-alpha/,
shade-staging.service, Caddyfile.staging-block, staging.env.example, скрипты,
MANIFEST.sha256 + MANIFEST.meta (commit-bound, генерируются make-manifest.py).
Переключение: admin-update-challenge.sh (root), процедура docs/STAGING_RELEASE_5783295.md.
"@ | Set-Content (Join-Path $Out 'README.txt') -Encoding UTF8

# Commit-bound MANIFEST for the release runtime (server/ + client/).
python (Join-Path $PSScriptRoot 'make-manifest.py') $Out
if ($LASTEXITCODE -ne 0) { throw 'MANIFEST generation failed' }

$size = (Get-ChildItem $Out -Recurse -File | Measure-Object Length -Sum).Sum
"UPLOAD READY: $Out ($([math]::Round($size/1MB,1)) MB)"
"Secrets check:"
$leaks = Get-ChildItem $Out -Recurse -File | Where-Object {
  $_.Name -match '\.env$|\.jks$|\.pem$|\.key$|key\.properties|production\.json|google\.local\.json|\.enc$'
}
if ($leaks) { $leaks | ForEach-Object { "LEAK: $($_.FullName)" }; throw 'secret-like files found' }
"no secret-like files"
