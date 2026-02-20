param ($fullPath)

if (-not $fullPath) {
    $fullpath = $env:PSModulePath -split ":(?!\\)|;|," | Select-Object -First 1
    $fullPath = Join-Path $fullPath -ChildPath "PSUnplugged"
}

Push-location $PSScriptRoot

Robocopy . $fullPath /mir /XD .vscode .git .github Examples /XF README.md plan.md .gitattributes .gitignore InstallModule.ps1 PublishToGallery.ps1

Pop-Location