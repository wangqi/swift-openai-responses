# What's New in swift-openai-responses

## Update: 27c0dab → ba6dddd (2025-12-01)

### New Models
- Added GPT-5.1 model family:
  - `gpt-5.1`
  - `gpt-5.1-mini`
  - `gpt-5.1-codex`
  - `gpt-5.1-codex-mini`
- Added `gpt-5-codex-mini`

### New Tools
- **Shell Tool** (`shell`): Execute shell commands in a managed environment
  - Supports multiple commands, timeout, and max output length
  - New item types: `shellCall`, `shellCallOutput`

- **Apply Patch Tool** (`apply_patch`): Create, delete, or update files using unified diffs
  - Operations: create file, delete file, update file
  - New item types: `applyPatchCall`, `applyPatchCallOutput`

### New Features
- **Prompt Cache Retention**: New `CacheRetention` enum with options:
  - `oneDay` ("24h"): Extended prompt caching up to 24 hours
  - `inMemory`: In-memory caching
- Added `promptCacheRetention` field to `Request` and `Response`

### Changes
- `ReasoningConfig.Effort`: Added `none` case for disabling reasoning effort

### Files Changed
| File | Lines Changed |
|------|---------------|
| Config.swift | +10, -5 |
| Item.swift | +267, -1 |
| Model.swift | +15 |
| Request.swift | +7 |
| Response.swift | +7 |
| Tool.swift | +17 |

### Commits
- `14613d0` - Add `gpt-5.1`, `shell` and `apply_patch` tools
- `3e176b8` - wip
- `ba6dddd` - Merge branch 'm1guelpf:main' into main
