## UI Features: Issue Encyclopedia, AI Chat & Overlay Polish

Origin: Feature expansion to make Widget Watchdog a complete in-app diagnostics experience — not just detection, but education and AI-assisted resolution. Shipped across v2.5.0 and subsequent polish passes.

**Feature groups:**
- **Issue Encyclopedia** — searchable educational deep-dives for every detector type
- **Contextual AI Chat** — per-issue streaming AI assistant with provider abstraction
- **IssueCard enhancements** — "Learn more" and "Ask AI" action links with shimmer animation
- **Overlay UI polish** — status bar safety, MediaQuery optimization, responsive layouts

---

### Issue Encyclopedia

**Files:** `lib/src/ui/issue_encyclopedia_page.dart`, `lib/src/utils/issue_explanation_builder.dart`

**Purpose:** Provide in-depth educational content for every issue type — what it is, why it matters, how to fix it, when to ignore it, and how to read the data. Accessible from any IssueCard via "Learn more" link.

**Architecture:**
- `IssueEncyclopediaPage` is a full-screen overlay mounted in `FloatingIssuesCard`'s `Stack` via `Positioned.fill`
- `IssueExplanationBuilder` provides structured explanations keyed by `PerformanceIssue.stableId`
- Dynamic stableId suffixes (e.g. `excessive_keep_alive:3`, `rebuild_debug_MyWidget`) are stripped to match base explanations
- Returns `null` for custom detector issues (no encyclopedia entry)

**Explanation structure (`IssueExplanation` record):**

| Field | Purpose |
|-------|---------|
| `displayName` | Human-readable issue name |
| `category` | `IssueCategory` for grouping |
| `whatItIs` | What the detection means |
| `readingTheData` | How to interpret the metrics (optional) |
| `whyItMatters` | Performance impact explanation |
| `howToFix` | Concrete fix guidance beyond the brief hint |
| `whenToIgnore` | False positive scenarios (optional) |

**UI features:**
- Search with debounce — filters entries by display name and content
- Expandable entries — `Set<String> _expandedEntries` tracks open items
- Scroll-to support — `scrollToStableId` param pre-expands and scrolls to the target entry on open
- Entrance animation — 400ms slide-up via `AnimationController`

**Integration in FloatingIssuesCard:**
- `onLearnMore` callback on `IssueCard` is non-null only when `IssueExplanationBuilder.explain(stableId) != null`
- Sets `_showDetail = true` and `_detailStableId = issue.stableId` to mount the page

---

### Contextual AI Chat

**Files:** `lib/src/ui/ai_chat_page.dart`, `lib/src/models/ai_chat_adapter.dart`, `lib/src/ai/ai_providers.dart`, `lib/src/utils/ai_context_builder.dart`

**Purpose:** Per-issue AI chat that understands the full context of the detected issue — metrics, encyclopedia knowledge, causal graph, and session state. Makes any AI model dramatically more useful than generic Flutter performance advice.

#### AiChatAdapter — Provider Abstraction

**API:**
```dart
class AiChatAdapter {
  const AiChatAdapter({
    required this.sendMessage,      // Stream<String> Function(AiChatRequest)
    this.networkExcludePatterns,    // auto-exclude provider URLs from monitoring
  });
}
```

**Built-in factories:**

| Factory | Default Model | Endpoint | Network Exclusion |
|---------|--------------|----------|-------------------|
| `AiChatAdapter.anthropic()` | `claude-sonnet-4-20250514` | `api.anthropic.com/v1/messages` | `api.anthropic.com` |
| `AiChatAdapter.openAi()` | `gpt-4o` | `{baseUrl}/v1/chat/completions` | Auto-extracted from `baseUrl` host |
| `AiChatAdapter.google()` | `gemini-2.0-flash` | `generativelanguage.googleapis.com` | `generativelanguage.googleapis.com` |

- OpenAI factory accepts custom `baseUrl` for Azure, proxies, and OpenAI-compatible APIs
- Google factory sends API key via `x-goog-api-key` header (not query param) to prevent network monitoring leakage
- All factories auto-populate `networkExcludePatterns` so the AI provider's own traffic doesn't trigger the network detector

**Configuration:** Set via `WatchdogConfig(aiChat: AiChatAdapter.anthropic(apiKey: myKey))`. When `aiChat` is null, the "Ask AI" link is hidden on all IssueCards.

#### ai_providers.dart — SSE Streaming Implementation

Low-level streaming infrastructure shared by all three provider factories:

- `SseLineParser` — handles TCP chunk boundary splits for Server-Sent Events parsing
- `_streamSse()` — generic SSE streaming function: HTTP request → SSE line parsing → token extraction → `Stream<String>`
- Provider-specific token extractors: `extractAnthropicToken()`, `extractOpenAiToken()`, `extractGoogleToken()`
- Cancellation: on stream cancel, aborts HTTP request and closes client immediately
- Provider-specific request body formatting (role mapping, system prompt placement, header conventions)

#### AiContextBuilder — System Prompt Assembly

**Budget target:** ~2000 tokens. Sections prioritized:

1. **Role preamble** — establishes Flutter performance expert persona
2. **Focus issue full context** — title, severity, category, confidence, detail, fix hint, ancestor chain, stableId
3. **Encyclopedia knowledge** — `IssueExplanationBuilder.explain()` content for the focus issue
4. **Other active issues** — max 5, one-line summaries for broader context
5. **Response instructions** — formatting and behavior guidelines

Also generates **starter questions** — contextual prompts relevant to the specific issue type.

#### AiChatPage — Chat UI

**Constructor params:**
- `issue` — the `PerformanceIssue` being discussed
- `allIssues` — all active issues for broader context in system prompt
- `adapter` — the `AiChatAdapter` for API calls
- `history` / `onHistoryChanged` — persisted conversation (survives page close/reopen)
- `onClose` — returns to the issues list

**UI components:**
- Header with back button and "Ask AI" title (respects device safe area via `MediaQuery.paddingOf`)
- Expandable `IssueCard` context card (capped at 40% screen height, scrollable)
- Starter question chips (shown before first message)
- Message bubbles (user right-aligned, AI left-aligned)
- Streaming bubble with cursor character (`\u258C`) during AI response
- Thinking indicator (3 animated dots) before first token arrives
- Input bar with pill-shaped text field and accent send button

**State management:**
- `_messages` — local list of `AiChatMessage`, synced to parent via `onHistoryChanged`
- `_streamBuffer` — accumulates tokens during streaming
- `_isStreaming` — gates send button and shows streaming bubble
- `_streamSubscription` — cancellable stream subscription for AI response

**Performance considerations:**
- `MediaQuery.viewInsetsOf(context)` (not `.of(context)`) — granular keyboard subscription
- `MediaQuery.sizeOf(context)` for issue context height cap
- `MediaQuery.paddingOf(context)` for safe area inset

---

### IssueCard Action Links

**File:** `lib/src/ui/issue_card.dart`

**Callbacks:**
- `onLearnMore: VoidCallback?` — hidden when null (e.g. custom detector issues with no encyclopedia entry)
- `onAskAi: VoidCallback?` — hidden when null (e.g. when no `AiChatAdapter` is configured)

**Layout:** `LayoutBuilder`-based responsive design:
- **Wide (≥240px):** `Row` with "Learn more" left-aligned (`Flexible` with ellipsis) + `Spacer` + "Ask AI" right-aligned
- **Narrow (<240px):** `Column` with "Learn more" on top + "Ask AI" below right-aligned via `Align`
- Both labels have `TextOverflow.ellipsis` + `maxLines: 1` for extreme narrow cases

**Shimmer "Ask AI" link (`_AskAiShimmerLink`):**
- `ShaderMask` with animated `LinearGradient` — purple → blue → pink sweep
- `AnimationController` with 2-second duration, repeating
- `RepaintBoundary` isolates per-frame shimmer repaints from parent tree
- `AnimatedBuilder` with static `child` — only the `ShaderMask` wrapper rebuilds, not the `Row`/`Icon`/`Text`
- Gradient math: `dx = value * 6.0 - 3.0`, end `dx + 2.0` — full widget coverage, full sweep range

**Theme tokens (in `WatchdogThemeData`):**

| Token | Dark/Light Value | Purpose |
|-------|-----------------|---------|
| `aiShimmerStart` | `#8B5CF6` (purple) | Gradient start color |
| `aiShimmerMid` | `#3B82F6` (blue) | Gradient midpoint color |
| `aiShimmerEnd` | `#EC4899` (pink) | Gradient end color |

---

### Overlay UI Polish

**Status bar overlap fix (`ai_chat_page.dart`):**
- Header top padding includes `MediaQuery.paddingOf(context).top` to respect device safe area (notch, status bar)

**MediaQuery optimization (3 files):**
- `ai_chat_page.dart`: `MediaQuery.viewInsetsOf(context).bottom` for keyboard height
- `floating_issues_card.dart`: Split `MediaQuery.of(context)` into `sizeOf` / `paddingOf` / `viewInsetsOf`
- `issue_encyclopedia_page.dart`: `MediaQuery.viewInsetsOf(context).bottom` for keyboard height

**Rationale:** `MediaQuery.of(context)` subscribes to ALL MediaQuery changes (orientation, text scale, accessibility, etc.). Granular accessors (`sizeOf`, `paddingOf`, `viewInsetsOf`) subscribe only to the specific property needed, avoiding unnecessary rebuilds.

---

### Test Coverage

- 1,490 tests total, 0 analysis issues
- AI chat page: 21 widget tests (header, input, messages, streaming, starter questions, issue context)
- Issue encyclopedia: widget tests for search, expand/collapse, scroll-to, Learn more link visibility and callbacks
- IssueCard Ask AI: widget tests for link visibility, callback wiring
- Shimmer animation: not widget-tested (visual effect, verified manually)
