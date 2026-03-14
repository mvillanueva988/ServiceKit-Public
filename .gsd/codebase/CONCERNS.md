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

**`Launch.ps1` Still Requires Manual Repo Configuration:**
- Issue: `[string] $GitHubRepo = 'TU_USUARIO/TU_REPO'` remains a placeholder until the maintainer sets the real `usuario/repo`.
- Files: `Launch.ps1` line 5
- Impact: Distribution is intentionally blocked until the repo is configured. The pre-flight check now fails fast with a clear message, but end-to-end deployment cannot proceed yet.
- Fix approach: Set the real GitHub repository before Phase 9 and, if desired later, move this value to a config file or release-time substitution.

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
- Current mitigation: Only runs on explicit user confirmation per app. The UI now shows the parsed command before execution and validates that the target executable exists. Registry values come from `HKLM:\SOFTWARE` requiring admin write access to tamper.
- Recommendations: Current mitigation is acceptable for local technical use. If this ever becomes unattended or remotely orchestrated, add an allowlist for trusted uninstall executables.

**`Release.ps1` Reads GitHub Token from Environment Variable:**
- Risk: `$env:GITHUB_TOKEN` is used directly in an `Authorization: token ...` header. On shared machines or CI environments that log environment variables, this can lead to token exposure.
- Files: `Release.ps1` lines ~85–90
- Current mitigation: Token is not logged or printed; it's only used in the header. Risk is CI/CD log exposure.
- Recommendations: Acceptable pattern for local developer use. Ensure CI pipeline masks the token in logs.

---

## Known Bugs

No high-confidence runtime bugs remain listed after Phase 8. The main residual concerns are architectural and security-related rather than confirmed user-facing defects.

---

## Performance Bottlenecks

No major UI-thread bottlenecks remain documented after the async work completed in Phase 8. Remaining performance risk is concentrated in the serialization-heavy async architecture itself, not in a specific menu action.

---

## Fragile Areas

**Module Loading via Blind Dot-Sourcing:**
- Files: `main.ps1` lines 5–11
- Why fragile: All scripts in `core/`, `utils/`, and `modules/` are dot-sourced in a `foreach` loop. The load order is now deterministic (`Sort-Object Name`), but top-level dependencies between modules would still be brittle.
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

---

## Missing Critical Features

No missing critical features remain before Phase 9 deployment. The main pending work is release/distribution setup rather than core runtime capability.

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
