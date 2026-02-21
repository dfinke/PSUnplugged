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
        'Get-CodexThreads'
        'Invoke-CodexCommand'
        'Invoke-CodexQuestion'
        'Invoke-CodexTurn'
        'New-CodexThread'
        'Read-CodexNotifications'
        'Resume-CodexThread'
        'Send-CodexNotification'
        'Send-CodexRequest'
        'Start-CodexSession'
        'Stop-CodexSession'
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
