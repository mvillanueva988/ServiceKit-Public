# Testing Patterns

**Analysis Date:** 2026-03-10

## Test Framework

**Runner:** None — no testing framework is installed or configured.

**Pester:** Not present. No `*.Tests.ps1`, `*.test.ps1`, or `*.spec.ps1` files exist anywhere in the workspace.

**Test configuration:** No `pester.config.ps1`, `pester.json`, or equivalent config files exist.

**Run Commands:** No test commands defined. `package.json`, `Makefile`, and equivalent build-runner files do not exist.

## Current Test Coverage

**Automated tests: 0%**

The codebase has no automated test suite of any kind. All 15 `.ps1` files are production code with no accompanying test files. There are no mocks, no fixtures, no assertions, and no test helpers.

## Verification Approach (Current)

Testing is entirely manual. The workflow is:

1. Run `main.ps1` as Administrator
2. Navigate to the relevant menu option
3. Observe console output and system state changes
4. The `output/` directory holds pre/post snapshot JSON files (`Telemetry.ps1`) that serve as a form of manual before/after comparison

No CI pipeline exists (confirmed in INTEGRATIONS.md). No automated regression safety net.

## Code Structure Implications for Testing

The codebase **is designed to be testable in isolation** even without tests written yet. The architecture separates concerns clearly:

**Pure logic functions** (synchronous, return structured objects — ideal unit test targets):
- `modules/Network.ps1` → `Optimize-Network`, `Get-NetworkDiagnostics`
- `modules/Cleanup.ps1` → `Clear-TempFiles`, `Get-CleanupPreview`, `_Get-CleanupPaths`
- `modules/Debloat.ps1` → `Disable-BloatServices`
- `modules/Performance.ps1` → `Set-BalancedVisuals`, `Set-FullOptimizedVisuals`, `Restore-DefaultVisuals`
- `modules/Privacy.ps1` → `Invoke-PrivacyTweaks`
- `modules/RestorePoint.ps1` → `New-RestorePoint`
- `modules/Maintenance.ps1` → `Repair-WindowsSystem`
- `modules/Apps.ps1` → `Get-InstalledWin32Apps`, `Get-InstalledUwpApps`
- `modules/Diagnostics.ps1` → `Get-BsodHistory`
- `modules/StartupManager.ps1` → `Get-StartupEntries`
- `modules/Telemetry.ps1` → `Get-SystemSnapshot`
- `core/JobManager.ps1` → `Invoke-AsyncToolkitJob`, `Wait-ToolkitJobs`

**Async launchers** (job wrappers — require integration testing with mocked jobs):
- All `Start-*Process` / `Start-*Job` functions in every module

**UI layer** (console-only, not unit testable without capturing Write-Host):
- `main.ps1` — monolithic menu loop, mixes UI and orchestration

## Recommended Test Framework

**Pester 5.x** is the standard PowerShell testing framework. Install:

```powershell
Install-Module -Name Pester -Force -SkipPublisherCheck
```

Run tests (once created):

```powershell
Invoke-Pester -Path tests/ -Output Detailed
Invoke-Pester -Path tests/ -CodeCoverage modules/*.ps1
```

## Recommended Test File Organization

**Convention to adopt:** Co-located test directory at project root:

```
Toolkit/
├── tests/
│   ├── unit/
│   │   ├── Network.Tests.ps1
│   │   ├── Cleanup.Tests.ps1
│   │   ├── Debloat.Tests.ps1
│   │   ├── Performance.Tests.ps1
│   │   ├── Privacy.Tests.ps1
│   │   ├── Apps.Tests.ps1
│   │   ├── Diagnostics.Tests.ps1
│   │   ├── StartupManager.Tests.ps1
│   │   └── JobManager.Tests.ps1
│   └── integration/
│       └── AsyncJobs.Tests.ps1
```

## Recommended Test Structure (Pester 5)

All module functions dot-source their parent file, then exercise the function directly:

```powershell
#Requires -Modules Pester

BeforeAll {
    . "$PSScriptRoot\..\..\modules\Network.ps1"
}

Describe 'Get-NetworkDiagnostics' {

    Context 'When network adapters are available' {
        It 'returns a PSCustomObject with expected shape' {
            $result = Get-NetworkDiagnostics
            $result                | Should -BeOfType [PSCustomObject]
            $result.TcpAutoTuning  | Should -Not -BeNullOrEmpty
            $result.Adapters       | Should -BeOfType [object[]]
            $result.PingMs         | Should -BeOfType [int]
        }
    }
}

Describe 'Optimize-Network' {

    Context 'When no active adapters are found' {
        It 'returns Success = $false and empty AdaptersOptimized' {
            $result = Optimize-Network -AdapterNames @('NonExistentAdapter99')
            $result.Success           | Should -Be $false
            $result.AdaptersOptimized.Count | Should -Be 0
        }
    }
}
```

## Recommended Mocking Strategy

**Registry operations** — mock `Set-ItemProperty` and `Get-ItemProperty` to avoid writing to real registry:

```powershell
Describe 'Invoke-PrivacyTweaks' {
    BeforeAll {
        . "$PSScriptRoot\..\..\modules\Privacy.ps1"
    }

    Context 'Basic profile' {
        BeforeEach {
            Mock Set-ItemProperty { return $null }
            Mock New-Item         { return $null }
            Mock Get-ItemProperty { return $null }
            Mock Test-Path        { return $true }
        }

        It 'returns Applied list with Basic entries' {
            $result = Invoke-PrivacyTweaks -Profile 'Basic'
            $result.Profile  | Should -Be 'Basic'
            $result.Applied  | Should -Not -BeNullOrEmpty
            $result.Errors   | Should -BeNullOrEmpty
        }
    }
}
```

**Service operations** — mock `Get-Service`, `Stop-Service`, `Set-Service`:

```powershell
Describe 'Disable-BloatServices' {
    BeforeAll {
        . "$PSScriptRoot\..\..\modules\Debloat.ps1"
    }

    BeforeEach {
        Mock Get-Service  { [PSCustomObject]@{ Status = 'Running'; Name = $Name } }
        Mock Stop-Service { }
        Mock Set-Service  { }
    }

    It 'returns Disabled count equal to input list count' {
        $result = Disable-BloatServices -ServicesList @('Fax', 'RemoteRegistry')
        $result.Disabled | Should -Be 2
        $result.Failed   | Should -Be 0
    }
}
```

**CIM queries** — mock `Get-CimInstance` to return controlled PSCustomObject stubs:

```powershell
Mock Get-CimInstance {
    if ($ClassName -eq 'Win32_Processor') {
        return [PSCustomObject]@{
            Name = 'Intel Core i7-12700H'; NumberOfCores = 14; NumberOfLogicalProcessors = 20
        }
    }
}
```

**Async job testing** — mock `Invoke-AsyncToolkitJob` and `Wait-ToolkitJobs` to avoid real background jobs:

```powershell
Mock Invoke-AsyncToolkitJob { return [PSCustomObject]@{ Id = 1; State = 'Completed' } }
```

## What to Mock

- `Get-CimInstance` / `Get-WmiObject` — always mock in unit tests
- `Get-Service`, `Stop-Service`, `Set-Service` — always mock
- `Set-ItemProperty`, `Get-ItemProperty`, `New-Item`, `Test-Path` — mock for registry tests
- `Get-NetAdapter`, `Get-DnsClientServerAddress`, `Test-Connection` — mock for network tests
- `netsh`, `ipconfig`, `DISM`, `sfc` — mock via `Mock` on the process invocation or skip in unit tests

## What NOT to Mock

- `[System.Collections.Generic.List[T]]` — real .NET collection, no mock needed
- `[PSCustomObject]@{...}` construction — test directly
- String manipulation, math operations — test real code paths

## Coverage Targets

**Requirements:** None currently enforced.

**Recommended minimums once Pester is adopted:**
- Pure logic functions (`Get-*`, `Invoke-*`): 80%+ branch coverage
- Async launchers (`Start-*`): smoke test only (verify job is returned)
- `main.ps1` UI loop: excluded from coverage measurement

## Test Types

**Unit Tests** (recommended priority):
- Scope: Individual public functions in `modules/` and `core/`
- Isolation: Mock all external calls (CIM, Registry, Services, Network)
- Location: `tests/unit/<ModuleName>.Tests.ps1`

**Integration Tests** (secondary):
- Scope: `Invoke-AsyncToolkitJob` + `Wait-ToolkitJobs` round-trip with real `Start-Job`
- Requires: No elevated privileges for most scenarios
- Location: `tests/integration/AsyncJobs.Tests.ps1`

**E2E / Manual Tests:**
- `main.ps1` full flow — manual only, requires Administrator, real Windows system
- Snapshot compare flow (Pre → Post via `Telemetry.ps1`) — manual validation

## Common Test Patterns to Establish

**Testing structured return objects:**
```powershell
It 'result has Success property' {
    $result = New-RestorePoint
    $result.PSObject.Properties.Name | Should -Contain 'Success'
    $result.PSObject.Properties.Name | Should -Contain 'Message'
}
```

**Testing error accumulation:**
```powershell
It 'accumulates errors without throwing' {
    Mock Set-Service { throw 'Access denied' }
    { Disable-BloatServices -ServicesList @('Fax') } | Should -Not -Throw
    $result = Disable-BloatServices -ServicesList @('Fax')
    $result.Failed | Should -BeGreaterThan 0
}
```

**Testing empty-safe returns:**
```powershell
It 'returns empty array not null when no adapters' {
    Mock Get-NetAdapter { return @() }
    $result = Optimize-Network
    $result.Success           | Should -Be $false
    $result.AdaptersOptimized | Should -Not -BeNullOrEmpty -Because 'should be empty array not null'
    $result.AdaptersOptimized.Count | Should -Be 0
}
```

---

_Testing analysis: 2026-03-10_
