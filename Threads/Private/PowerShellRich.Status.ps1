# Adapted from D:\mygit\PowerShellRich\Public\Status.ps1
# to provide lightweight status spinners inside PSUnplugged.

$script:PSUnpluggedSpinners = @{
    dots         = @{
        interval = 80
        frames   = @("⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏")
    }
    dots2        = @{
        interval = 80
        frames   = @("⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷")
    }
    line         = @{
        interval = 130
        frames   = @("-", "\", "|", "/")
    }
    arc          = @{
        interval = 100
        frames   = @("◜", "◠", "◝", "◞", "◡", "◟")
    }
    moon         = @{
        interval = 80
        frames   = @("🌑", "🌒", "🌓", "🌔", "🌕", "🌖", "🌗", "🌘")
    }
    bouncingBall = @{
        interval = 80
        frames   = @("( ●    )", "(  ●   )", "(   ●  )", "(    ● )", "(     ●)", "(    ● )", "(   ●  )", "(  ●   )")
    }
}

function Test-PSUnpluggedSpinnerEnabled {
    [CmdletBinding()]
    param()

    if ($env:PSUNPLUGGED_NO_SPINNER -in @('1', 'true', 'yes')) {
        return $false
    }

    if (-not [Environment]::UserInteractive) {
        return $false
    }

    try {
        if ([Console]::IsOutputRedirected -or [Console]::IsErrorRedirected) {
            return $false
        }
    }
    catch {
        return $false
    }

    return $Host.Name -notmatch 'ServerRemoteHost|Visual Studio Code Host'
}

function New-PSUnpluggedSpinner {
    [CmdletBinding()]
    param(
        [string]$Name = 'dots',
        [string]$Text = '',
        [string]$Style = 'bold cyan',
        [double]$Speed = 1.0
    )

    if (-not $script:PSUnpluggedSpinners.ContainsKey($Name)) {
        throw "No spinner called '$Name'."
    }

    $spinnerDef = $script:PSUnpluggedSpinners[$Name]
    return @{
        Name      = $Name
        Frames    = $spinnerDef.frames
        Interval  = $spinnerDef.interval
        Text      = $Text
        Style     = $Style
        Speed     = $Speed
        StartTime = [DateTime]::Now
    }
}

function Start-PSUnpluggedStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Status,
        [string]$SpinnerName = 'dots',
        [string]$SpinnerStyle = 'bold cyan',
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )

    $spinner = New-PSUnpluggedSpinner -Name $SpinnerName -Text $Status -Style $SpinnerStyle
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()

    $powershell = [powershell]::Create().AddScript({
            param($spinner, $status)

            [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

            function Get-SimpleAnsi {
                param([string]$Style)

                $esc = [char]27
                $result = ''
                if ($Style -match 'bold') { $result += "$esc[1m" }
                if ($Style -match 'cyan') { $result += "$esc[36m" }
                if ($Style -match 'green') { $result += "$esc[32m" }
                if ($Style -match 'magenta') { $result += "$esc[35m" }
                if ($Style -match 'red') { $result += "$esc[31m" }
                if ($Style -match 'yellow') { $result += "$esc[33m" }
                if ($Style -match 'blue') { $result += "$esc[34m" }
                return $result
            }

            $frames = $spinner.Frames
            $styleCode = Get-SimpleAnsi -Style $spinner.Style
            $reset = "$([char]27)[0m"
            $index = 0

            [Console]::Write("$([char]27)[?25l")

            try {
                while ($true) {
                    $frame = $frames[$index % $frames.Count]
                    [Console]::Write("`r$([char]27)[K$styleCode$frame$reset $status")
                    $index++
                    [System.Threading.Thread]::Sleep([int]($spinner.Interval / $spinner.Speed))
                }
            }
            catch {
            }
            finally {
                [Console]::Write("`r$([char]27)[K$([char]27)[?25h")
            }
        }).AddArgument($spinner).AddArgument($Status)

    $powershell.Runspace = $runspace
    $null = $powershell.BeginInvoke()

    try {
        return (& $ScriptBlock)
    }
    finally {
        try { $powershell.Stop() } catch { }
        $runspace.Close()
        $powershell.Dispose()
        $runspace.Dispose()
        Write-Host -NoNewline "`r$([char]27)[K$([char]27)[?25h"
    }
}

function Invoke-PSUnpluggedWithSpinner {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Status,
        [string]$SpinnerName = 'dots',
        [string]$SpinnerStyle = 'bold cyan',
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )

    if ([string]::IsNullOrWhiteSpace($Status)) {
        return (& $ScriptBlock)
    }

    if (-not (Test-PSUnpluggedSpinnerEnabled)) {
        return (& $ScriptBlock)
    }

    return (Start-PSUnpluggedStatus -Status $Status -SpinnerName $SpinnerName -SpinnerStyle $SpinnerStyle -ScriptBlock $ScriptBlock)
}
