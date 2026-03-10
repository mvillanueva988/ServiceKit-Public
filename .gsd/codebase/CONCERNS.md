# Codebase Concerns

**Analysis Date:** 2026-03-10

---

## Tech Debt

**`main.ps1` God File (~1250 lines):**
- Issue: All 15 menu handlers, UI rendering, and user-input parsing live in a single file with no separation of concerns.
- Files: `main.ps1`
- Impact: Every feature change risks breaking unrelated menu branches. Impossible to unit-test individual handlers. Merge conflicts guaranteed in any parallel work.
- Fix approach: Extract each menu `case` into a `Show-<Feature>Menu` function in its own file under `modules/`, keeping `main.ps1` as a pure router.

**Function Serialization Anti-Pattern (all async jobs):**
- Issue: Every module copies its own function body as a string literal into a new `[scriptblock]::Create(...)` to pass to `Start-Job`. Pattern is copy-pasted across `Debloat.ps1`, `Network.ps1`, `Maintenance.ps1`, `Privacy.ps1`, `RestorePoint.ps1`, `Telemetry.ps1`, `Diagnostics.ps1`.
- Files: all modules with `Start-*Process` / `Start-*Job` functions
- Impact: If a function calls a private helper (e.g., `_Invoke-UninstallCommand` in `Apps.ps1`), that helper is silently absent in the job runspace and will throw `CommandNotFoundException` at runtime. Changes to a function require updating both the function and every serialization site.
- Fix approach: Use a `-InitializationScript` scriptblock that dot-sources the module file inside the job, or use `[System.Management.Automation.Runspaces.RunspacePool]` with proper module loading.

**`Launch.ps1` Uses Deprecated `WebClient`:**
- Issue: `[System.Net.WebClient]::new()` is used for the ZIP download. `WebClient` is deprecated in .NET 6+.
- Files: `Launch.ps1` line 42
- Impact: No timeout control on the download stream. `WebClient` does not honor system proxy settings consistently. Will generate deprecation warnings on .NET 7+ runtimes.
- Fix approach: Replace with `Invoke-WebRequest -OutFile` or `[System.Net.Http.HttpClient]`.

**`Launch.ps1` Repo Placeholder Never Configured:**
- Issue: `[string] $GitHubRepo = 'TU_USUARIO/TU_REPO'` is a hardcoded placeholder.
- Files: `Launch.ps1` line 4
- Impact: Any user running `Launch.ps1` unmodified will hit a GitHub API 404 and fall through to the "no local version" error path. The auto-update feature is completely non-functional out of the box.
- Fix approach: Read repo from a config file, an environment variable, or add a pre-flight check that aborts with a clear setup message when the placeholder value is detected.

**`Sophia` Tool URL Hard-Coded to Windows 11:**
- Issue: `tools/manifest.json` entry for `sophia` points to `Sophia.Script.for.Windows.11.zip` with a comment saying "replace with Windows.10.And.11 for W10". The download script does not check OS version.
- Files: `tools/manifest.json` line ~175
- Impact: On a Windows 10 machine, `Bootstrap-Tools.ps1` silently downloads the wrong Sophia Script variant.
- Fix approach: Either detect OS version in `Bootstrap-Tools.ps1` and select the correct URL, or replace with the universal `Windows.10.And.11` URL.

---

## Security Considerations

**All SHA-256 Hashes in Manifest Are Empty:**
- Risk: Every tool in `tools/manifest.json` has `"sha256": ""`. The verification logic in `Bootstrap-Tools.ps1` (lines ~165–175) is dead — it only runs when the hash is non-empty. Downloaded executables (Autoruns, ProcessMonitor, OOSU10, DDU, BCUninstaller, etc.) are run without any integrity check.
- Files: `tools/manifest.json`, `Bootstrap-Tools.ps1`
- Current mitigation: None. The code structure for verification exists but is never exercised.
- Recommendations: Populate SHA-256 hashes for all versioned/pinned downloads. For Sysinternals "live" downloads (no fixed version), document the risk explicitly and consider pinning to a known release rather than `live.sysinternals.com`.

**`Launch.ps1` Extracts Downloaded ZIP Without Hash Verification:**
- Risk: The self-update flow downloads a ZIP from GitHub Releases and extracts it over `$InstallPath` (`C:\PCTk`) with `Remove-Item $InstallPath -Recurse -Force` then `Expand-Archive`. No integrity check on the ZIP before extraction.
- Files: `Launch.ps1` lines 60–70
- Current mitigation: Uses HTTPS for the GitHub API call and asset download URL.
- Recommendations: Verify asset hash against a known checksum published in the release metadata before extraction. At minimum, verify the downloaded file size is within an expected range.

**`_Invoke-UninstallCommand` Executes Registry Uninstall Strings Directly:**
- Risk: The function parses `UninstallString` from the registry and passes it to `Start-Process` with extracted arguments. Maliciously crafted registry entries (possible after malware infection) could cause arbitrary command execution.
- Files: `modules/Apps.ps1` lines ~180–215
- Current mitigation: Only runs on explicit user confirmation per app. Registry values come from `HKLM:\SOFTWARE` requiring admin write access to tamper.
- Recommendations: Add a `Test-Path` check on the resolved executable before launching. Display the full parsed command to the user in the confirmation prompt so they can verify it.

**`Release.ps1` Reads GitHub Token from Environment Variable:**
- Risk: `$env:GITHUB_TOKEN` is used directly in an `Authorization: token ...` header. On shared machines or CI environments that log environment variables, this can lead to token exposure.
- Files: `Release.ps1` lines ~85–90
- Current mitigation: Token is not logged or printed; it's only used in the header. Risk is CI/CD log exposure.
- Recommendations: Acceptable pattern for local developer use. Ensure CI pipeline masks the token in logs.

---

## Known Bugs

**`Wait-ToolkitJobs` Silently Drops Job Errors:**
- Symptoms: If a `Start-Job` scriptblock throws an unhandled exception, the job transitions to `Failed` state. `Receive-Job -AutoRemoveJob -Wait` on a failed job returns no output (not the exception). The caller in `main.ps1` then accesses properties on `$null` (e.g., `$result.Disabled`) and gets no error, just empty output.
- Files: `core/JobManager.ps1` lines 55–65, all callers in `main.ps1`
- Trigger: Any unhandled exception inside an async job (e.g., missing cmdlet in job runspace, access denied).
- Workaround: None visible to the end user — operation silently appears to succeed with zero results.

**`Get-InstalledWin32Apps` and `Get-InstalledUwpApps` Block the Main UI Thread:**
- Symptoms: Menu options 12 (Apps Win32) and 12→2 (UWP) call these functions synchronously inside the main menu loop. On systems with 200+ installed apps, the screen freezes for 2–5 seconds with no spinner or feedback.
- Files: `main.ps1` lines ~610–620 and ~730–740; `modules/Apps.ps1`
- Trigger: Any use of the Apps menu on a system with many installed apps or slow disk.
- Workaround: None currently. The pattern is inconsistent — all other heavy operations use `Start-Job`.

**`Spooler` in Bloat Catalog Without Printer Warning:**
- Symptoms: `Spooler` (Print Spooler) appears in the bloat catalog with `Risk = 'Medio'`. Disabling it permanently breaks all local and network printing. There is no warning in the UI that this service is required for printing.
- Files: `main.ps1` lines ~133–144, `modules/Debloat.ps1` lines ~18–30
- Trigger: User selects Spooler for disabling.
- Workaround: Re-enable via `Set-Service Spooler -StartupType Automatic; Start-Service Spooler`.

**`Repair-WindowsSystem` Silences All DISM/SFC Output:**
- Symptoms: `DISM /Online /Cleanup-Image /RestoreHealth *> $null` and `sfc /scannow *> $null` discard ALL output including actionable error messages. Exit code interpretation is too coarse — DISM exit code 87 (invalid parameter) is reported the same as a real repair failure.
- Files: `modules/Maintenance.ps1` lines 14–17
- Trigger: DISM or SFC fails with a non-standard error (e.g., network unavailable for WU source).
- Workaround: User is referred to `C:\Windows\Logs\CBS\CBS.log` but not in a way they can act on programmatically.

**`Checkpoint-Computer` 24-Hour Cooldown Not Detected:**
- Symptoms: Windows enforces a 24-hour minimum between restore points. When the cooldown is active, `Checkpoint-Computer` throws an exception that `New-RestorePoint` catches and returns as `Success = $false`. This looks identical to a permissions failure in the UI output.
- Files: `modules/RestorePoint.ps1` lines 9–20
- Trigger: Running restore point creation twice within 24 hours.
- Workaround: Check existing restore points via `Get-ComputerRestorePoint` before attempting creation and display a helpful message.

---

## Performance Bottlenecks

**CIM Queries on Every Menu Redraw:**
- Problem: `Show-MainMenu` queries `Win32_ComputerSystem` and `Win32_VideoController` via CIM on every iteration of the main `:mainLoop`. Clearing the screen and typing a number immediately triggers new WMI calls.
- Files: `main.ps1` lines ~40–60
- Cause: Hardware info is displayed in the menu header, and the entire header is redrawn each loop iteration with no caching.
- Improvement path: Cache the hardware info in `$script:` scope variables on first load. Only refresh if explicitly requested (e.g., by the user pressing a dedicated key).

**`Get-CleanupPreview` Scans All User Profile Temp Dirs Synchronously:**
- Problem: Before showing the cleanup preview, the function enumerates all user profiles via CIM and scans browser cache directories for each profile. On machines with multiple users and heavy browser usage, this can take 5–15 seconds in the foreground.
- Files: `modules/Cleanup.ps1` (the `_Get-CleanupPaths` function)
- Cause: Called directly in main.ps1 before displaying any output, with only a "Escaneando..." message and no progress display.
- Improvement path: Move the preview scan into an async job like all other heavy operations, showing the spinner during the scan.

---

## Fragile Areas

**Module Loading via Blind Dot-Sourcing:**
- Files: `main.ps1` lines 5–11
- Why fragile: All scripts in `core/`, `utils/`, and `modules/` are dot-sourced in a `foreach` loop. Load order is filesystem-determined (alphabetical by `Get-ChildItem`). If any module requires another module's functions to be available at dot-source time (not just at call time), load order dependency bugs will appear intermittently.
- Safe modification: Keep all module-level code side-effect free at load time. Only define functions and declare `$script:` variables. Do not call functions from other modules at the top-level of a module file.
- Test coverage: None — no test for load order correctness.

**`_Get-CleanupPaths` Private Function Naming Convention:**
- Files: `modules/Cleanup.ps1`
- Why fragile: The function is named with a leading underscore (`_Get-CleanupPaths`) to signal "private," but PowerShell has no visibility modifiers. With `Set-StrictMode -Version Latest`, the function is globally available in the session after dot-sourcing. Any future module could accidentally depend on it or override it.
- Safe modification: Acceptable risk for current scope, but worth noting if module count grows.

**Job Serialization Breaks on Multi-Function Modules:**
- Files: `modules/Debloat.ps1` `Start-DebloatProcess`, `modules/Privacy.ps1` `Start-PrivacyJob`
- Why fragile: The serialization pattern only copies one function body into the job scriptblock. If `Disable-BloatServices` or `Invoke-PrivacyTweaks` are ever refactored to call a shared helper, the job will fail with `CommandNotFoundException` at runtime — not at authoring time. There is no test that the job actually runs successfully end-to-end.
- Test coverage: None.

**Windows Update Info Reads From Two Different Registry Paths:**
- Files: `main.ps1` lines ~995–1040
- Why fragile: The code tries a "modern" registry path first (`WindowsUpdate\UX\Settings`) then falls back to a legacy path. The fallback is necessary for LTSC and pre-1903 builds, but `$lastInstall` / `$lastCheck` remain `'Desconocida'` silently if neither path has data. No diagnostic is shown to explain why dates are unknown.
- Safe modification: Add a check for `$isLtsc` (already computed at menu level) to branch directly to the correct path rather than trying both.

---

## Missing Critical Features

**No Admin Elevation Check at Startup:**
- Problem: Many operations (disabling services, registry writes to HKLM, DISM/SFC, network adapter registry, restore points) require elevation. There is no check for admin rights at startup or before each operation.
- Blocks: Silent failures when run without elevation — the user sees vague error messages instead of "re-run as Administrator."
- Recommended fix: Add at the top of `main.ps1`:
  ```powershell
  if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
      Write-Host '  [!] Requiere privilegios de Administrador. Ejecuta como Admin.' -ForegroundColor Red
      exit 1
  }
  ```

**No Audit Log for Applied Changes:**
- Problem: There is no persistent log of what the toolkit changed: which services were disabled, which registry keys were modified, which apps were uninstalled. If something breaks after a session, there is no trail to follow.
- Blocks: Troubleshooting and reversibility — user cannot know what was changed without manually checking.
- Note: The `output/` directory exists and driver backup writes to it, but no general change log is written there.

---

## Test Coverage Gaps

**Zero Test Files in Entire Codebase:**
- What's not tested: All module functions, all job serialization patterns, all UI menu flows, all error handling paths.
- Files: All `.ps1` files in `modules/`, `core/`, `utils/`
- Risk: Regressions in any module function go undetected until a user encounters them. The job serialization pattern is particularly risky — a function refactor can silently break async execution.
- Priority: High for `core/JobManager.ps1` and job-serialization helpers in each module.

**No Integration Test for the Async Job Pipeline:**
- What's not tested: That a serialized function actually executes correctly inside `Start-Job` and that `Wait-ToolkitJobs` returns the expected result shape.
- Files: `core/JobManager.ps1`, all `Start-*Process` and `Start-*Job` functions
- Risk: The most commonly used code path (async operations) has zero coverage.
- Priority: High.

---

*Concerns audit: 2026-03-10*
