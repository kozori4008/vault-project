Push-Location (Join-Path $PSScriptRoot 'out')
& .\myapp.exe $args
$rc = $LASTEXITCODE
Pop-Location
exit $rc
