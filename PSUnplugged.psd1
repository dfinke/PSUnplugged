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
        'Start-CodexSession'
        'Stop-CodexSession'
        'New-CodexThread'
        'Resume-CodexThread'
        'Invoke-CodexTurn'
        'Invoke-CodexQuestion'
        'Get-CodexThreads'
        'Get-CodexModels'
        'Invoke-CodexCommand'
        'Get-CodexAccount'
        'Send-CodexRequest'
        'Send-CodexNotification'
        'Read-CodexNotifications'
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
