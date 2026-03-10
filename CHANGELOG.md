# Changelog

All notable changes to GSD for GitHub Copilot will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [1.2.1] - 2025-02-04

### Changed

- Removed hardcoded `model: "Claude Sonnet 4"` from all agent configuration files (model selection now uses default/user preference)
- Removed hardcoded `model: "Claude Sonnet 4"` from all prompt configuration files
- Updated 11 agent files in `.github/agents/` to remove model declaration
- Updated 23 prompt files in `.github/prompts/` to remove model declaration

### Files Modified

- `.github/agents/` (11 files): gsd-codebase-mapper, gsd-debugger, gsd-executor, gsd-integration-checker, gsd-phase-researcher, gsd-plan-checker, gsd-planner, gsd-project-researcher, gsd-research-synthesizer, gsd-roadmapper, gsd-verifier
- `.github/prompts/` (23 files): add-phase, add-todo, audit-milestone, check-todos, complete-milestone, debug, discuss-phase, execute-phase, insert-phase, list-phase-assumptions, map-codebase, new-milestone, new-project, pause-work, plan-milestone-gaps, plan-phase, progress, quick, remove-phase, research-phase, resume-work, set-profile, settings, update, verify-work

## [1.2.0] - 2025-02-04

### Changed

- Updated web search priority order:
  1. Context7 MCP (library/framework documentation)
  2. Copilot `fetch` (built-in web search, no MCP needed)
  3. Exa / Brave Search MCP (optional, for deep research)
- Updated README MCP Server Support section with priority table
- Updated discovery-phase skill source_hierarchy with new priority
- Updated gsd-project-researcher agent tool_strategy with new priority
- Updated gsd-phase-researcher agent tool_strategy with new priority

### Documentation

- Added priority order table to README MCP section
- Clarified that Copilot's `fetch` is built-in and requires no MCP setup
- Exa/Brave Search MCP now marked as optional for users who install them

## [1.1.0] - 2025-02-04

### Added

- HumanAgent MCP integration for user interaction during agent workflows
- HumanAgent MCP tool: `HumanAgent_Chat` (forces Copilot to chat with user before acting)
- HumanAgent MCP added to MCP Server Support table in README
- Human category added to Tool Groups by Platform table

### Changed

- Updated tool mapping: `AskUserQuestion`/`ask_followup_question` → HumanAgent MCP (`HumanAgent_Chat`)
- Previously marked as "N/A (use chat)" now properly mapped to MCP tool
- Converted all `AskUserQuestion` references to `HumanAgent MCP (HumanAgent_Chat)` in 15 files:
  - 1 instruction: questioning.instructions.md
  - 9 prompts: add-todo, check-todos, debug, new-milestone, new-project, quick, settings, update, verify-work
  - 5 skills: complete-milestone, discovery-phase, discuss-phase, execute-plan, verify-work

### Documentation

- Added HumanAgent MCP to all tool reference tables in README
- Documented `HumanAgent_Chat` tool for mid-workflow user interaction
- Link: https://github.com/3DTek-xyz/HumanAgent-MCP

## [1.0.0] - 2025-02-04

### Added

- Initial GitHub Copilot port of [get-stuff-done-for-kilocode](https://github.com/punal100/get-stuff-done-for-kilocode) by [punal100](https://github.com/punal100)
- 27 Prompt Files with Copilot-compatible YAML frontmatter (`.github/prompts/*.prompt.md`)
  - Discovery, planning, execution, verification, and utility prompts
- 11 Custom Agents for specialized GSD behaviors (`.github/agents/*.agent.md`)
  - gsd-codebase-mapper, gsd-debugger, gsd-executor, gsd-integration-checker
  - gsd-phase-researcher, gsd-plan-checker, gsd-planner, gsd-project-researcher
  - gsd-research-synthesizer, gsd-roadmapper, gsd-verifier
- 12 Agent Skills with detailed instruction sets (`.github/skills/*/SKILL.md`)
  - complete-milestone, diagnose-issues, discovery-phase, discuss-phase
  - execute-phase, execute-plan, list-phase-assumptions, map-codebase
  - resume-project, transition, verify-phase, verify-work
- 9 Instructions for workflow guidelines (`.github/instructions/*.instructions.md`)
  - checkpoints, continuation-format, git-integration, model-profiles
  - planning-config, questioning, tdd, ui-brand, verification-patterns
- 18 Project templates in `.gsd/templates/` for context engineering documents
- Full 3-way tool mapping documentation (Claude Code → Kilo Code → GitHub Copilot)

### Changed

- Restructured from Kilo Code format to GitHub Copilot format
- Renamed `.kilocode/skills/` to `.github/skills/`
- Renamed `.kilocode/rules-{mode-slug}/` to `.github/agents/{agent}.agent.md`
- Renamed `.kilocode/workflows/` to `.github/prompts/`
- Renamed `.kilocode/rules/` to `.github/instructions/`
- Converted all tool references from Kilo Code to GitHub Copilot naming:
  - `read_file` → `readFile`
  - `write_to_file` → `editFiles`, `createFile`
  - `apply_diff` → `editFiles`
  - `execute_command` → `runInTerminal`
  - `search_files` → `textSearch`
  - `list_files` → `listDirectory`, `fileSearch`
  - `new_task` → `runSubagent`
  - `codebase_search` → `codebase`, `usages`
- Updated all 47 `.github/**/*.md` files with Copilot tool names and relative paths
- Updated all 18 `.gsd/templates/*.md` files with Copilot references
- Rewrote `update.prompt.md` from npm/npx workflow to git pull workflow
- Removed Kilo Code-specific files (`.kilocodemodes`, `.kilocode/` directory)

### Documentation

- Rewrote README.md with full attribution chain (Claude Code → Kilo Code → Copilot)
- Added 3-way structure comparison table (Claude Code | Kilo Code | GitHub Copilot)
- Added 4-column tool mapping table with all three platforms
- Added tool groups comparison by platform
- Added codebase exploration tools documentation
- Added MCP server support section

### Attribution

This project is a GitHub Copilot port of [GSD for Kilo Code](https://github.com/punal100/get-stuff-done-for-kilocode) by [@punal100](https://github.com/punal100), which itself is an adaptation of [Get Shit Done](https://github.com/glittercowboy/get-shit-done) by [@glittercowboy](https://github.com/glittercowboy). All credit for the core GSD methodology, workflows, and agent designs belongs to the original authors.
