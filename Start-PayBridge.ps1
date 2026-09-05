param([int]$Port = 9292)
$ErrorActionPreference = 'Stop'
if ($Port -lt 1024 -or $Port -gt 65535) { throw 'Choose a port between 1024 and 65535.' }
$rubyCommand = Get-Command ruby -ErrorAction SilentlyContinue
$taskRuntime = Join-Path $PSScriptRoot '../../work/runtime/rubyinstaller-3.2.9-1-x64/bin'
if ($rubyCommand) {
    $rubyExecutable = $rubyCommand.Source
} elseif (Test-Path -LiteralPath (Join-Path $taskRuntime 'ruby.exe')) {
    $rubyExecutable = (Resolve-Path -LiteralPath (Join-Path $taskRuntime 'ruby.exe')).Path
} else {
    throw 'Ruby 3.2+ is required. Install Ruby, run bundle install, then start this script again.'
}
$savedPath = $env:PATH
Push-Location $PSScriptRoot
try {
    $rubyBin = Split-Path -Parent $rubyExecutable
    $env:PATH = $rubyBin + ';' + $env:PATH
    $bundleExecutable = Join-Path $rubyBin 'bundle'
    if (-not (Test-Path -LiteralPath $bundleExecutable)) { throw 'Bundler is required. Run gem install bundler.' }
    & $rubyExecutable $bundleExecutable check
    if ($LASTEXITCODE -ne 0) { throw 'Dependencies are missing. Run bundle install in this project.' }
    Write-Host "PayBridge: http://127.0.0.1:$Port (Ctrl+C to stop)"
    & $rubyExecutable $bundleExecutable exec rackup --host 127.0.0.1 --port $Port
} finally {
    $env:PATH = $savedPath
    Pop-Location
}
