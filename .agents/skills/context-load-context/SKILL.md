---
name: context-load-context
description: Load or create functional AGENTS.md context files before implementation work. Use when starting frontend/backend/devops code changes, when a task references a domain or feature, or when required context is missing and must be discovered or created.
models:
  claude: haiku      # low-complexity; file discovery and loading requires minimal reasoning
  copilot: gpt-5.4-mini  # mini equivalent for low-complexity Copilot tasks
  codex: gpt-5.4-mini
---

# Load Context — Phase 0 of AI Coding Workflow

**⚠️ MANDATORY PHASE** - Load functional context BEFORE clarifying requirements or executing code changes.

Load or create functional `*_AGENTS.md` context files to enable intelligent, context-aware coding tasks.

## 🎯 Purpose

**Why Context First:** You cannot ask intelligent clarifying questions or implement features without understanding:
- Existing patterns and architecture
- Current implementations
- Domain-specific context
- How similar features are built

## Workflow Steps

### 1. Detect Domain/Feature
- If arguments provided → Use specified domain/feature
- If no arguments → Analyze current conversation context to detect domain/feature
- Extract domain from file paths, feature names, or task description

### 2. Search for Relevant AGENTS.md Files

**Search Strategy:**
1. Use Glob to find AGENTS.md files matching domain pattern: `**/*{DOMAIN}*AGENTS.md`
2. Prioritize:
   - Exact domain matches (e.g., "auth" → `AUTH_AGENTS.md`)
   - Parent feature matches (e.g., "dashboard" → `DASHBOARD_AGENTS.md`)
   - Related domain files (e.g., "orders" → `ORDER_PROCESSING_AGENTS.md`, `INVENTORY_AGENTS.md`)

### 3. Load Context Files

**If files found:**
- Read and load all relevant AGENTS.md files
- Report what was loaded to user
- Summarize key context (TL;DR sections)
- Proceed to Phase 1 (Clarify) or execution

**If NO files found:**
- BLOCK immediately with options:

```
⚠️ CONTEXT REQUIRED - No functional context found for [domain]

Options:
A) Create new [DOMAIN]_AGENTS.md using TEMPLATE_AGENTS.md structure
B) Search codebase more broadly for relevant AGENTS.md files
C) Provide file path(s) manually to load
D) BYPASS - Proceed without context (not recommended)

Respond with A, B, C, D, or type file paths directly
```

### 4. Context Creation (If Requested)

**If user responds 'create':**
1. Read `.agents/templates/TEMPLATE_AGENTS.md` for structure
2. Create new AGENTS.md file with minimal template
3. Place in appropriate location based on domain
4. Report created file path
5. Note: "This is a minimal template - we'll populate it during Phase 8 (Bragi)"
6. Load the newly created file
7. Proceed to Phase 1

### 5. Report Context Status

**Always report:**
- ✅ Context loaded: List all loaded files
- 📝 Context created: Report new file created
- ⚠️ Bypassed: Warn if proceeding without context
- 🎯 Next phase: "Ready for Phase 1: Clarify Requirements" or "Ready to execute"

## Arguments

- Optional domain/feature name to load context for
  - Examples: `auth`, `orders`, `dashboard`, `dotnet`, `api`
  - If not provided, will auto-detect from conversation context

## Usage Examples

```
/context-load-context auth
/context-load-context orders
/context-load-context
```

## Context Loading Rules

**Mandatory for:**
- Frontend code changes
- Backend code changes
- DevOps changes (CI/CD, infrastructure)
- Feature implementation, bug fixes, refactoring

**Optional for:**
- Pure research tasks
- Documentation-only tasks
- Non-functional requirement changes
