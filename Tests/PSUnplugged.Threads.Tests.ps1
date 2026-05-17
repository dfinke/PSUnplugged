#requires -Version 7.0

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:ThreadModulePath = Join-Path $script:RepoRoot 'Threads\PSUnplugged.Threads.psm1'
    $script:ModuleUnderTestName = 'PSUnplugged.Threads.UnderTest'
    $script:ModuleUnderTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('PSUnpluggedThreadTests-' + [guid]::NewGuid().ToString('N'))
    $script:ModuleUnderTestPath = Join-Path $script:ModuleUnderTestRoot "$script:ModuleUnderTestName.psm1"

    New-Item -ItemType Directory -Path $script:ModuleUnderTestRoot | Out-Null
    Copy-Item -LiteralPath $script:ThreadModulePath -Destination $script:ModuleUnderTestPath
    Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'Threads\PSUnplugged.Threads.Format.ps1xml') -Destination $script:ModuleUnderTestRoot
    Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'Threads\Private') -Destination $script:ModuleUnderTestRoot -Recurse

    Get-Module $script:ModuleUnderTestName -All | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module $script:ModuleUnderTestPath -Force -DisableNameChecking
}

AfterAll {
    Get-Module $script:ModuleUnderTestName -All | Remove-Module -Force -ErrorAction SilentlyContinue
    if (
        -not [string]::IsNullOrWhiteSpace($script:ModuleUnderTestRoot) -and
        (Test-Path -LiteralPath $script:ModuleUnderTestRoot) -and
        ([System.IO.Path]::GetFullPath($script:ModuleUnderTestRoot)).StartsWith([System.IO.Path]::GetTempPath(), [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        Remove-Item -LiteralPath $script:ModuleUnderTestRoot -Recurse -Force
    }
}

Describe 'PSUnplugged task lifecycle regressions' {
    Context 'Project location resolution' {
        It 'resolves missing relative paths from the PowerShell location' {
            $testRoot = (Get-Item -LiteralPath TestDrive:\).FullName
            $expectedPath = Join-Path $testRoot 'periodicTable'
            $originalCurrentDirectory = [Environment]::CurrentDirectory

            Push-Location -LiteralPath $testRoot
            try {
                [Environment]::CurrentDirectory = [Environment]::SystemDirectory

                InModuleScope -ModuleName $script:ModuleUnderTestName -Parameters @{ ExpectedPath = $expectedPath } {
                    param([string]$ExpectedPath)

                    Resolve-CodexProjectLocation -Path '.\periodicTable' -AllowMissing |
                        Should -Be $ExpectedPath
                }
            }
            finally {
                [Environment]::CurrentDirectory = $originalCurrentDirectory
                Pop-Location
            }
        }
    }

    Context 'Worker completion status' {
        It 'ignores stale worker completion for remote thread snapshots without worker metadata' {
            InModuleScope -ModuleName $script:ModuleUnderTestName {
                Mock Get-CodexTaskTerminalStatusFromSessionFile { $null }
                Mock Resolve-CodexTaskSessionPath { $null }
                Mock Test-CodexTaskWorkerCompleted { $true }

                $task = [pscustomobject]@{
                    ThreadId = '019e057c-0ae5-7021-a840-f01ef836a9db'
                    Status   = 'active'
                    Source   = 'Remote'
                }

                Get-CodexTaskEffectiveStatus -InputObject $task | Should -Be 'active'
                Should -Invoke Test-CodexTaskWorkerCompleted -Times 0 -Exactly
            }
        }

        It 'still treats stopped task worker handles as failed' {
            InModuleScope -ModuleName $script:ModuleUnderTestName {
                Mock Get-CodexTaskTerminalStatusFromSessionFile { $null }
                Mock Resolve-CodexTaskSessionPath { $null }
                Mock Test-CodexTaskWorkerCompleted { $true }

                $task = [pscustomobject]@{
                    ThreadId        = '019e057c-0ae5-7021-a840-f01ef836a9db'
                    Status          = 'active'
                    Source          = 'Local'
                    WorkerProcessId = 999999
                }

                Get-CodexTaskEffectiveStatus -InputObject $task | Should -Be 'failed'
                Should -Invoke Test-CodexTaskWorkerCompleted -Times 1 -Exactly
            }
        }

        It 'does not add worker-stopped diagnostics to remote task output without worker metadata' {
            InModuleScope -ModuleName $script:ModuleUnderTestName {
                Mock Get-CodexTaskTerminalInfoFromSessionFile { [pscustomobject]@{} }
                Mock Get-CodexTaskTerminalStatusFromSessionFile { $null }
                Mock Resolve-CodexTaskSessionPath { $null }
                Mock Get-CodexTaskDiagnosticErrorMessage { $null }
                Mock Test-CodexTaskWorkerCompleted { $true }

                $task = [pscustomobject]@{
                    ThreadId = '019e057c-0ae5-7021-a840-f01ef836a9db'
                    Status   = 'active'
                    Source   = 'Remote'
                }

                $result = $task | ConvertTo-CodexTaskOutput

                $result.Status | Should -Be 'active'
                $result.LastErrorMessage | Should -BeNullOrEmpty
                Should -Invoke Test-CodexTaskWorkerCompleted -Times 0 -Exactly
            }
        }
    }

    Context 'Task removal' {
        It 'archives the resolved task id with meaningful task metadata' {
            InModuleScope -ModuleName $script:ModuleUnderTestName {
                Mock Set-CodexThread { [pscustomobject]$PSBoundParameters }

                $task = [pscustomobject]@{
                    TaskId = '019e057c-0ae5-7021-a840-f01ef836a9db'
                    Name   = 'periodicTable'
                    Path   = 'D:\temp\periodicTable'
                }

                $null = $task | Remove-CodexTask

                Should -Invoke Set-CodexThread -Times 1 -Exactly -ParameterFilter {
                    $ThreadId -eq '019e057c-0ae5-7021-a840-f01ef836a9db' -and
                    $Archive -and
                    $Name -eq 'periodicTable' -and
                    $ProjectPath -eq 'D:\temp\periodicTable'
                }
            }
        }

        It 'does not write Untitled thread back as an archive name' {
            InModuleScope -ModuleName $script:ModuleUnderTestName {
                Mock Set-CodexThread { [pscustomobject]$PSBoundParameters }

                $task = [pscustomobject]@{
                    TaskId  = '019e057c-0ae5-7021-a840-f01ef836a9db'
                    Name    = 'Untitled thread'
                    Project = 'periodicTable'
                }

                $null = $task | Remove-CodexTask

                Should -Invoke Set-CodexThread -Times 1 -Exactly -ParameterFilter {
                    $ThreadId -eq '019e057c-0ae5-7021-a840-f01ef836a9db' -and
                    $Archive -and
                    -not $PSBoundParameters.ContainsKey('Name') -and
                    $ProjectName -eq 'periodicTable'
                }
            }
        }
    }

    Context 'Wait task tailing' {
        It 'does not assign to the Text switch variable inside Wait-CodexTask' {
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $script:ThreadModulePath,
                [ref]$tokens,
                [ref]$parseErrors
            )

            $parseErrors | Should -BeNullOrEmpty
            $waitFunction = $ast.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq 'Wait-CodexTask'
                }, $true)

            $waitFunction | Should -Not -BeNullOrEmpty

            $textAssignments = @(
                $waitFunction.Body.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        $node.Left.Extent.Text -eq '$text'
                    }, $true)
            )

            $textAssignments | Should -BeNullOrEmpty
        }
    }
}
