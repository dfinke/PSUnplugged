@{
    RootModule        = 'PSUnplugged.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '61f3ddba-3a4a-495e-95ac-6c47aaed4c24'
    Author            = 'Douglas Finke'
    CompanyName       = 'Douglas Finke'
    Copyright         = '(c) 2026 Douglas Finke. All rights reserved.'
    Description       = 'Terminal-native agentic AI for PowerShell. No IDE required.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Get-CodexAccount'
        'Get-CodexModels'
        'Get-CodexProject'
        'Get-CodexThread'
        'Get-CodexTranscript'
        'Get-CodexThreads'
        'Show-CodexTranscript'
        'Enter-CodexThread'
        'Invoke-CodexCommand'
        'Invoke-CodexQuestion'
        'Invoke-CodexTurn'
        'New-CodexPlaygroundProject'
        'New-CodexProject'
        'New-PlaygroundProject'
        'New-CodexThread'
        'Read-CodexNotifications'
        'Remove-CodexThread'
        'Resume-CodexThread'
        'Set-CodexThread'
        'Send-CodexNotification'
        'Send-CodexRequest'
        'Start-CodexSession'
        'Stop-CodexSession'
    )

    FormatsToProcess  = @(
        'Threads/PSUnplugged.Threads.Format.ps1xml'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData       = @{
        PSData = @{
            Tags       = @('AI', 'Agent', 'Codex', 'OpenAI', 'LLM', 'MCP', 'Agentic')
            LicenseUri = 'https://github.com/dfinke/PSUnplugged/blob/main/LICENSE'
            ProjectUri = 'https://github.com/dfinke/PSUnplugged'
        }
    }
}
