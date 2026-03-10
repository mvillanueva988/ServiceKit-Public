<div align="center">

# GSD for GitHub Copilot

**A GitHub Copilot port of the incredible [Get Shit Done](https://github.com/glittercowboy/get-shit-done) system by [glittercowboy](https://github.com/glittercowboy), based on the [Kilo Code fork](https://github.com/punal100/get-stuff-done-for-kilocode) by [punal100](https://github.com/punal100).**

This project adapts GSD's powerful context engineering and spec-driven development workflow to work natively with [GitHub Copilot](https://github.com/features/copilot) using Custom Agents, Prompt Files, and Agent Skills.

[![License](https://img.shields.io/badge/license-MIT-blue?style=for-the-badge)](LICENSE)

</div>

---

## 🙏 Credits & Attribution

> **This is a port of a port, not an original work.**

All credit for the GSD system, methodology, and workflow design goes to:

### **[Get Shit Done](https://github.com/glittercowboy/get-shit-done)** by **[glittercowboy (TÂCHES)](https://github.com/glittercowboy)**

The original GSD is a brilliant meta-prompting and context engineering system for Claude Code. Everything good about this port comes from that project:

- The phase-based workflow (discuss → plan → execute → verify)
- Context engineering architecture (PROJECT.md, STATE.md, ROADMAP.md, etc.)
- Multi-agent orchestration patterns
- Goal-backward verification methodology
- Atomic commit strategies

**If you're using Claude Code, use the original:** https://github.com/glittercowboy/get-shit-done

### **[GSD for Kilo Code](https://github.com/punal100/get-stuff-done-for-kilocode)** by **[punal100](https://github.com/punal100)**

This GitHub Copilot port is based on the Kilo Code adaptation of GSD. The Kilo Code fork adapted GSD from Claude Code to Kilo Code, providing:

- Custom Modes and Skills structure
- Tool name conversions for Kilo Code
- MCP server integration patterns
- Codebase indexing tool usage

**If you're using Kilo Code, use the Kilo Code fork:** https://github.com/punal100/get-stuff-done-for-kilocode

**Join the GSD community:** [Discord](https://discord.gg/5JJgD5svVS)

---

## What This Port Does

This repository adapts GSD for **GitHub Copilot** using VS Code's customization features:

| Original (Claude Code)             | Kilo Code Fork                     | This Port (GitHub Copilot)                              |
| ---------------------------------- | ---------------------------------- | ------------------------------------------------------- |
| Slash commands (`/new-project.md`) | Workflows (`.kilocode/workflows/`) | Prompt Files (`.github/prompts/*.prompt.md`)            |
| Agent prompts in `agents/`         | Custom Modes (`.kilocodemodes`)    | Custom Agents (`.github/agents/*.agent.md`)             |
| Claude Code specific paths         | Kilo Code conventions              | GitHub Copilot conventions                              |
| Skills                             | Skills (`.kilocode/skills/`)       | Agent Skills (`.github/skills/*/SKILL.md`)              |
| Rules                              | Rules (`.kilocode/rules/`)         | Instructions (`.github/instructions/*.instructions.md`) |

### Tool Name Mapping

The full tool chain from Claude Code → Kilo Code → GitHub Copilot:

| Claude Code Tool         | Kilo Code Tool                    | GitHub Copilot Tool           | Description                    |
| ------------------------ | --------------------------------- | ----------------------------- | ------------------------------ |
| `Read`                   | `read_file`                       | `readFile`                    | Read file contents             |
| `Write`                  | `write_to_file`                   | `editFiles`, `createFile`     | Create or overwrite files      |
| `Edit`                   | `apply_diff`                      | `editFiles`                   | Make surgical changes to files |
| `Bash`                   | `execute_command`                 | `runInTerminal`               | Run terminal commands          |
| `Grep`                   | `search_files`                    | `textSearch`                  | Regex search across files      |
| `Glob`                   | `list_files`                      | `listDirectory`, `fileSearch` | List directory contents        |
| `Task`                   | `new_task`                        | `runSubagent`                 | Spawn subtasks/subagents       |
| `AskUserQuestion`        | `ask_followup_question`           | HumanAgent MCP                | Get user input                 |
| `TodoWrite`              | `update_todo_list`                | `todos`                       | Track task progress            |
| `WebSearch` / `WebFetch` | `use_mcp_tool` → `browser_action` | `fetch`                       | Web access                     |
| `SlashCommand`           | `switch_mode`                     | N/A (use agents)              | Change modes                   |
| N/A                      | `list_code_definition_names`      | `codebase`                    | Semantic code search           |
| N/A                      | `codebase_search`                 | `codebase`, `usages`          | Find code by concept           |
| `mcp__*`                 | `use_mcp_tool`                    | MCP tools                     | MCP server tools               |

**Tool Groups by Platform:**

| Category | Kilo Code                                                                                  | GitHub Copilot                                                                |
| -------- | ------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------- |
| Read     | `read_file`, `search_files`, `list_files`, `list_code_definition_names`, `codebase_search` | `readFile`, `listDirectory`, `fileSearch`, `textSearch`, `codebase`, `usages` |
| Edit     | `apply_diff`, `write_to_file`, `delete_file`                                               | `editFiles`, `createFile`, `createDirectory`                                  |
| Terminal | `execute_command`                                                                          | `runInTerminal`, `terminalLastCommand`, `getTerminalOutput`, `runTask`        |
| Web      | `browser_action`, `use_mcp_tool`                                                           | `fetch`, `openSimpleBrowser`                                                  |
| MCP      | `use_mcp_tool`, `access_mcp_resource`                                                      | MCP server tools                                                              |
| Human    | `ask_followup_question`                                                                    | HumanAgent MCP (`HumanAgent_Chat`)                                            |

For full tool documentation:

- **Kilo Code:** [Kilo Code Tools](https://kilo.ai/docs/automate/tools)
- **GitHub Copilot:** [VS Code Copilot Chat Tools Reference](https://code.visualstudio.com/docs/copilot/reference/copilot-vscode-features#_chat-tools)

### 🔍 Codebase Exploration Tools

GSD agents leverage GitHub Copilot's codebase tools for efficient code exploration:

| Tool         | Purpose                | When to Use                                                     |
| ------------ | ---------------------- | --------------------------------------------------------------- |
| `codebase`   | Semantic code search   | Finding related code by concept, locating implementations       |
| `usages`     | Find symbol references | Understanding how functions/classes are used across the project |
| `textSearch` | Regex/text search      | Finding exact patterns when you know what to search for         |

**Agents Using Codebase Tools:**

| Agent                     | Usage                                                             |
| ------------------------- | ----------------------------------------------------------------- |
| `gsd-codebase-mapper`     | Primary use — maps architecture, structure, conventions, concerns |
| `gsd-debugger`            | Finds related code when investigating bugs                        |
| `gsd-executor`            | Locates similar implementations before adding new code            |
| `gsd-verifier`            | Finds implementations to verify goal achievement                  |
| `gsd-integration-checker` | Discovers cross-phase connections and wiring                      |
| `gsd-plan-checker`        | Verifies plan feasibility against existing codebase               |
| `gsd-roadmapper`          | Understands brownfield codebases before planning                  |

### 🔌 MCP Server Support

GitHub Copilot supports MCP (Model Context Protocol) servers for extended capabilities. GSD workflows use this priority:

| Priority | Tool/Server                       | Use Case                                        |
| -------- | --------------------------------- | ----------------------------------------------- |
| 1        | Context7 MCP                      | Library/framework documentation (most accurate) |
| 2        | Copilot `fetch` (built-in)        | Web search, fetching URLs (no MCP needed)       |
| 3        | Exa / Brave Search MCP (optional) | Deep research, company info, news               |
| 4        | HumanAgent MCP                    | Get user input mid-workflow                     |

**MCP Server Tools:**

| MCP Server   | Tools                                    | Use Case                    |
| ------------ | ---------------------------------------- | --------------------------- |
| Context7     | `resolve-library-id`, `query-docs`       | Library documentation       |
| HumanAgent   | `HumanAgent_Chat`                        | Get user input mid-workflow |
| Exa          | `web_search_exa`, `get_code_context_exa` | Code search, deep research  |
| Brave Search | `brave_web_search`                       | General web search, news    |

Configure MCP servers in VS Code settings or agent frontmatter.

### Included

- **27 Prompt Files** — Discovery, planning, execution, verification prompts
- **11 Custom Agents** — Specialized agents (planner, executor, verifier, debugger, etc.)
- **12 Agent Skills** — Reusable skill definitions with detailed instructions
- **9 Instructions** — Guidelines for checkpoints, git integration, TDD, etc.

---

## 🚀 Getting Started

### PowerShell (Windows)

```powershell
# Open your project
cd your-project

# Clone the GSD template
git clone https://github.com/Punal100/get-stuff-done-for-github-copilot.git gsd-template

# Copy to your project
Copy-Item -Recurse gsd-template\.github .\
Copy-Item -Recurse gsd-template\.gsd .\

# Clean up
Remove-Item -Recurse -Force gsd-template
```

### Bash (Linux/Mac)

```bash
# Open your project
cd your-project

# Clone the GSD template
git clone https://github.com/Punal100/get-stuff-done-for-github-copilot.git gsd-template

# Copy to your project
cp -r gsd-template/.github ./
cp -r gsd-template/.gsd ./

# Clean up
rm -rf gsd-template
```

Then reload VS Code and use the `@gsd-planner` agent or `gsd:new-project` prompt to get started.

---

## Installation

1. Clone or copy this repository into your project
2. Reload VS Code to pick up the agents, prompts, and instructions
3. Enable GitHub Copilot customization features in VS Code settings

### VS Code Settings

Enable the customization features:

```json
{
  "github.copilot.chat.codeGeneration.useInstructionFiles": true,
  "chat.promptFilesLocations": [".github/prompts"],
  "chat.instructionsFilesLocations": [".github/instructions"]
}
```

### Structure

```
.github/
├── agents/                   # Custom Agents (.agent.md)
│   ├── gsd-executor.agent.md
│   ├── gsd-planner.agent.md
│   ├── gsd-verifier.agent.md
│   └── ... (11 total)
├── prompts/                  # Prompt Files (.prompt.md)
│   ├── new-project.prompt.md
│   ├── execute-phase.prompt.md
│   ├── plan-phase.prompt.md
│   └── ... (27 total)
├── skills/                   # Agent Skills
│   ├── execute-plan/
│   ├── verify-phase/
│   └── ... (12 total)
├── instructions/             # Custom Instructions
│   ├── git-integration.instructions.md
│   ├── checkpoints.instructions.md
│   └── ... (9 total)
└── copilot-instructions.md   # Global instructions (optional)

.gsd/                         # Project planning data (created per-project)
├── PROJECT.md                # Project vision
├── REQUIREMENTS.md           # Scoped requirements
├── ROADMAP.md                # Phase structure
├── STATE.md                  # Current position, decisions, memory
├── config.json               # GSD settings
├── research/                 # Domain research outputs
├── codebase/                 # Codebase analysis (from map-codebase)
├── phases/                   # Phase-specific files
├── milestones/               # Archived milestones
├── debug/                    # Debug session files
├── quick/                    # Quick mode task files
└── todos/                    # Captured ideas for later
```

---

## How GSD Works

> All methodology credit goes to the [original GSD project](https://github.com/glittercowboy/get-shit-done).

### The Core Loop

1. **Initialize** — Define project, research domain, create roadmap
2. **Discuss** — Capture your implementation preferences
3. **Plan** — Research and create atomic task plans
4. **Execute** — Run plans with fresh context per task
5. **Verify** — Confirm goals were achieved, not just tasks completed

### Why It Works

- **Context engineering** — Right information at the right time
- **Fresh context per plan** — No degradation from accumulated tokens
- **Goal-backward verification** — Check outcomes, not just task completion
- **Atomic commits** — Every task gets its own traceable commit

For full documentation on the GSD methodology, see the [original project](https://github.com/glittercowboy/get-shit-done).

---

## Prompt Reference

| Prompt              | Purpose                         |
| ------------------- | ------------------------------- |
| `gsd:new-project`   | Initialize new project          |
| `gsd:plan-phase`    | Create phase plans              |
| `gsd:execute-phase` | Execute plans in parallel waves |
| `gsd:verify-work`   | User acceptance testing         |
| `gsd:debug`         | Systematic debugging            |
| `gsd:progress`      | Check project status            |
| `gsd:quick`         | Quick tasks with GSD guarantees |
| `gsd:help`          | Show command reference          |

---

## Custom Agents

| Agent                         | Purpose                        |
| ----------------------------- | ------------------------------ |
| 🗺️ `gsd-codebase-mapper`      | Analyze codebase structure     |
| 🐛 `gsd-debugger`             | Scientific debugging           |
| ⚡ `gsd-executor`             | Execute plans atomically       |
| 🔗 `gsd-integration-checker`  | Verify cross-phase integration |
| 🔬 `gsd-phase-researcher`     | Research phase implementation  |
| ✅ `gsd-plan-checker`         | Verify plans before execution  |
| 📋 `gsd-planner`              | Create executable plans        |
| 🌐 `gsd-project-researcher`   | Research domain ecosystem      |
| 📊 `gsd-research-synthesizer` | Synthesize research outputs    |
| 🛤️ `gsd-roadmapper`           | Create project roadmaps        |
| 🔍 `gsd-verifier`             | Verify goal achievement        |

---

## Contributing

This port aims to faithfully adapt GSD for GitHub Copilot. Contributions that improve the integration are welcome.

For improvements to the core GSD methodology, please contribute to the [original project](https://github.com/glittercowboy/get-shit-done).

---

## License

MIT License — Same as the original GSD project.

---

<div align="center">

**Original GSD by [glittercowboy](https://github.com/glittercowboy)**

**Kilo Code fork by [punal100](https://github.com/punal100)** — GitHub Copilot port

⭐ **Star the original:** https://github.com/glittercowboy/get-shit-done

⭐ **Star the Kilo Code fork:** https://github.com/punal100/get-stuff-done-for-kilocode

</div>
