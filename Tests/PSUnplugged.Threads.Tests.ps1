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
    Context 'Codex message router' {
        It 'routes JSON-RPC responses to their matching waiter' {
            InModuleScope -ModuleName $script:ModuleUnderTestName {
                $session = [pscustomobject]@{
                    Router = New-CodexMessageRouter
                }
                $waiter = [System.Collections.Concurrent.BlockingCollection[object]]::new(1)
                $session.Router.ResponseWaiters['request-1'] = $waiter

                Route-CodexTransportMessage -Session $session -Message ([pscustomobject]@{
                        id     = 'request-1'
                        result = [pscustomobject]@{ ok = $true }
                    })

                $item = $null
                $waiter.TryTake([ref]$item, 100) | Should -BeTrue
                $item.result.ok | Should -BeTrue
                $session.Router.ResponseWaiters.ContainsKey('request-1') | Should -BeFalse
            }
        }

        It 'replays pending turn notifications when the turn queue is registered' {
            InModuleScope -ModuleName $script:ModuleUnderTestName {
                $session = [pscustomobject]@{
                    Router = New-CodexMessageRouter
                }
                $notification = [pscustomobject]@{
                    method = 'item/completed'
                    params = [pscustomobject]@{
                        turnId = 'turn-1'
                        item   = [pscustomobject]@{ type = 'agentMessage'; text = 'Done.' }
                    }
                }

                Add-CodexRouterNotification -Session $session -Message $notification
                $session.Router.PendingTurnNotifications.ContainsKey('turn-1') | Should -BeTrue

                Register-CodexTurnQueue -Session $session -TurnId 'turn-1'
                $session.Router.PendingTurnNotifications.ContainsKey('turn-1') | Should -BeFalse

                $item = $null
                $session.Router.TurnQueues['turn-1'].TryTake([ref]$item, 100) | Should -BeTrue
                $item.params.item.text | Should -Be 'Done.'
            }
        }

        It 'routes live turn notifications to a pre-registered turn queue' {
            InModuleScope -ModuleName $script:ModuleUnderTestName {
                $session = [pscustomobject]@{
                    Router = New-CodexMessageRouter
                }

                Register-CodexTurnQueue -Session $session -TurnId 'turn-1'
                Add-CodexRouterNotification -Session $session -Message ([pscustomobject]@{
                        method = 'turn/completed'
                        params = [pscustomobject]@{ turnId = 'turn-1' }
                    })

                $item = $null
                $session.Router.TurnQueues['turn-1'].TryTake([ref]$item, 100) | Should -BeTrue
                $item.method | Should -Be 'turn/completed'
            }
        }

        It 'routes unscoped notifications to the global queue' {
            InModuleScope -ModuleName $script:ModuleUnderTestName {
                $session = [pscustomobject]@{
                    Router = New-CodexMessageRouter
                }

                Add-CodexRouterNotification -Session $session -Message ([pscustomobject]@{
                        method = 'thread/started'
                        params = [pscustomobject]@{ threadId = 'thread-1' }
                    })

                $item = $null
                $session.Router.GlobalNotifications.TryTake([ref]$item, 100) | Should -BeTrue
                $item.method | Should -Be 'thread/started'
            }
        }
    }

    Context 'Model resolution' {
        It 'uses the upgrade target for the default runtime model when no model is requested' {
            InModuleScope -ModuleName $script:ModuleUnderTestName {
                $script:CodexModelLookupCache = $null
                Mock Get-CodexModels {
                    [pscustomobject]@{
                        data = @(
                            [pscustomobject]@{
                                id        = 'gpt-5.3-codex'
                                model     = 'gpt-5.3-codex'
                                upgrade   = 'gpt-5.4'
                                isDefault = $true
                            },
                            [pscustomobject]@{
                                id        = 'gpt-5.4'
                                model     = 'gpt-5.4'
                                upgrade   = $null
                                isDefault = $false
                            }
                        )
                    }
                }

                Resolve-CodexRequestedModel -Session ([pscustomobject]@{}) -Model $null |
                    Should -Be 'gpt-5.4'
            }
        }
    }

    Context 'Task listing scope' {
        It 'lists recent tasks across projects by default' {
            InModuleScope -ModuleName $script:ModuleUnderTestName {
                Mock Import-PSUnpluggedCatalog { [pscustomobject]@{ projects = @(); threads = @() } }
                Mock Import-PSUnpluggedArchivedThreadIndex { @() }
                Mock Resolve-CodexTaskSessionPath { $null }
                Mock Get-CodexTaskTerminalInfoFromSessionFile { [pscustomobject]@{} }
                Mock Get-CodexTaskTerminalStatusFromSessionFile { $null }
                Mock Get-CodexTaskDiagnosticErrorMessage { $null }
                Mock Get-PSUnpluggedTaskWorkerHandles {
                    @(
                        [pscustomobject]@{
                            Id      = 'pending-1'
                            Name    = 'create largest'
                            Project = 'f1'
                            Path    = 'D:\temp\f1'
                            Status  = 'starting'
                        }
                    )
                }
                Mock Get-CodexThread {
                    $now = [DateTimeOffset]::Now
                    @(
                        [pscustomobject]@{
                            ThreadId       = '11111111-1111-7111-8111-111111111111'
                            Name           = 'fib task'
                            Project        = 'f2'
                            Path           = 'D:\temp\f2'
                            Status         = 'completed'
                            LastActivityAt = $now.AddMinutes(-10).ToString('o')
                        }
                        [pscustomobject]@{
                            ThreadId       = '22222222-2222-7222-8222-222222222222'
                            Name           = 'scratch task'
                            Project        = 'f3'
                            Path           = 'D:\temp\scratch\f3'
                            Status         = 'failed'
                            LastActivityAt = $now.AddDays(-3).ToString('o')
                        }
                    )
                }

                $tasks = @(Get-CodexTask -LocalOnly -Limit 25)

                $tasks.Project | Should -Contain 'f1'
                $tasks.Project | Should -Contain 'f2'
                $tasks.Project | Should -Contain 'f3'
                $tasks.Status | Should -Contain 'starting'
                $tasks.Status | Should -Contain 'completed'
                $tasks.Status | Should -Contain 'failed'
                Should -Invoke Get-PSUnpluggedTaskWorkerHandles -Times 1 -Exactly -ParameterFilter {
                    [string]::IsNullOrWhiteSpace($ProjectPath)
                }
                Should -Invoke Get-CodexThread -Times 1 -Exactly -ParameterFilter {
                    -not $PSBoundParameters.ContainsKey('Project')
                }
            }
        }

        It 'refreshes by default and uses the local catalog only when requested' {
            InModuleScope -ModuleName $script:ModuleUnderTestName {
                $calls = [System.Collections.Generic.List[object]]::new()
                $spinnerCalls = [System.Collections.Generic.List[object]]::new()
                Mock Import-PSUnpluggedCatalog { [pscustomobject]@{ projects = @(); threads = @() } }
                Mock Import-PSUnpluggedArchivedThreadIndex { @() }
                Mock Invoke-PSUnpluggedWithSpinner {
                    $spinnerCalls.Add([pscustomobject]@{ Status = $Status })
                    & $ScriptBlock
                }
                Mock Resolve-CodexTaskSessionPath { $null }
                Mock Get-CodexTaskTerminalInfoFromSessionFile { [pscustomobject]@{} }
                Mock Get-CodexTaskTerminalStatusFromSessionFile { $null }
                Mock Get-CodexTaskDiagnosticErrorMessage { $null }
                Mock Get-PSUnpluggedTaskWorkerHandles { @() }
                Mock Get-CodexThread {
                    $calls.Add([pscustomobject]@{
                            LocalOnly     = $LocalOnly.IsPresent
                            SpinnerStatus = $SpinnerStatus
                            BoundNames     = @($PSBoundParameters.Keys)
                        })
                    @(
                        [pscustomobject]@{
                            ThreadId       = '11111111-1111-7111-8111-111111111111'
                            Name           = 'local task'
                            Project        = 'local'
                            Status         = 'completed'
                            LastActivityAt = [DateTimeOffset]::Now.ToString('o')
                        }
                    )
                }

                $null = Get-CodexTask -Limit 25
                $calls[0].BoundNames | Should -Not -Contain 'LocalOnly'
                $spinnerCalls[0].Status | Should -Be 'Loading Codex tasks: reading catalog, refreshing app-server, preparing view...'

                $null = Get-CodexTask -LocalOnly -Limit 25
                $calls[1].LocalOnly | Should -BeTrue
                $spinnerCalls[1].Status | Should -Be 'Loading Codex tasks: reading local catalog and worker handles...'
            }
        }

        It 'normalizes legacy mixed catalog arrays before persisting refreshed tasks' {
            $oldPSUnpluggedHome = $env:PSUNPLUGGED_HOME
            $psUnpluggedHome = Join-Path (Get-Item -LiteralPath TestDrive:\).FullName 'psunplugged-home-mixed-catalog'
            New-Item -ItemType Directory -Path $psUnpluggedHome -Force | Out-Null

            try {
                $env:PSUNPLUGGED_HOME = $psUnpluggedHome
                InModuleScope -ModuleName $script:ModuleUnderTestName {
                    $catalogPath = Get-PSUnpluggedCatalogPath
                    @(
                        [pscustomobject]@{
                            version  = 1
                            projects = @()
                            threads  = @(
                                [pscustomobject]@{
                                    ThreadId       = '11111111-1111-7111-8111-111111111111'
                                    Name           = 'old local'
                                    ProjectName    = 'old'
                                    LastActivityAt = [DateTimeOffset]::Now.AddDays(-3).ToString('o')
                                }
                            )
                        }
                        [pscustomobject]@{
                            Id     = 'legacy-task-record'
                            Name   = 'Reply with exactly: OK'
                            Status = 'running'
                        }
                    ) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $catalogPath -Encoding utf8

                    $catalog = Import-PSUnpluggedCatalog
                    $catalog.PSObject.Properties.Name | Should -Contain 'threads'
                    @($catalog.threads).Count | Should -Be 1

                    $remoteTask = [pscustomobject]@{
                        ThreadId       = '22222222-2222-7222-8222-222222222222'
                        Name           = 'fib'
                        Project        = 'fib'
                        Path           = Join-Path (Get-Item -LiteralPath TestDrive:\).FullName 'fib'
                        Status         = 'completed'
                        LastActivityAt = [DateTimeOffset]::Now.ToString('o')
                    }
                    $changed = Update-CodexCatalogFromThreadOutputs -Catalog $catalog -Thread @($remoteTask)
                    $changed | Should -BeTrue
                    Export-PSUnpluggedCatalog -Catalog $catalog

                    $roundTrip = Import-PSUnpluggedCatalog
                    @($roundTrip.threads).Name | Should -Contain 'fib'
                    @($roundTrip).Count | Should -Be 1
                }
            }
            finally {
                $env:PSUNPLUGGED_HOME = $oldPSUnpluggedHome
            }
        }

        It 'hides old completed tasks from the default operator view unless history is requested' {
            InModuleScope -ModuleName $script:ModuleUnderTestName {
                $now = [DateTimeOffset]::Now
                Mock Import-PSUnpluggedCatalog { [pscustomobject]@{ projects = @(); threads = @() } }
                Mock Import-PSUnpluggedArchivedThreadIndex { @() }
                Mock Resolve-CodexTaskSessionPath { $null }
                Mock Get-CodexTaskTerminalInfoFromSessionFile { [pscustomobject]@{} }
                Mock Get-CodexTaskTerminalStatusFromSessionFile { $null }
                Mock Get-CodexTaskDiagnosticErrorMessage { $null }
                Mock Get-PSUnpluggedTaskWorkerHandles { @() }
                Mock Get-CodexThread {
                    @(
                        [pscustomobject]@{
                            ThreadId       = '11111111-1111-7111-8111-111111111111'
                            Name           = 'recent completed'
                            Project        = 'recent'
                            Status         = 'completed'
                            LastActivityAt = $now.AddHours(-1).ToString('o')
                        }
                        [pscustomobject]@{
                            ThreadId       = '22222222-2222-7222-8222-222222222222'
                            Name           = 'old completed'
                            Project        = 'old'
                            Status         = 'completed'
                            LastActivityAt = $now.AddHours(-8).ToString('o')
                        }
                        [pscustomobject]@{
                            ThreadId       = '33333333-3333-7333-8333-333333333333'
                            Name           = 'old failed'
                            Project        = 'attention'
                            Status         = 'failed'
                            LastActivityAt = $now.AddDays(-5).ToString('o')
                        }
                    )
                }

                $defaultTasks = @(Get-CodexTask -LocalOnly -Limit 25)
                $defaultTasks.Name | Should -Contain 'recent completed'
                $defaultTasks.Name | Should -Contain 'old failed'
                $defaultTasks.Name | Should -Not -Contain 'old completed'

                $allTasks = @(Get-CodexTask -LocalOnly -All -Limit 25)
                $allTasks.Name | Should -Contain 'old completed'

                $widerWindowTasks = @(Get-CodexTask -LocalOnly -RecentHours 12 -Limit 25)
                $widerWindowTasks.Name | Should -Contain 'old completed'

                $sinceTasks = @(Get-CodexTask -LocalOnly -Since $now.AddHours(-12) -Limit 25)
                $sinceTasks.Name | Should -Contain 'old completed'
            }
        }
    }

    Context 'Observable task substrate' {
        It 'projects Codex session JSONL into normalized events' {
            $oldCodexHome = $env:CODEX_HOME
            $codexHome = Join-Path (Get-Item -LiteralPath TestDrive:\).FullName 'codex-home-events'
            $sessionRoot = Join-Path $codexHome 'sessions\2026\05\16'
            $threadId = '11111111-1111-7111-8111-111111111111'
            $sessionPath = Join-Path $sessionRoot "rollout-$threadId.jsonl"

            New-Item -ItemType Directory -Path $sessionRoot -Force | Out-Null
            @(
                (@{ type = 'session_meta'; timestamp = '2026-05-16T21:00:00Z'; payload = @{ id = $threadId } } | ConvertTo-Json -Compress -Depth 10)
                (@{ type = 'event_msg'; timestamp = '2026-05-16T21:00:01Z'; payload = @{ type = 'task_started'; turn_id = 'turn-1' } } | ConvertTo-Json -Compress -Depth 10)
                (@{ type = 'response_item'; timestamp = '2026-05-16T21:00:02Z'; payload = @{ type = 'function_call'; call_id = 'call-1'; name = 'shell_command'; arguments = '{"command":"git status --short"}' } } | ConvertTo-Json -Compress -Depth 10)
                (@{ type = 'response_item'; timestamp = '2026-05-16T21:00:03Z'; payload = @{ type = 'function_call_output'; call_id = 'call-1'; output = "Exit code: 0`nWall time: 0.1 seconds" } } | ConvertTo-Json -Compress -Depth 10)
                (@{ type = 'event_msg'; timestamp = '2026-05-16T21:00:04Z'; payload = @{ type = 'task_complete'; last_agent_message = 'Done.' } } | ConvertTo-Json -Compress -Depth 10)
            ) | Set-Content -LiteralPath $sessionPath -Encoding utf8

            try {
                $env:CODEX_HOME = $codexHome

                $events = @(Get-CodexEvent -Id $threadId -LocalOnly -Limit 10)
                $events.Kind | Should -Be @('SessionMeta', 'TaskStarted', 'Command', 'CommandResult', 'TaskCompleted')
                ($events | Where-Object Kind -eq 'Command').Summary | Should -Be 'git status --short'
                ($events | Where-Object Kind -eq 'CommandResult').Summary | Should -Be 'Completed: git status --short (exit 0, 0.1 seconds)'

                $commandRaw = @(Get-CodexEvent -Id $threadId -LocalOnly -Kind Command -IncludeRaw)[0]
                $commandRaw.RawEvent | Should -Not -BeNullOrEmpty
                $commandRaw.PSObject.TypeNames[0] | Should -Be 'PSUnplugged.CodexEvent.Raw'
            }
            finally {
                $env:CODEX_HOME = $oldCodexHome
            }
        }

        It 'validates event kind values' {
            $kindParameter = (Get-Command Get-CodexEvent).Parameters['Kind']
            $validateSet = @($kindParameter.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | Select-Object -First 1)

            $validateSet | Should -Not -BeNullOrEmpty
            $validateSet.ValidValues | Should -Contain 'Command'
            $validateSet.ValidValues | Should -Contain 'ApprovalRequested'
            $validateSet.ValidValues | Should -Contain 'TaskCompleted'
        }

        It 'projects observed approval requests into read-only approval objects' {
            $oldCodexHome = $env:CODEX_HOME
            $codexHome = Join-Path (Get-Item -LiteralPath TestDrive:\).FullName 'codex-home-approvals'
            $sessionRoot = Join-Path $codexHome 'sessions\2026\05\16'
            $threadId = '22222222-2222-7222-8222-222222222222'
            $sessionPath = Join-Path $sessionRoot "rollout-$threadId.jsonl"

            New-Item -ItemType Directory -Path $sessionRoot -Force | Out-Null
            @(
                (@{ type = 'session_meta'; timestamp = '2026-05-16T21:00:00Z'; payload = @{ id = $threadId } } | ConvertTo-Json -Compress -Depth 10)
                (@{ id = 41; method = 'item/commandExecution/requestApproval'; timestamp = '2026-05-16T21:00:02Z'; params = @{ command = 'git status --short'; cwd = 'D:\repo' } } | ConvertTo-Json -Compress -Depth 10)
                (@{ id = 42; method = 'item/fileChange/requestApproval'; timestamp = '2026-05-16T21:00:03Z'; params = @{ path = 'README.md'; reason = 'write file' } } | ConvertTo-Json -Compress -Depth 10)
            ) | Set-Content -LiteralPath $sessionPath -Encoding utf8

            try {
                $env:CODEX_HOME = $codexHome

                $approvals = @(Get-CodexApproval -Id $threadId -LocalOnly -Limit 10)
                $approvals.ApprovalType | Should -Be @('CommandExecution', 'FileChange')
                $approvals.Status | Should -Be @('Requested', 'Requested')
                ($approvals | Where-Object ApprovalType -eq 'CommandExecution').Target | Should -Be 'git status --short'
                ($approvals | Where-Object ApprovalType -eq 'FileChange').Target | Should -Be 'README.md'

                $rawFileApproval = @(Get-CodexApproval -Id $threadId -LocalOnly -ApprovalType FileChange -IncludeRaw)[0]
                $rawFileApproval.RawEvent | Should -Not -BeNullOrEmpty
                $rawFileApproval.PSObject.TypeNames[0] | Should -Be 'PSUnplugged.CodexApproval.Raw'
            }
            finally {
                $env:CODEX_HOME = $oldCodexHome
            }
        }

        It 'projects durable task artifacts from local session state' {
            $oldCodexHome = $env:CODEX_HOME
            $codexHome = Join-Path (Get-Item -LiteralPath TestDrive:\).FullName 'codex-home-artifacts'
            $sessionRoot = Join-Path $codexHome 'sessions\2026\05\16'
            $threadId = '33333333-3333-7333-8333-333333333333'
            $sessionPath = Join-Path $sessionRoot "rollout-$threadId.jsonl"

            New-Item -ItemType Directory -Path $sessionRoot -Force | Out-Null
            @(
                (@{ type = 'session_meta'; timestamp = '2026-05-16T21:00:00Z'; payload = @{ id = $threadId } } | ConvertTo-Json -Compress -Depth 10)
                (@{ type = 'event_msg'; timestamp = '2026-05-16T21:00:01Z'; payload = @{ type = 'user_message'; message = 'Summarize the repo.' } } | ConvertTo-Json -Compress -Depth 10)
                (@{ type = 'event_msg'; timestamp = '2026-05-16T21:00:02Z'; payload = @{ type = 'agent_message'; phase = 'active'; message = 'Reading files.' } } | ConvertTo-Json -Compress -Depth 10)
                (@{ type = 'event_msg'; timestamp = '2026-05-16T21:00:03Z'; payload = @{ type = 'task_complete'; last_agent_message = 'Wrote artifact summary.' } } | ConvertTo-Json -Compress -Depth 10)
            ) | Set-Content -LiteralPath $sessionPath -Encoding utf8

            try {
                $env:CODEX_HOME = $codexHome

                $artifacts = @(Get-CodexArtifact -Id $threadId -LocalOnly -IncludeContent -Limit 10)
                $artifacts.Kind | Should -Contain 'SessionFile'
                $artifacts.Kind | Should -Contain 'ResultText'
                $artifacts.Kind | Should -Contain 'Transcript'
                $artifacts.Kind | Should -Contain 'EventLog'

                $sessionArtifact = @($artifacts | Where-Object Kind -eq 'SessionFile')[0]
                $sessionArtifact.Path | Should -Be $sessionPath
                $sessionArtifact.Content | Should -Match 'task_complete'
                $sessionArtifact.PSObject.TypeNames[0] | Should -Be 'PSUnplugged.CodexArtifact.Content'
                $sessionArtifact.PSObject.TypeNames | Should -Contain 'PSUnplugged.CodexArtifact'

                $resultArtifact = @(Get-CodexArtifact -Id $threadId -LocalOnly -Kind ResultText -IncludeContent)[0]
                $resultArtifact.Kind | Should -Be 'ResultText'
                $resultArtifact.Content | Should -Be 'Wrote artifact summary.'

                $eventArtifact = @($artifacts | Where-Object Kind -eq 'EventLog')[0]
                $eventArtifact.ItemCount | Should -Be 4
                $eventArtifact.Content | Should -Match 'TaskCompleted'
            }
            finally {
                $env:CODEX_HOME = $oldCodexHome
            }
        }

        It 'validates artifact kind values' {
            $kindParameter = (Get-Command Get-CodexArtifact).Parameters['Kind']
            $validateSet = @($kindParameter.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | Select-Object -First 1)

            $validateSet | Should -Not -BeNullOrEmpty
            $validateSet.ValidValues | Should -Contain 'SessionFile'
            $validateSet.ValidValues | Should -Contain 'ResultText'
            $validateSet.ValidValues | Should -Contain 'Transcript'
            $validateSet.ValidValues | Should -Contain 'EventLog'
        }

        It 'builds a local task dashboard over existing task projections' {
            $oldCodexHome = $env:CODEX_HOME
            $codexHome = Join-Path (Get-Item -LiteralPath TestDrive:\).FullName 'codex-home-dashboard'
            $sessionRoot = Join-Path $codexHome 'sessions\2026\05\16'
            $threadId = '44444444-4444-7444-8444-444444444444'
            $sessionPath = Join-Path $sessionRoot "rollout-$threadId.jsonl"
            $dashboardPath = Join-Path (Get-Item -LiteralPath TestDrive:\).FullName 'dashboard.html'

            New-Item -ItemType Directory -Path $sessionRoot -Force | Out-Null
            @(
                (@{ type = 'session_meta'; timestamp = '2026-05-16T21:00:00Z'; payload = @{ id = $threadId } } | ConvertTo-Json -Compress -Depth 10)
                (@{ type = 'event_msg'; timestamp = '2026-05-16T21:00:01Z'; payload = @{ type = 'user_message'; message = 'Build a dashboard.' } } | ConvertTo-Json -Compress -Depth 10)
                (@{ type = 'event_msg'; timestamp = '2026-05-16T21:00:02Z'; payload = @{ type = 'agent_message'; phase = 'active'; message = 'Collecting task state.' } } | ConvertTo-Json -Compress -Depth 10)
                (@{ type = 'event_msg'; timestamp = '2026-05-16T21:00:03Z'; payload = @{ type = 'task_complete'; last_agent_message = 'Dashboard snapshot ready.' } } | ConvertTo-Json -Compress -Depth 10)
            ) | Set-Content -LiteralPath $sessionPath -Encoding utf8

            try {
                $env:CODEX_HOME = $codexHome
                $task = [pscustomobject]@{
                    TaskId  = $threadId
                    ThreadId = $threadId
                    Name    = 'dashboard-test'
                    Project = 'tryStuff'
                    Status  = 'completed'
                }

                $data = $task | ConvertTo-CodexTaskDashboardData -LocalOnly -Title 'Task Monitor'
                $data.PSObject.TypeNames[0] | Should -Be 'PSUnplugged.CodexTaskDashboardData'
                $data.taskCount | Should -Be 1
                $data.tasks[0].latest.text | Should -Be 'Dashboard snapshot ready.'
                ($data | ConvertTo-Json -Depth 20) | Should -Match 'dashboard-test'

                $page = $task | Show-CodexTaskDashboard -LocalOnly -NoOpen -PassThru -OutputPath $dashboardPath -Title 'Task Monitor'

                $page.Path | Should -Be $dashboardPath
                $page.TaskCount | Should -Be 1
                $page.Opened | Should -BeFalse
                $page.PSObject.TypeNames[0] | Should -Be 'PSUnplugged.CodexTaskDashboardPage'

                $html = Get-Content -LiteralPath $dashboardPath -Raw
                $html | Should -Match 'dashboard-data'
                $html | Should -Match 'nlpBox'
                $html | Should -Match 'data-theme="light"'
                $html | Should -Match 'themeBtn'
                $html | Should -Match 'Dashboard snapshot ready.'

                $dataDashboardPath = Join-Path (Get-Item -LiteralPath TestDrive:\).FullName 'dashboard-from-data.html'
                $dataPage = $data | Show-CodexTaskDashboard -NoOpen -PassThru -OutputPath $dataDashboardPath
                $dataPage.Path | Should -Be $dataDashboardPath
                $dataPage.TaskCount | Should -Be 1

                $dataHtml = Get-Content -LiteralPath $dataDashboardPath -Raw
                $dataHtml | Should -Match 'Task Monitor'
                $dataHtml | Should -Match 'data-theme="light"'
                $dataHtml | Should -Match 'Dashboard snapshot ready.'
            }
            finally {
                $env:CODEX_HOME = $oldCodexHome
            }
        }

        It 'renders an empty local task dashboard when no tasks match' {
            $oldCodexHome = $env:CODEX_HOME
            $oldPSUnpluggedHome = $env:PSUNPLUGGED_HOME
            $codexHome = Join-Path (Get-Item -LiteralPath TestDrive:\).FullName 'codex-home-empty-dashboard'
            $psUnpluggedHome = Join-Path (Get-Item -LiteralPath TestDrive:\).FullName 'psunplugged-home-empty-dashboard'
            $dashboardPath = Join-Path (Get-Item -LiteralPath TestDrive:\).FullName 'empty-dashboard.html'

            New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
            New-Item -ItemType Directory -Path $psUnpluggedHome -Force | Out-Null

            try {
                $env:CODEX_HOME = $codexHome
                $env:PSUNPLUGGED_HOME = $psUnpluggedHome

                $page = Show-CodexTaskDashboard -Project '*' -LocalOnly -NoOpen -PassThru -OutputPath $dashboardPath -Title 'Empty Task Monitor' -ErrorAction Stop

                $page.Path | Should -Be $dashboardPath
                $page.TaskCount | Should -Be 0
                $page.Opened | Should -BeFalse

                $html = Get-Content -LiteralPath $dashboardPath -Raw
                $html | Should -Match 'Empty Task Monitor'
                $html | Should -Match 'No tasks match the current filters.'
                $html | Should -Match 'data-theme="light"'
            }
            finally {
                $env:CODEX_HOME = $oldCodexHome
                $env:PSUNPLUGGED_HOME = $oldPSUnpluggedHome
            }
        }
    }

    Context 'Project location resolution' {
        It 'resolves client cwd paths from the PowerShell location' {
            $testRoot = (Get-Item -LiteralPath TestDrive:\).FullName
            $expectedPath = Join-Path $testRoot 'periodicTable'
            $originalCurrentDirectory = [Environment]::CurrentDirectory

            Push-Location -LiteralPath $testRoot
            try {
                [Environment]::CurrentDirectory = [Environment]::SystemDirectory

                InModuleScope -ModuleName $script:ModuleUnderTestName -Parameters @{ ExpectedPath = $expectedPath } {
                    param([string]$ExpectedPath)

                    Resolve-CodexClientPath -Path '.\periodicTable' |
                        Should -Be $ExpectedPath
                }
            }
            finally {
                [Environment]::CurrentDirectory = $originalCurrentDirectory
                Pop-Location
            }
        }

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
