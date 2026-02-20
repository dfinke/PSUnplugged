<#
.SYNOPSIS
    Renders Markdown text with ANSI colors and formatting in the terminal.

.DESCRIPTION
    Converts Markdown to pretty terminal output with:
    - Bold headers (colored by level)
    - Bold and italic text
    - Syntax-highlighted code blocks with language labels
    - Colored inline code
    - Bullet and numbered lists with indentation
    - Horizontal rules
    - Blockquotes
    - Links and images
    - Tables with box-drawing characters

.EXAMPLE
    "# Hello`n`nThis is **bold** and ``code``" | Show-Markdown

.EXAMPLE
    $response = Read-TurnEvents -Writer $w -Reader $r
    Show-Markdown $response
#>

function Get-DisplayWidth {
    param([string]$Text)
    $w = 0
    foreach ($ch in $Text.ToCharArray()) {
        $cp = [int]$ch
        # CJK, fullwidth, and common wide Unicode ranges
        if (($cp -ge 0x1100 -and $cp -le 0x115F) -or
            ($cp -ge 0x2E80 -and $cp -le 0x303E) -or
            ($cp -ge 0x3040 -and $cp -le 0x9FFF) -or
            ($cp -ge 0xAC00 -and $cp -le 0xD7AF) -or
            ($cp -ge 0xF900 -and $cp -le 0xFAFF) -or
            ($cp -ge 0xFE30 -and $cp -le 0xFE6F) -or
            ($cp -ge 0xFF01 -and $cp -le 0xFF60) -or
            ($cp -ge 0xFFE0 -and $cp -le 0xFFE6)) {
            $w += 2
        }
        else {
            $w += 1
        }
    }
    $w
}

function Show-Markdown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, Position = 0)]
        [AllowEmptyString()]
        [string]$Markdown
    )

    begin {
        $allText = [System.Collections.Generic.List[string]]::new()
    }

    process {
        $allText.Add($Markdown)
    }

    end {
        $text = $allText -join "`n"
        if ([string]::IsNullOrWhiteSpace($text)) { return }

        # ── ANSI escape sequences ──
        $esc = [char]27
        $reset = "$esc[0m"
        $bold = "$esc[1m"
        $dim = "$esc[2m"
        $italic = "$esc[3m"
        $underline = "$esc[4m"
        $strike = "$esc[9m"

        # Colors
        $cH1 = "$esc[1;38;5;39m"     # Bold bright blue
        $cH2 = "$esc[1;38;5;114m"    # Bold green
        $cH3 = "$esc[1;38;5;214m"    # Bold orange
        $cH4 = "$esc[1;38;5;183m"    # Bold lavender
        $cCode = "$esc[38;5;223m"      # Warm yellow for inline code
        $cCodeBg = "$esc[48;5;236m"      # Dark background for inline code
        $cBlock = "$esc[38;5;250m"      # Light gray for code blocks
        $cBlockBg = "$esc[48;5;235m"      # Darker background for blocks
        $cBlockLn = "$esc[38;5;240m"      # Line numbers
        $cLang = "$esc[38;5;245m"      # Language label
        $cBullet = "$esc[38;5;75m"       # Blue bullets
        $cQuote = "$esc[38;5;248m"      # Gray quotes
        $cQuoteBar = "$esc[38;5;240m"      # Dark gray bar
        $cLink = "$esc[4;38;5;75m"     # Underlined blue
        $cBold = "$esc[1;38;5;255m"    # Bright white bold
        $cItalic = "$esc[3;38;5;252m"    # Italic light
        $cHR = "$esc[38;5;240m"      # Dim horizontal rule
        $cTable = "$esc[38;5;245m"      # Table borders
        $cTableH = "$esc[1;38;5;75m"     # Table headers

        $lines = $text -split "`n"
        $i = 0
        $inCodeBlock = $false
        $codeLang = ""
        $codeLines = @()

        while ($i -lt $lines.Count) {
            $line = $lines[$i]

            # ── Code blocks ──
            if ($line -match '^```(.*)$') {
                if (-not $inCodeBlock) {
                    $inCodeBlock = $true
                    $codeLang = $Matches[1].Trim()
                    $codeLines = @()
                    $i++
                    continue
                }
                else {
                    # Render the collected code block
                    $inCodeBlock = $false

                    # Trim trailing whitespace, expand tabs, measure display width
                    $codeLines = $codeLines | ForEach-Object { $_.TrimEnd() -replace "`t", "    " }
                    $displayWidths = @($codeLines | ForEach-Object { Get-DisplayWidth $_ })
                    $maxDisplay = ($displayWidths | Measure-Object -Maximum).Maximum
                    if ($null -eq $maxDisplay -or $maxDisplay -lt 1) { $maxDisplay = 1 }
                    $boxInner = $maxDisplay + 7  # │ + space + num(3) + space + content + space + │

                    if ($codeLang) {
                        $langExtra = 4 + $codeLang.Length  # ╭─ LANG ╮ minus dashes
                        Write-Host "  $cLang╭─ $codeLang $("─" * [Math]::Max(0, $boxInner - $langExtra))╮$reset"
                    }
                    else {
                        Write-Host "  $cLang╭$("─" * ($boxInner - 1))╮$reset"
                    }

                    $lineNum = 1
                    $lineIdx = 0
                    foreach ($cl in $codeLines) {
                        $numStr = $lineNum.ToString().PadLeft(3)
                        $dw = $displayWidths[$lineIdx]
                        $pad = $maxDisplay - $dw
                        $padded = $cl + (" " * [Math]::Max(0, $pad))
                        Write-Host "  $cLang│$reset $cBlockLn$numStr$reset $cBlockBg$cBlock$padded$reset $cLang│$reset"
                        $lineNum++
                        $lineIdx++
                    }

                    Write-Host "  $cLang╰$("─" * ($boxInner - 1))╯$reset"
                    Write-Host ""
                    $i++
                    continue
                }
            }

            if ($inCodeBlock) {
                $codeLines += $line
                $i++
                continue
            }

            # ── Blank lines ──
            if ([string]::IsNullOrWhiteSpace($line)) {
                Write-Host ""
                $i++
                continue
            }

            # ── Headers ──
            if ($line -match '^(#{1,6})\s+(.+)$') {
                $level = $Matches[1].Length
                $title = $Matches[2]
                $color = switch ($level) {
                    1 { $cH1 }
                    2 { $cH2 }
                    3 { $cH3 }
                    default { $cH4 }
                }
                $prefix = switch ($level) {
                    1 { "▌ " }
                    2 { "│ " }
                    3 { "  " }
                    default { "  " }
                }
                Write-Host ""
                Write-Host "$color$prefix$title$reset"
                if ($level -eq 1) {
                    Write-Host "$color$("─" * ($title.Length + 2))$reset"
                }
                Write-Host ""
                $i++
                continue
            }

            # ── Horizontal rule ──
            if ($line -match '^[-*_]{3,}\s*$') {
                Write-Host "  $cHR$("─" * 50)$reset"
                Write-Host ""
                $i++
                continue
            }

            # ── Blockquote ──
            if ($line -match '^>\s?(.*)$') {
                $quoteText = Format-InlineMarkdown $Matches[1] $cCode $cCodeBg $cBold $cItalic $cLink $cStrike $reset $bold $italic $underline $strike
                Write-Host "  $cQuoteBar▐$reset $cQuote$quoteText$reset"
                $i++
                continue
            }

            # ── Table detection ──
            if ($line -match '^\|' -and ($i + 1) -lt $lines.Count -and $lines[$i + 1] -match '^\|[\s\-:|]+\|') {
                $tableLines = @()
                while ($i -lt $lines.Count -and $lines[$i] -match '^\|') {
                    if ($lines[$i] -notmatch '^\|[\s\-:|]+\|$') {
                        $tableLines += $lines[$i]
                    }
                    $i++
                }
                Render-Table $tableLines $cTable $cTableH $reset $bold
                Write-Host ""
                continue
            }

            # ── Unordered list ──
            if ($line -match '^(\s*)([-*+])\s+(.+)$') {
                $indent = [Math]::Floor($Matches[1].Length / 2)
                $content = Format-InlineMarkdown $Matches[3] $cCode $cCodeBg $cBold $cItalic $cLink $cStrike $reset $bold $italic $underline $strike
                $pad = "  " * $indent
                $bullet = switch ($indent) { 0 { "●" } 1 { "○" } default { "▪" } }
                Write-Host "  $pad$cBullet$bullet$reset $content"
                $i++
                continue
            }

            # ── Ordered list ──
            if ($line -match '^(\s*)(\d+)[.)]\s+(.+)$') {
                $indent = [Math]::Floor($Matches[1].Length / 2)
                $num = $Matches[2]
                $content = Format-InlineMarkdown $Matches[3] $cCode $cCodeBg $cBold $cItalic $cLink $cStrike $reset $bold $italic $underline $strike
                $pad = "  " * $indent
                Write-Host "  $pad$cBullet$num.$reset $content"
                $i++
                continue
            }

            # ── Regular paragraph ──
            $formatted = Format-InlineMarkdown $line $cCode $cCodeBg $cBold $cItalic $cLink $cStrike $reset $bold $italic $underline $strike
            Write-Host "  $formatted"
            $i++
        }

        # Handle unclosed code block
        if ($inCodeBlock -and $codeLines.Count -gt 0) {
            foreach ($cl in $codeLines) {
                Write-Host "  $cBlockBg$cBlock  $cl$reset"
            }
        }
    }
}

function Format-InlineMarkdown {
    param(
        [string]$Text,
        [string]$cCode, [string]$cCodeBg,
        [string]$cBold, [string]$cItalic, [string]$cLink, [string]$cStrike,
        [string]$reset, [string]$bold, [string]$italic, [string]$underline, [string]$strike
    )

    $esc = [char]27

    # Bold + italic ***text***
    $Text = [regex]::Replace($Text, '\*{3}(.+?)\*{3}', "$cBold$($esc)[3m`$1$reset")

    # Bold **text** or __text__
    $Text = [regex]::Replace($Text, '\*{2}(.+?)\*{2}', "$cBold`$1$reset")
    $Text = [regex]::Replace($Text, '__(.+?)__', "$cBold`$1$reset")

    # Italic *text* or _text_ (but not inside words with underscores)
    $Text = [regex]::Replace($Text, '(?<!\w)\*(.+?)\*(?!\w)', "$cItalic`$1$reset")
    $Text = [regex]::Replace($Text, '(?<!\w)_(.+?)_(?!\w)', "$cItalic`$1$reset")

    # Strikethrough ~~text~~
    $Text = [regex]::Replace($Text, '~~(.+?)~~', "$($esc)[9m`$1$reset")

    # Inline code `text`
    $Text = [regex]::Replace($Text, '`([^`]+)`', "$cCodeBg$cCode `$1 $reset")

    # Links [text](url)
    $Text = [regex]::Replace($Text, '\[([^\]]+)\]\(([^)]+)\)', "$cLink`$1$reset $($esc)[38;5;240m(`$2)$reset")

    # Images ![alt](url)
    $Text = [regex]::Replace($Text, '!\[([^\]]*)\]\(([^)]+)\)', "$($esc)[38;5;240m[img: `$1]$reset")

    return $Text
}

function Render-Table {
    param(
        [string[]]$Lines,
        [string]$cTable, [string]$cTableH,
        [string]$reset, [string]$bold
    )

    # Parse cells
    $rows = foreach ($line in $Lines) {
        $cells = ($line.Trim('|') -split '\|') | ForEach-Object { $_.Trim() }
        , $cells
    }

    if ($rows.Count -eq 0) { return }

    # Calculate column widths
    $colCount = $rows[0].Count
    $widths = @(0) * $colCount
    foreach ($row in $rows) {
        for ($c = 0; $c -lt [Math]::Min($row.Count, $colCount); $c++) {
            if ($row[$c].Length -gt $widths[$c]) { $widths[$c] = $row[$c].Length }
        }
    }

    # Top border
    $top = ($widths | ForEach-Object { "─" * ($_ + 2) }) -join "┬"
    Write-Host "  $cTable┌$top┐$reset"

    for ($r = 0; $r -lt $rows.Count; $r++) {
        $row = $rows[$r]
        $color = if ($r -eq 0) { $cTableH } else { $reset }
        $cells = for ($c = 0; $c -lt $colCount; $c++) {
            $val = if ($c -lt $row.Count) { $row[$c] } else { "" }
            " $color$($val.PadRight($widths[$c]))$reset "
        }
        Write-Host "  $cTable│$reset$($cells -join "$cTable│$reset")$cTable│$reset"

        # Header separator
        if ($r -eq 0) {
            $sep = ($widths | ForEach-Object { "─" * ($_ + 2) }) -join "┼"
            Write-Host "  $cTable├$sep┤$reset"
        }
    }

    # Bottom border
    $bottom = ($widths | ForEach-Object { "─" * ($_ + 2) }) -join "┴"
    Write-Host "  $cTable└$bottom┘$reset"
}

Export-ModuleMember -Function Show-Markdown