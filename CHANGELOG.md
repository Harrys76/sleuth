## Unreleased

### Overlay accessibility, text scaling and theme

- Overlay text follows the system text scale between 0.8x and 2.0x, and the
  app keeps its own scale. The chrome (card header, status row, summary bar,
  footer, badges and trigger) stops at 1.3x, and its fixed heights become
  minimums that grow with the scale, up to the screen's usable height. A
  maximized card follows the keyboard down to its header, summary bar and
  footer. A resize under large text stores the unscaled height. Issue titles
  take two lines above 1.3x, and detail lines wrap. The category and
  confidence badges sit beside the title only at 1.3x or less and while the
  title keeps 96 px; otherwise they move to the badge line. `fontXxs` and
  `fontXs` default to 10 (were 8 and 9). When a host
  `MediaQuery.withClampedTextScaling` above the overlay clamps to a range
  outside 0.8x to 2.0x, the overlay uses a fixed scale at its nearest bound.
- The VM+/FRAME and DBG badges move from the card header to the status row.
  The row wraps, and the issue count stays at its right edge.
- These controls are 48 x 48 dp: the footer buttons, FPS info, banner dismiss,
  rebuild pause and See all, the rebuild header and startup banner, About this
  detection, encyclopedia entries, related chips and search clear, guide
  sections, the AI chat back, copy, send, message copy, starter chip and input
  controls, and the resize grip. The card header's highlight, theme, minimize,
  maximize and restore controls are 36 x 48, and Close is 48 x 48.
- For screen readers, an issue card is one button labelled with its title. Its
  expanded state is announced, and a long press or the Copy details action
  copies it. Pages announce their name and hide the app below them while open,
  and icon-only controls are labelled. Custom actions replace dragging: Move
  up, Move down, Move left, Move right and Move to top left on the card
  header, Taller, Shorter, Wider and Narrower on the resize grip (normal
  window state only), and Move to left edge and Move to right edge on the
  trigger. The header and grip read the card size back. While a screen reader
  or another assistive service is on (`accessibleNavigation` or semantics
  enabled), toasts stay three times longer, and a toast with an action stays
  until it is used or dismissed (a Dismiss button appears).
- Full-screen pages and the Hidden list take keyboard focus from the app while
  open (an `ExcludeFocus` around the app, switched after the frame) and give
  it back on close. Typing, Tab, Enter and Space no longer reach the app
  behind them, and the soft keyboard closes. Closing a page restores the issue
  list's scroll position and moves screen-reader focus to the card that opened
  it. Opening the dashboard focuses its header.
- Moves and resizes, by touch or by screen-reader action, keep the whole card
  in the usable area above the keyboard. A maximized card has no move actions,
  and its grip does not resize it. The footer wraps on a narrow card so Hidden
  keeps a 48 x 48 target and its full label. The Startup metrics and Rebuild
  stats titles wrap at large text.
- AI chat sizes the issue context from the height left above the keyboard, so
  the input and Send stay visible. The input's outline covers the full 48 px
  field and is centred on the Send button at any text scale. The chat keeps
  focus while a reply streams and announces Thinking and the reply.
- Tertiary and quaternary text, `checkboxActive` and the AI chat bubble are
  retuned for WCAG AA on every surface. New tokens `severityCriticalText`,
  `severityWarningText` and `severityOkText` colour severity text. Badges draw
  `textPrimary` on their tint with a 1 px accent border. The trigger icon is
  dark on the warning and OK fills (`triggerIconOnLightFill`). The trigger's
  FPS number sits on an opaque pill in `fpsTextColor` with the severity as its
  border. The Ask AI link text uses `textSecondary`, and the shimmer stays on
  its sparkle. Severity chips show a check when on and a dot when off, with a
  3:1 border. The highlight checkbox's check, the paused rebuild icon and the
  source accent strips reach 3:1.
- An expanded card's actions sit in one row, with Learn more and Ask AI at the
  start and Copy and Hide at the end. Learn more and Ask AI show short labels,
  and screen readers keep the full names. On a narrow card the actions wrap,
  and every row starts at the same edge.
- New `SleuthThemeData.highContrastDark()` and `highContrastLight()` presets.
  Sleuth picks one when the platform reports high contrast and no theme is
  set. They keep state cues at full opacity and draw the structural and
  no-source accents lighter (dark) or darker (light). New tokens `brightness`,
  `badgeFillAlpha`, `focusRingWidth` and `sourceAccentWidth`.
- New `SleuthThemeData.fromColorScheme(ColorScheme)` and
  `fromSeed(Color, {brightness})` map surfaces and text from a Material
  scheme. A text group that fails contrast falls back to the Sleuth preset of
  the same brightness. Every text, check and chip pair is then checked again
  against the scheme's surfaces, and a surface that its text still cannot
  clear falls back together with that text (for example a mid-tone container
  from the `fidelity` or `content` variants).
- The header theme toggle cycles System, Light and Dark, shows a toast and
  persists the choice (`OverlayUiState.themeMode`, `SleuthThemeMode`, JSON key
  `themeMode`). Light or Dark wins over `Sleuth.updateTheme`, which wins over
  `SleuthConfig.theme`, which wins over the automatic choice. System shows an
  `updateTheme` override again, and `updateTheme` with a theme sets the toggle
  to System.
- Escape unfocuses a focused overlay text field, then closes the open page,
  then the dashboard. With only the card open, a focused app text field or an
  open app dialog or sheet keeps its Escape.
- Reduced motion honours both the Android animator duration scale
  (`disableAnimations`) and iOS Reduce Motion
  (`AccessibilityFeatures.reduceMotion`, which Flutter does not put in
  `MediaQueryData`). Under either, page entrances, expand and collapse,
  scrolls to an encyclopedia entry or to the chat's last message, the toast
  fade, the severity chip colour and the rebuild count tween take no time, and
  the Ask AI shimmer stops. Turning either setting on while an animation runs
  finishes it at once, scrolls included.
- The AI chat page has a `Material` surface, so its text field no longer fails
  the `debugCheckHasMaterial` assert in debug builds.
- Example: `ext.sleuthDemo.a11y` reports the accessibility settings, overlay
  text scale, overflow reports and semantics nodes, and releases its semantics
  handle after each dump. `ext.sleuthDemo.theme`,
  `ext.sleuthDemo.overlay action=setTheme` and
  `ext.sleuthDemo.orientation value=portrait|landscape|all` (forces the
  orientation for a hands-free rotation check and reports the size once the
  rotation lands) are new.

### AI chat, list stability and issue ids

- AI chat replies have states. A failed reply shows a short reason with Retry
  and Copy error. The reasons are API key rejected (HTTP 401 or 403), Rate
  limited (429), Provider error (5xx), Offline (no network), Can't reach the
  provider (refused or unreachable host, such as a stopped local Ollama), No
  reply in 30 s and Reply stalled (the two timeouts); anything else reads
  Reply failed. Sleuth reads status codes from Dio, dart_openai and plain HTTP
  messages, and custom adapters can throw the exported
  `AiProviderException(message, statusCode: ...)`. Before the error text is
  logged or kept for Copy error, Sleuth masks credential query parameters and
  JSON fields, Authorization and API-key headers, bearer tokens, `sk-` and
  `AIza` keys, JWTs, and runs of 40 or more letters and digits. The reason
  sits on its own line with the actions wrapped below it. Sleuth never adds
  the error text to the conversation or sends it to the provider. Retry asks
  again without adding a turn, and Retry and Stop give a selection click.
- Stop ends a reply and keeps the text received so far, marked "(stopped)" on
  screen and in Copy conversation. The provider receives the partial text with
  any open code fence closed and the note on its own line
  (`AiChatMessage.stopped`). Closing the chat, system back and the issue
  disappearing keep the partial reply the same way, once. A question left
  without a reply shows "Reply did not finish" with Retry when the chat
  reopens. A new question after it keeps its own bubble, and the request joins
  consecutive user turns with a blank line, so a provider never receives two
  user turns in a row.
- Replies time out after 30 s without a first token or 15 s between tokens by
  default. `AiChatAdapter.firstTokenTimeout` and `stallTimeout` change or turn
  off either wait (the example gives its local Ollama 90 s for the first
  token), and an empty chunk from an adapter restarts the wait. After 5 s the
  thinking row reads "Still waiting for a reply".
- Server-sent events join their data lines before parsing, OpenAI string error
  codes map to their status, and a non-stream JSON error body is raised. The
  built-in transport ends the stream at `[DONE]` instead of reading the
  connection to its end. It raises error frames (Anthropic `{"type":"error"}`,
  and OpenAI-compatible and Gemini `{"error":...}` with a non-empty object or
  string) instead of ending as if done; `"error": false`, `{}` or `""` is not
  an error. The transport drops a byte order mark at the start of the stream.
- The input stays editable while a reply streams. Sending then shows "Wait for
  the reply, or stop it" with a Stop action, and closing the chat while that
  notice is up hides it after the frame. Messages are capped at 4000
  characters, with a counter past 80 %. The streaming reply is a live region
  whose label changes at most every 2 s.
- The prompt gains a "## Session" section with the current route, presented
  and throughput FPS, the latest frame verdict (its phase, mode, and first
  line with the phase timings, cut before any related issue), active issue
  counts by severity, the number of reported issues the user hid (never their
  titles), build mode, connection mode and platform. The other active issues
  list leaves out hidden issues. Route names in the prompt drop any query or
  fragment, and related issue ids are named only for issues the prompt already
  lists. A caption above the input (up to two lines) shows what is sent, and
  once a message has gone out, Copy conversation ends with the context sent.
- Ask AI opens the chat for the card it was tapped on, and the controller
  keeps each card's conversation in memory for the session, so closing and
  reopening the dashboard keeps it. Detectors that report one issue per widget
  under one id (the ListView detector's ids, such as `non_lazy_*` and
  `sliver_to_box_adapter_shrinkwrap`, `wrap_layout_bottleneck`,
  `excessive_repaint_boundary` and the simple structural detectors) stamp
  `PerformanceIssue.occurrenceId` from the flagged element (not exported), and
  the chat is keyed and found by that id, never by title.
- Cards that share a stable id and widget (a detector reporting several
  occurrences) keep their own expansion and highlight. Expanding one no longer
  shows the other twice or drops it.
- Collapsed issue cards hold their order while the dashboard is open. New
  issues enter at the top of the list (below any expanded cards), with a wider
  source accent painted over the card edge for 2 s each and a "New" hint for
  screen readers. A severity promotion moves a card up at once, never down.
  Other rank changes apply after 10 s of quiet while the list is at the top.
  Any touch, scroll or trackpad gesture on the list restarts the 10 s wait,
  and a list scrolled down keeps holding. Collapsing the last expanded card
  keeps the order on screen. Under a screen reader, held cards change order
  only when the dashboard opens, on a severity filter change and on hide or
  unhide (the points where the hold always resets), and a new issue enters at
  its rank position instead of the top, so a new critical never sits under
  older warnings. Exports, `ext.sleuth.*` and MCP keep the ranker's order.
- Per-widget debug rebuild and paint counts (`rebuild_debug_*`,
  `repaint_debug_*`) leave out Sleuth's own overlay. The overlay registers its
  subtree and the widget it wraps around the app, and Sleuth skips elements on
  the overlay side and that wrapper (the decision is cached per element). With
  the dashboard open, a debug build used to report the card's widgets
  (`rebuild_debug_IssueCard`, `rebuild_debug_SleuthListenableBuilder`,
  `repaint_debug_Padding`, ...) as the app's.
- The per-widget counts keep only widgets created outside the Flutter SDK, as
  the framework's creation tracking (on in debug builds) decides. Widgets from
  other packages still count; once DevTools has set the project's root
  directories, only the project's widgets count. New
  `DebugInstrumentationConfig.userWidgetsOnly` (default true) controls this,
  and without creation tracking every widget counts. A paint counts for the
  widget that created the painting render object, so your `CustomPaint`,
  `Padding` or `DecoratedBox` count as themselves, while `Text`, `Icon` and
  `Image` paint through framework render objects and have no paint count of
  their own. Framework widgets such as `_InkFeatures` no longer raise a
  `repaint_debug_*` card each (one animated painter sharing a layer with an
  app bar raised about 40). Framework paints stay in the aggregate count and
  its animation-owned share.
- While semantics are enabled (a screen reader is on), the debug paint counts
  leave out the framework's semantics-only widgets (`Semantics`,
  `MergeSemantics`, `ExcludeSemantics`, `BlockSemantics`, `IndexedSemantics`,
  `_GestureSemantics`), so VoiceOver or TalkBack no longer raises
  `repaint_debug_Semantics`. The VM `excessive_repaint` axis is unchanged.
- A rebuild counts for the widget that started it (`setState`, a changed
  dependency, a listenable builder). The widgets its build updates are counted
  under it (`DebugSnapshot.forcedRebuildsByRoot`), and its card's detail says
  how many, instead of each raising a card. One `setState` on a dashboard used
  to raise cards for `Text`, `Icon`, `Expanded` and every tile type below it.
- Per-widget rebuild and repaint cards no longer appear and vanish on
  alternate scans at the threshold. A widget's card appears when one scan
  reaches the threshold and stays until the rate over the last two scans falls
  below three quarters of it, or until a scan in which the widget did not
  rebuild or repaint at all. Critical uses the same rule around its own
  boundary, and highlights follow the cards. A widget at the threshold used to
  read 9 to 11/s over 1 s scan windows, so its card collapsed if expanded and
  lost its highlight every other scan. The `rebuild_activity` and
  `excessive_repaint` cards stay until the share is under 0.8 times the
  threshold for two VM windows, and stay critical until it is under 0.8 times
  the critical boundary for two windows. Emissions are unchanged, and capture
  mode shows each window as measured.
- The rebuild and repaint detectors keep each source's issues until that
  source updates. Both evaluate on the scan (debug counts) and on the VM
  window, and each evaluation used to replace every issue, so a VM window
  dropped the per-widget cards, a scan dropped the VM share's card (in profile
  too), and the card swapped between `excessive_repaint` and
  `excessive_repaint_debug`. Every VM window is now evaluated, also while
  per-widget cards are shown, so the VM card shows as soon as they clear and
  the rebuild peak keeps moving. `excessive_repaint_debug` reports only
  without a VM connection. A route or tab change and a hot reload drop held
  evidence, restart the VM window and skip that scan's counts (a reload
  rebuilds every element once). A scan that cannot find one page (two
  Scaffolds side by side) drops the held per-widget cards.
- The VM repaint gate that hides `excessive_repaint` while every paint is
  animation-owned now needs every paint in the window owned, framework paints
  included. An animation owner that animates by rebuilding (`AnimatedBuilder`,
  `ValueListenableBuilder`, `TweenAnimationBuilder`, `AnimatedContainer`,
  `AnimatedPadding`, `AnimatedAlign`, `AnimatedPositioned`,
  `AnimatedPositionedDirectional`, `AnimatedFractionallySizedBox`) owns paints
  only in frames where it rebuilt, so an idle one next to a repainting widget
  no longer hides it. A paint over the type cap still counts toward the
  animation-owned aggregate.
- With debug callbacks off, a VM disconnect now removes the
  `excessive_repaint` card, which used to stay until reconnect. When the same
  widget has a rebuild and a repaint card, the more severe one is kept (a
  warning rebuild used to hide a critical repaint).
- Example: demo subtitles fit 40 characters, demo file headers follow the
  home-screen numbering, tile titles use `titleMedium`, and category header
  icons use the theme's primary color. The new Shrink-wrapped Sections demo
  raises one `non_lazy_shrinkwrap` card per list, each with its own AI chat.
  `--dart-define=SLEUTH_AI_BASE_URL` points the Ollama adapter at another
  machine, and `--dart-define=SLEUTH_AI_FAKE=ok|fail|stall|partial|slow|empty`
  swaps in a scripted adapter (`slow` sends its first token after 8 s, and
  `empty` ends without one). The demo header (toggle, instructions and
  metrics) takes at most half the screen and scrolls, so demos fit a phone in
  landscape. The example opts into Android predictive back
  (`android:enableOnBackInvokedCallback`).
- In the example, `ext.sleuthDemo.scroll` and `fling` drive the largest
  scrollable, skipping the demo header, routes below the current one and
  hidden `IndexedStack` tabs. They prefer a scrollable that a touch at its
  centre reaches, so a list on an open overlay page beats the app list behind
  it, and `scroll ms=0` jumps. `tap` and `type` pick the foreground copy of a
  label or field, and `type` takes the focused field first. `tap` refuses a
  target that something else draws over (`obscured`), gives up on a reveal
  scroll after 2 s, and needs `text`, `label`, or both `x` and `y`. Frame
  waits stop after 2 s while the app is in the background, where `a11y` and
  `screenshot` return `unavailable`.
- Example: Rebuild Hotspot, High-Level setState and Combined Chat describe
  what Sleuth reports now: a rebuild card for the widget that starts the
  rebuild (the dashboard's builders in Rebuild Hotspot, with the number of
  widgets they rebuilt in the detail) and, in profile, the Rebuilds banner
  with its "See all" drilldown, not the removed rollup card.
- Example: `FileSleuthStateStore` writes each save through its own temp file
  and drops a late write older than the saved state, so a stalled save and the
  next one cannot interleave. A file that is not UTF-8 reads as no saved
  state. The Tabbed Shell note scrolls within a quarter of the screen.
- Example capture legs bring their screen to the front (a covered screen's
  workload never ran) and fail when it is covered mid-leg. They count the
  in-band records the bracket needs (`minInBandSamples`) before reporting
  done, and stamp the real device (`--dart-define=SLEUTH_CAPTURE_DEVICE`), OS
  and Flutter version, refusing a leg when one is unknown or not approved.
- Every capture screen checks provenance when a leg starts, before any
  workload, and shows the reason on screen. The StreamResource,
  TrackedResource and NetworkMonitor screens judge each leg's measurement
  against its band and check the composed capture against the bracket
  before offering an export (`checkCaptureRecords`: instant events only,
  every in-span record stamped, the reduced value in band, enough in-band
  records). A below leg with no measured value is refused instead of
  exporting `observed` 0, and an export or rewrite failure shows its real
  reason and stashes nothing. The StreamResource at leg runs 150
  subscriptions per kind (100 measured 43 on an iPhone 12, under the at
  band), and its triad is re-recorded with Flutter 3.47.6 at 8, 72 and 110
  instances.

### Detector fixes and schema docs

- Debug repaint cards (`repaint_debug_<Type>`) name the likely origin of a
  layer's repaints instead of every widget painted with it. Sleuth reads
  `debugNeedsPaint` in the paint hook, credits the deepest marked render
  object in each layer to the nearest widget the app creates, and rates
  each type by its busiest instance instead of summing instances. Sleuth
  does not credit widgets that only share the layer, clean
  `RepaintBoundary` visits, slivers, viewports, framework control painters,
  Material ink splashes or scrolling. Following the fix hint therefore no
  longer raises a `repaint_debug_RepaintBoundary` card. The cards are
  titled "Likely Repaint Origin", are `likely`, and highlight the busiest
  origin instances. `frequent_repaint_painter` and the lift of
  `always_repaint_painter` read the same origin rate and hold it across
  scans like the repaint cards, so a slow window no longer drops them. A
  nested boundary repainted earlier in the frame no longer makes the
  ancestors its resize relaid out look like origins. `DebugSnapshot` adds
  `paintOrigins` (`PaintOriginStats`, `PaintOriginInstance`) and
  `paintOriginTypesCapped`; the participation counts are unchanged.
- `ext.sleuth.issues` carries `vmConnected`, so MCP clients can tell a
  connected session from one without a VM link. `ConnectionMode.basic` is
  documented as "no VM-tier frame verdict yet": a connected session that has
  not janked since connect stays basic.
- A scroll that starts during layout (a page view re-fitting its pages after a
  rotation or resize) no longer publishes issues mid-frame. The
  interaction-context refresh runs after the frame, so debug builds no longer
  report "Build scheduled during frame".
- `heavy_compute` emits one issue per VM batch for the longest build over the
  threshold, and when more than one build went over, its detail says how many.
  Each slow build used to emit its own issue under the same stable id, which
  stacked identical cards in the overlay.
- `doc/mcp_schema.{json,md}` match what the handlers emit. `whenToIgnore` is
  nullable. Every `sessionSummary` key is conditional: `topIssues` and
  `detectorHitRates` need a ranked issue, `frameHistogram` needs a frame, and
  `memoryTrendSummary` needs two heap samples. `topIssues[]` documents
  `widgetName`, a nullable `stableId` and an optional `confidenceReason`.
  Route counts note the 256-key cap, and placeholder substitution is
  documented as 0.37 and later.

## 0.37.0

- Scan-root detection works on Flutter 3.47. `IndexedStack` no longer wraps
  inactive children in `Visibility`, so the visible-page walk now descends
  only into the selected child through the element's onstage visitor. Before
  this fix, every scan aborted in bottom-navigation apps on 3.47.
- The minimum versions are Dart `^3.8.0` and Flutter `>=3.32.0`. The previous
  declaration was `>=3.24.0`, but the code already needed 3.27+ APIs.
- The `vm_service` constraint widens to `>=14.0.0 <16.0.0`, so apps on Flutter
  3.32.x can resolve sleuth beside `flutter_test`.
- Overlay keyboard-inset detection reads the hosting `View` instead of the
  first platform view.
- Profile captures may be recorded on Flutter 3.41 or 3.47
  (`ProfileCaptureSchema.approvedFlutterMajorMinors`). The three legs of a
  bracket must still share one exact `flutterVersion`, and
  `approvedFlutterMajorMinor` stays `3.41` as the baseline member.
- Encyclopedia, fix-hint, detector-description, guide and README text now
  match detector behavior (thresholds, Impeller-era shader and repaint
  guidance, profile-mode axis wording, mode table). The debug repaint entries
  read the rate the detector alerts at (30/sec, critical above 60/sec), and
  the debug rebuild entry states its 10/sec alert.
- Encyclopedia entries for detectors removed in 0.20.0 are labelled legacy.
- `non_lazy_listview`, `non_lazy_gridview`, `non_lazy_sliver_list` and
  `non_lazy_sliver_grid` resolve to the `non_lazy_list` encyclopedia entry
  (Learn more, AI context, `ext.sleuth.explain`).
- Explanation placeholders (`{widgetName}`, `{routeName}`, `{count}`,
  `{severity}`, `{title}`, `{stableId}`) are substituted in the AI prompt and
  in `ext.sleuth.explain` and `ext.sleuth.encyclopedia` payloads. `explain`
  fills them from the live issue with the same id. A bare id falls back to
  another live issue of its family; any other id with no exact live match
  (`excessive_keep_alive:PageView~k-home`) gets neutral wording instead of
  another occurrence's values. `encyclopedia` always uses neutral wording.

### Overlay

- System back (gesture or button) closes the innermost overlay layer first: a
  focused text field, then the open full-screen page or Hidden list, then the
  dashboard. With the dashboard closed, back reaches the app unchanged. On
  Android, Sleuth claims predictive back swipes while a layer is open and
  requests `SystemNavigator.setFrameworkHandlesBack(true)` after each layer
  change. The app's own navigation notification turns that flag off at its
  root route, so while a layer is open Sleuth checks the app's navigators
  after each frame and requests the flag again when one of them changed. The
  inert `PopScope` wrappers on the overlay pages are gone.
- Overlay UI state lives in the controller (`OverlayUiState`,
  `Sleuth.overlayUiState`), so the trigger position and the card position,
  size and window state no longer reset when the dashboard closes or on hot
  reload.
- `SleuthConfig.stateStore` (`SleuthStateStore`, which reads and writes a JSON
  string) persists that state across restarts. Sleuth reads it once at startup
  with a 2 s timeout, and the trigger appears when the read finishes. Changes
  made before the read finishes are kept, and a dashboard opened before it
  finishes takes the stored position and size. Writes use a trailing 500 ms
  debounce with one write in flight at a time. A write still running after 5 s
  is given up so later changes are saved, a change waiting for its debounce is
  written when the app goes to the background, and a pending change is written
  on dispose. A read that times out, throws or returns a newer schema leaves
  the defaults and turns writes off for the session, so the stored state is
  not overwritten. Contents no release can read (not a JSON object, no valid
  `schemaVersion`) keep the defaults and are replaced by the next change.
  Return null from `read` when nothing is stored. `InMemorySleuthStateStore`
  is for tests, and the example app ships a file-backed store.
- An expanded card's Hide action removes the card from the overlay, with a 4 s
  Undo, and collapsed effects go with their root. The footer reads
  `N hidden · M suppressed` and opens a Hidden list (restore one, restore all,
  and the `suppressedIssues` patterns listed read-only). Hiding is
  overlay-only: `ext.sleuth.*`, snapshots, MCP budgets, route sessions and
  recurrence still see the issue. The trigger badge and summary counts follow
  the visible cards. A hide covers the card at the severity it was hidden at,
  so a hidden warning shows again if the same card turns critical, and a
  hidden critical stays hidden at any severity (hide keys of critical cards
  end in `!critical`). Restore all offers Undo. Hiding, filtering out or
  losing the highlighted issue clears its highlight.
- An expanded card's Copy action (or a long press on the title) puts the
  title, severity, confidence, route, widget, detail, fix hint and stable id
  on the clipboard as plain text (`PerformanceIssue.toClipboardText()`), with
  a "Copied" or "Couldn't copy" confirmation.
- The summary bar's severity counts toggle that severity, and one always stays
  on. A chip counts the cards of its severity that the list shows; a disabled
  severity counts the cards it would show if turned back on, so an effect
  surfaced by filtering out its root has a chip. When fewer cards show than
  with no filter and nothing hidden, the bar reads "Showing X of Y". Empty
  lists explain why: no issues; none match the filter, with Reset; or all
  hidden, with Show hidden. The bar is 36 px tall at 1x text, and its chips
  keep 48 dp hit boxes.
- The card's minimum height is 300 px (was 250), so two collapsed issue rows
  fit under the summary bar. On a screen whose usable height is smaller (split
  screen, landscape) it stops there, down to the header, summary bar and
  footer. A maximized card refits after a rotation or window resize. The
  status row and banners scroll so the list keeps room for the summary bar and
  one row. The minimized count badge turns red when a critical card is among
  the count.
- A card's "Caused by" list reads "(+N not shown)" (was "(+N suppressed)") for
  parents the ranker left out, so it is not confused with `suppressedIssues`.
- The trigger and card stay inside the view padding and above the keyboard. A
  dragged trigger snaps to the nearest side and keeps its side and vertical
  fraction through rotation. `triggerButtonAlignment` and
  `triggerButtonOffset` set the position until the first drag, measured from
  the safe area.
- One toast replaces the separate export, highlight and rebuild-panel banners,
  and the AI chat copy confirmation now shows (it relied on a missing
  `ScaffoldMessenger`). Toasts sit above the keyboard and are announced to
  screen readers.
- The trigger, the highlight checkbox, the Close button, the severity chips
  and the card actions (Copy, Hide, Learn more, Ask AI) have screen-reader
  labels and 48 dp targets. The trigger reads
  `Open Sleuth, 3 issues, 1 critical` and names the critical count only when
  an issue is critical.
- The overlay builds its listeners, animations, semantics groups and trigger
  layout from Sleuth-named classes, so the profile-mode rebuild filter never
  drops app-owned `ListenableBuilder`, `AnimatedContainer`,
  `AnimatedSwitcher`, `MergeSemantics` or `CustomSingleChildLayout` rebuilds.

### Behavior changes

- The VM client dispatches an empty timeline batch once per second while the
  timeline is quiet (`VmServiceClient.idleHeartbeat`), so window-based
  detectors keep evaluating on a static screen, and a platform-channel burst
  no longer waits for the next unrelated event before it is judged. The
  batch-attributed (FULL) verdict runs only for a batch with phase data and
  never over a frame that already holds a FULL or CORRELATED verdict, so an
  idle batch neither replaces a jank verdict nor fires the verdict notifier.
  Sleuth requests CPU attribution once per frame and applies it to the frame's
  current verdict, and a non-correlated verdict never replaces a captured
  correlated one.
- A structural scan tick schedules a frame when none is pending. On a quiet
  screen the post-frame scan used to wait for the next incidental repaint,
  which left results ten seconds or more behind a tab switch.
- The VM connection is reported lost after three consecutive failed polls (1.5
  s) or as soon as the socket closes, instead of on the first failed RPC. A VM
  under allocation pressure can fail one timeline poll, and treating that as a
  disconnect cleared every detector's VM state and left the memory detector
  without data for tens of seconds after each failure.
- Timeline begin/end reconstruction discards a pair longer than 2 s and evicts
  a pending begin older than that when the next begin arrives. Under heavy
  jank the VM drops events, and a lost begin let a later end pair with a stale
  one and report the gap between two frames as a multi-second `heavy_compute`
  or raster scope.
- `expensive_gpu_nodes` no longer counts the `ClipPath` a transparency
  `Material` builds for its own shape (buttons, chips); user `ClipPath`s still
  count. One render object is now reported once. Wrapper elements above it (a
  `Material`, a `Builder`) used to add a finding each, so a single clip showed
  as three nodes with subtrees one apart.
- The VM connection tries loopback before the address the service reports. A
  wirelessly launched iOS app binds its service to the wildcard address and
  reports the Wi-Fi address. Local-network privacy blocked the app from
  connecting to that address, so Sleuth stayed in Basic mode.
- Ranking uses an evidence tier built from severity and confidence, in this
  order: confirmed critical, likely critical, confirmed warning, possible
  critical, likely warning, possible warning, ok. A structural-only guess
  ranks below a warning observed at runtime. Frame impact and recurrence order
  issues within a tier. `rankingBreakdown` keeps its four keys; `confidence`
  now carries the tier offset from the severity base and can be negative.
- Duration escalation is removed. A warning no longer turns critical after 30
  scan cycles, and severity is the detector's. Persistence shows in the
  `Seen X/Y` badge and the trend.
- A `possible` root claims only `possible` effects in the causal graph; it no
  longer claims `likely` or `confirmed` ones.
- A single-parent effect collapses under its parent only when the parent is at
  least as severe. Multi-parent effects stay visible as before.
- Removed causal edges (cause to effect): `uncached_images` to `heap_growing`,
  `heap_near_capacity` and `gc_pressure`; `excessive_keep_alive:*` to
  `gc_pressure`; `slow_request` to `heavy_compute`; `request_frequency` to
  `rebuild_activity`; `high_frequency_same_path:*` to `rebuild_activity` and
  `rebuild_debug_*`; `multiple_custom_fonts` to `sustained_jank` and
  `jank_detected`; `missing_repaint_boundary` to `raster_dominance`.
- Added causal edges: `uncached_images` to `native_memory_growing` (decoded
  bitmaps live in native memory), `large_response` to `heavy_compute`,
  `excessive_repaint` to `raster_dominance`, and `non_lazy_shrinkwrap` to
  `jank_detected`. The graph has 41 causal rules.
- `compare_snapshots` between a 0.36 and a 0.37 snapshot can show severity
  differences caused by the escalation removal, not by app changes.
- The frame budget follows the measured frame rate. The vsync cadence (10th
  percentile of recent frame intervals), clamped to
  `[fpsTarget, display refresh rate]`, sets the budget, so 90 Hz and 120 Hz
  devices that render at their full rate get tighter jank thresholds, and a
  ProMotion device rendering at 60 keeps 16.67 ms. Opt out with
  `SleuthConfig(autoFrameBudget: false)`. Capture mode always uses the fixed
  `fpsTarget` budget.
- Jank classification compares microseconds (`FrameStats.frameBudgetUs`, JSON
  `frameBudgetUs`, derived from `frameBudgetMs` when absent). At 60 Hz the
  budget is 16667 µs, so a 16.8 ms frame is jank and a 33 ms frame is no
  longer severe (severe starts above 33.334 ms).
- `DetectorThresholds.heavyComputeGapMs` defaults to null (auto): 8 ms at the
  `fpsTarget` budget, and half the resolved budget when the budget tightens.
  An explicit value never scales. The `raster_dominance` per-frame floor
  scales the same way.
- `ext.sleuth.diagnose` adds `effectiveFrameRateHz`, `frameBudgetUs` and
  `frameRateSource` (`fixed`, `display` or `measured`).
- `heavy_compute` and `platform_channel_traffic` keep the interaction context
  they fired in, so an issue raised during navigation still reads `navigating`
  afterwards. Ranking weights recurrence for `navigating` issues at 0.7, like
  scrolling and app-lifecycle. Nothing is suppressed while navigating.
- `layout_bottleneck` suppresses intrinsics built by ToggleButtons, MenuBar,
  linear landscape BottomNavigationBar labels, AlertDialog, SimpleDialog,
  popup menus, CupertinoContextMenu and Scaffold footer buttons (matched by
  owner type within a measured ancestor-hop budget), and they do not count
  toward nesting. A single intrinsic is a `possible` warning; nesting is a
  `likely` critical.
- The font detectors ignore Material's platform families
  (`CupertinoSystemText`, `CupertinoSystemDisplay`, `.AppleSystemUIFont`,
  `Segoe UI`) and the SDK icon fonts. A `packages/<pkg>/` family and its bare
  name, or google_fonts `<Family>_<variant>` names, count as one family.
  `runtime_font_loading` is always a warning.
- `setstate_scope` requires observed rebuilds: child-identity churn across
  scans, or a debug-callback snapshot naming the owner (timeline-sourced
  counts do not qualify). A wide but static page no longer emits. Critical
  means the ratio exceeds 1.5× `dirtyRatioThreshold`, capped at 1.0.
  Builder-style owners (FutureBuilder, StreamBuilder, ValueListenableBuilder,
  Form, Focus and similar) never emit.
- `excessive_keep_alive` counts a keep-alive toward the innermost PageView or
  TabBarView only. ListView, GridView, CustomScrollView, NestedScrollView and
  SingleChildScrollView act as barriers and never emit, so a TabBarView emits
  once (previously twice, with its internal PageView), and kept-alive list
  items inside a page are not counted. Ids name the scrollable instead of its
  position: `excessive_keep_alive:<TypeName>~<part>`, where the part is `k-`
  plus the scrollable's string or number `ValueKey` (sanitised to
  `[A-Za-z0-9_-]`, 24 characters), or else its ordinal among unkeyed page
  scrollables of that type, counted in tree order before nested ones
  (`excessive_keep_alive:PageView~1`). A part repeated within a scan gets
  `-2`, `-3`. A hide stays with its scrollable when another scrollable starts
  keeping pages alive.
- `stateful_density` has its own threshold,
  `RebuildDetector.statefulDensityThreshold` (default 10), instead of
  following the rebuild-rate threshold.
- The list detectors' issue text says list-style children allocate every child
  widget on each parent rebuild, instead of claiming every item is built at
  once. Highlights go critical at the same threshold as the issue (more than
  3×). `sliver_to_box_adapter_shrinkwrap` fires only when the child count is
  unbounded or above 20.
- `CustomPainterDetector` and `RepaintBoundaryDetector` skip framework
  painters. Toggle and scrollbar painters are matched by type
  (`ToggleablePainter`, `ScrollbarPainter`). Material shape borders (Card,
  buttons, FAB), input borders, the TabBar indicator and divider, progress and
  activity indicators, overscroll glow and stretch, AnimatedIcon, the dropdown
  menu, Placeholder and GridPaper are matched by painter class name plus the
  owning widget within a measured ancestor-hop budget. A user painter with the
  same class name outside that owner is still reported.
  `RepaintBoundaryDetector` also skips the `ClipPath` a transparency
  `Material` builds for itself.
- `excessive_repaint_boundary` no longer counts the boundaries a default
  `SliverList` or `SliverGrid` adds per child inside a `CustomScrollView`.
  Boundary frames are keyed by the element that pushed them, and any
  `BoxScrollView` subclass is supported. User boundaries under a
  `SliverToBoxAdapter` or an `addRepaintBoundaries: false` delegate still
  count toward the enclosing scroll view.
- `uncached_images` measures instead of pattern-matching. Each `Image` is
  paired with its decoded picture, and a decode shared by several widgets is
  measured once against the largest size those widgets need ("shown by N
  widgets", `extraTraceArgs.widgetCount`). An image counts when its decode is
  at least 1.5× the physical pixels its box needs on the smaller axis (box ×
  device pixel ratio). The issue emits as `likely` when counted images waste
  at least 1 MiB in total, and is critical at 16 MiB or more. The title shows
  the worst ratio and the wasted megabytes, and the detail lists the top five.
  The detector skips images not yet decoded, `ResizeImage` providers
  (`cacheWidth` / `cacheHeight`), `BoxFit.none`, `centerSlice`, `repeat`, and
  images with no reachable device pixel ratio. `BoxDecoration` images are no
  longer reported, because their decode is not reachable. The 50 dp
  small-image skip and the rule that made more than 5 images critical are
  removed. The encyclopedia calls the issue Oversized Images.
- New `non_lazy_shrinkwrap` (ListView detector): a `ListView` or `GridView`
  with `shrinkWrap: true` inside a `Column` or `Row`, with an unbounded main
  axis (not under `Expanded` or a sized box) and more than 20 children (or an
  unbounded builder), is a `possible` warning, critical above 100. It replaces
  `non_lazy_listview` for the same list. Inside a `SliverToBoxAdapter`,
  `sliver_to_box_adapter_shrinkwrap` still wins. Like the other list ids, it
  escalates to `likely` with jank.
- `detectorHitRates` counts `non_lazy_sliver_list` and `non_lazy_sliver_grid`
  toward the ListView detector, `stream_resource_growth` toward
  `streamResource` and `tracked_resource_*` toward `trackedResource`
  (previously all `custom`).
- `missing_repaint_boundary` caps at `likely`, because per-type paint rates
  cannot point at the specific unprotected widget.
- `frequent_repaint_painter` and the `always_repaint_painter` upgrade use the
  CustomPaint paint rate minus animation-owned paints.
- `shader_compilation` reads engine begin/end pairs: Impeller Vulkan pipeline
  builds (`PipelineVK::Create`, `CreateComputePipeline`) and Skia shader
  compiles (`devtoolsTag: shaders`). Issues are `likely`, because a build
  stalls only the frames that need that pipeline. Impeller Metal emits no
  build events and stays silent. The `--cache-sksl` / `--bundle-sksl-path`
  advice is removed.
- Platform-channel profiling is opt-in.
  `SleuthConfig(profilePlatformChannels: true)` sets
  `debugProfilePlatformChannels` once the VM connects and restores it on
  dispose. While it is on, the framework prints a "Platform Channel Stats"
  table to the console every second that channels are active.
- `platform_channel_traffic` emits on call count only. Per-call durations come
  from async `b`/`e` pairs matched by `id`; when an id is reused before its
  first call ends, each end pairs with the earliest open begin (same thread
  first). The issue reports `maxCallDurationUs`, `p95CallDurationUs` and
  `callsOverThreshold`. `platformChannelDurationThresholdMs` (default 8) now
  marks slow calls and no longer triggers. `cumulativeDurationUs` is no longer
  stamped. Exported channel summaries carry measured durations.
- `large_response` skips `image/`, `video/`, `audio/` and `font/` responses.
  `RequestRecord.contentType` (MIME type, serialized when present) is new.
  Network monitoring observes `dart:io` `HttpClient` traffic only;
  `cronet_http`, `cupertino_http` and platform-SDK networking are invisible.
- `issuesNotifier` fires only when something rendered changes (ids, order,
  severity, confidence, category, text, widget or route attribution,
  interaction context, causal links). Timestamps, ranking scores and trace
  arguments no longer trigger it. Export, fix verification and
  `ext.sleuth.issues` / `ext.sleuth.explain` read the latest aggregation. A
  per-tick scan pulse keeps the rebuild-stats panel and the `Seen X/Y` badge
  live.
- Scrolling re-measures highlight rects from their render objects instead of
  rescanning the tree, so scrolling no longer consumes detector state.
  `WidgetHighlight.renderObject` is new (optional). `refreshHighlights()`
  requests an early scan tick, and scroll end runs one early tick 300 ms
  later.
- A scan tick costing more than 4 ms stretches the next interval to
  `treeScanInterval × ceil(cost / 4 ms)`, capped at 5 s (not in capture mode).
  The clean-scan back-off no longer shortens intervals above 2 s.
  `SleuthConfig.maxElementsPerScan` (default 0, unlimited) skips one tick
  after a walk over the cap; a walk is never cut short.
- Periodic ticks defer by 250 ms while scrolling, at most three times in a
  row, and a scroll with no activity for 2 s counts as ended.
- Route names come from `ModalRoute.settingsOf`, so the scan root no longer
  rebuilds on route pushes, pops and animation status changes.
- Long sessions stay bounded. `RouteSession.issueSnapshots` and
  `rebuildCountsByType` keep at most 256 keys
  (`RouteSession.maxTrackedEntries`, oldest-inserted evicted), unnamed-route
  ordinals are dropped with their last session, and recurrence trends go stale
  120 cycles after their last presence even when it has left the 60-entry
  window. The type-name cache persists across scans and clears on hot reload.
- `raster_dominance` fires without a VM. Each frame's `FrameTiming` raster
  time is compared with its UI time. Three frames within one second whose
  raster time exceeds the per-frame floor and `gpuPressureRatio` × UI time
  raise it as `likely` (new `ObservationSource.frameTiming`), critical when
  those frames also exceeded the frame budget. A route change starts a new
  window, and the issue carries the route it was emitted on, so frames from
  the previous screen are not credited to the next one. Frames in the startup
  window (`startupPhaseWindowSeconds`) are ignored on both legs, so cold-start
  pipeline compilation no longer raises a VM-timeline `raster_dominance`. The
  VM leg is unchanged and still emits `confirmed`, and a scan emits at most
  one `raster_dominance`. A VM disconnect keeps frame-sourced issues. The
  frame leg needs Frame Timing enabled.
- `expensive_gpu_nodes` is `likely` when raster-dominant frames were seen from
  either source, and its text no longer asks for a VM connection.
- `BaseDetector.processFrame(FrameStats)` (default no-op) receives every
  presented frame on every tier. A detector that throws there is reported once
  and skipped until the next scan.
- `gc_pressure` defaults to more than 180 GC/min
  (`SleuthConfig.gcRateThresholdPerMin`, previously 60). An idle app with
  Sleuth attached runs 66 to 138 scavenges per minute from its own VM-service
  polling (measured on an iPhone 12). Emissions stamp `scavengeCount` and
  `oldGenCount`, read from each GC event's raw `gcType`.
- `heap_near_capacity` measures process RSS against the new opt-in
  `DetectorThresholds.memoryBudgetBytes` (default null, which turns the issue
  off). It fires when RSS is at or above `memoryCapacityPercent` (default
  0.80, now a fraction of the budget) of the budget for 4 of the last 5 memory
  polls while `heap_growing` is emitted. It is critical and `likely`, with one
  identity per episode. The Dart heap usage/capacity rule is removed, because
  Dart grows capacity with usage and the ratio sat at 85 to 97 % on idle
  screens. Older capture files still carry `heap_near_capacity` and
  `gc_pressure` records from the previous rules, and no audit reads them.
- Jank is judged per route. `FrameTimingDetector.markRouteEpoch()`, called
  when the scan loop sees a new route, drops `sustained_jank` and
  `jank_detected` at once. Later evaluations read only frames since then, and
  emissions carry `sourceRoute`. Frames up to one scan tick after navigation
  still count toward the previous route, and frames before the first scan
  (startup) no longer count. The frame buffer, FPS and verdicts are unchanged.
- `platform_channel_traffic` stays visible for 10 s after it fires
  (`PlatformChannelDetector.emissionPersistence`). After the 3-window cooldown
  the issue is kept unchanged, so a burst still records one trace event.
- Example: the GPU Pressure demo animates eighteen blurred circles (with a
  pause switch) to raise `raster_dominance`. The new Tabbed Shell demo
  (`IndexedStack`) shows one structural pattern per tab.
- `rebuild_activity` and `excessive_repaint` measure cost, not count: the
  share of UI-thread wall time spent inside BUILD or PAINT scopes per ~1 s VM
  window, divided by the window's measured length. Both warn above 10 % and go
  critical above 30 % (`excessive_repaint` critical moves from 2× to 3× the
  warning threshold). A 60 fps animation of a small subtree no longer raises
  `rebuild_activity`. Titles read `build phase 18.2% of UI time`, and
  emissions stamp `observedBuildPercent` / `observedPaintPercent` (one
  decimal) instead of `observedRebuildRate` / `observedPaintCount`.
- New `DetectorThresholds.buildTimePercentThreshold` and
  `paintTimePercentThreshold` (default 10). `SleuthConfig.rebuildThreshold`
  and `RepaintDetector.paintFrequencyThreshold` now gate only the per-widget
  debug paths (`rebuild_debug_*`, `repaint_debug_*`,
  `excessive_repaint_debug`).
- Removed: `RebuildDetector.setBaseline`, `baselineRebuildRate`,
  `lastObservedRebuildRate`, `peakObservedRebuildRate`;
  `RepaintDetector.lastObservedPaintCount`, `peakObservedPaintCount`. They are
  replaced by `lastObservedBuildPercent` / `peakObservedBuildPercent` and
  `lastObservedPaintPercent` / `peakObservedPaintPercent` (double).
  `FixHintBuilder.rebuildActivity` takes `buildPercent`, and
  `excessiveRepaintVm` takes `paintPercent`.
- The `rebuild_activity` (warning, critical) and `excessive_repaint` (warning)
  capture triads are re-recorded on the iPhone 12 / iOS 17.5 / Flutter 3.47.6
  on the time-share axis (`percent`, atTolerance 0.5, ceiling 2.7×,
  observed-axis tolerance 0.25; the critical bracket keeps
  `minInBandSamples: 2`).
- Example: the RebuildActivity and Repaint capture screens vary build or paint
  cost per frame with a calibration pre-pass, and `ext.sleuthDemo.captureLeg`
  / `captureResult` / `vmAxes` drive the legs. The repaint leg records 6 s
  (was 4 s), with the above leg aimed at 2.0× the threshold. `vmAxes` refuses
  `reset=true` while a leg runs, and a scenario end that throws in a leg's
  cleanup is logged instead of replacing the leg's result.
- The VM poll loop fetches incrementally and never clears the VM timeline. The
  first poll of a session reads the whole buffer (startup events). Later polls
  read a window from 500 ms (one poll interval,
  `VmServiceClient.fetchOverlapMicros`) before the newest event seen to the
  VM's timeline clock plus 1 s, and per-thread cursors drop the overlap.
  Begin/end pairs split across fetches pair through the pending-begin maps.
  The newest timestamp is bounded by the clock reading, and thread cursors
  past it are rewound to the newest cursor within it, so one event stamped
  ahead of the clock cannot stop timeline data for the rest of the session. A
  clock read that fails or runs behind the newest event falls back to a full
  read with a client-side floor, and after three such fallbacks in a row the
  next poll reads the whole buffer (counted in `pollWindowFallbacks`). Capture
  mode no longer re-reads the retained ring buffer on every poll (the source
  of two UI-isolate stalls per poll), live mode no longer loses events written
  between the fetch and the clear, and DevTools keeps its timeline.
- Timeline parsing compares `ts` before reading any other field and builds the
  `(ph, name, id)` dedup signature only for events at a cursor's latest
  timestamp. `ParsedTimelineData` gains `maxTimestampUs` (used by the
  stale-begin sweep instead of a second walk) and `duplicatesDropped`.
- Poll cost is measured. `Sleuth.lastPollTimings` (`PollTimings`) holds the
  RPC time, the UI-isolate decode inside it, parse, dispatch, tail RPCs, event
  count, raw response length and duplicates dropped. `uiBlockingMicros` sums
  the UI-isolate segments (decode, parse and dispatch), while RPC and tail are
  wall time including VM-side work. `ext.sleuth.diagnose` adds
  `lastPollRpcMicros`, `lastPollDecodeMicros`, `lastPollParseMicros`,
  `lastPollDispatchMicros`, `lastPollTailMicros`, `lastPollEventCount`,
  `lastPollResponseChars`, `maxPollRpcMicros`, `maxPollDecodeMicros`,
  `maxPollParseMicros`, `maxPollDispatchMicros` (32-poll maxima),
  `pollDuplicatesDropped` and `pollWindowFallbacks`. The decode runs from the
  arrival of the matched raw response (`VmService.onReceive`) to the completed
  await. The response is matched by request id within its first and last 64
  characters, so ids nested in a payload cannot match. When no response
  matches, the decode and response length are null (`PollTimings.decodeMicros`
  and `responseChars` are nullable). Every reading is null after a reconnect
  until the new session's first poll. Dispatch and tail are split further:
  `lastPollDispatch{Detectors,Correlate,Aggregate,Other}Micros` (they sum to
  the dispatch), `lastPollTailMemoryMicros` (the `getMemoryUsage` await), and
  `lastPollTail{CpuSamples,AllocationProfile}Micros` (tail time during which
  such a request was in flight).
- Measured on the iPhone 12 (iOS 17.5, profile, 500 ms polls, median per
  poll): capture mode on the idle home screen went from 117 ms RPC, 7.6 ms
  parse, 3.7 MB and 23.8k events to 6.6 ms, 0.3 ms, 38 KB and 278 events, flat
  over five minutes. Live mode on the idle home screen stays at 6.4 ms RPC,
  with parse down from 1.5 ms to 0.3 ms. On the live-mode FPS stress screen
  the dispatch segment fell from 211 ms median (238 ms max) to 0.2 ms, and the
  tail from 808 ms median (847 ms max) to 27 ms once CPU-sample requests were
  spaced, and the verdict mode is `correlated` again. The UI-isolate decode is
  1.0 ms per poll on the idle home screen and 21 to 29 ms on the FPS stress
  screen (1.5 to 1.7 MB per poll), so decode, parse and dispatch together
  block the UI isolate for about 1.5 ms per 500 ms at idle.
- `getCpuSamples` (jank-frame CPU attribution) is issued at most once per 10 s
  (`VmServiceClient.cpuSamplesMinInterval`) and never while an earlier
  request, including one that timed out, is unanswered. A request left
  unanswered for 30 s (`cpuSamplesInFlightStaleAfter`) stops blocking. The VM
  builds the profile on the UI isolate's own thread, and the response (about
  3.3 MB for a 60 ms window, mostly the function table) is decoded there.
  Issued on every poll with a jank verdict, it stalled the UI isolate by about
  20 ms + 95 ms per poll on an M1 Pro.
- The debug paint callback caches each element's ancestor chain and its
  nearest ancestor animation owner, and checks on each paint whether that
  owner drove the frame. The cache entry is recomputed when any ancestor
  either walk read is a different or unmounted element, or when the depth or
  the hot-reload epoch changes. `SourceLocationCache` keys on the widget
  `Type`. 1,000 paints of a repainting widget cost about 5 % of the uncached
  path.
- Correlated verdicts are no longer suppressed when a poll batch spans several
  frames. The trust check compared one frame's matched events against the
  whole batch, so with three or more frames no frame reached half and the
  verdict fell back to `full`. `CorrelatedFrameData` now carries
  `batchMatchedEventCount` and `batchCoverageRatio` (events that matched any
  frame). A frame is trusted when it matched at least two events
  (`CorrelatedFrameData.minTrustworthyEvents`), so a single phase cannot drive
  a correlated verdict, and the batch coverage is at least 0.5.
  `coverageRatio` is removed, and `FrameVerdict.correlationCoverage` reports
  the batch coverage.

### Testing

- Wall-clock benchmarks carry the `benchmark` tag and run serially:
  `flutter test --exclude-tags benchmark` runs the default suite and
  `flutter test --tags benchmark --concurrency=1` runs the benchmarks. Budgets
  are about 5× the measured serial means, doubled on CI.
- The audit forwards each detector's canonical `observedAxisReduction` to
  bracket validation, so the `jank_detected` bracket is checked with `last` as
  declared.

`kSleuthPackageVersion` is 0.37.0. The `sleuth_mcp` 0.8.0 sidecar pins
0.37.0.

## 0.36.0

Companion package: `sleuth_mcp` is now available — an MCP stdio sidecar that
exposes the `ext.sleuth.*` VM service extensions to AI clients (Claude Code,
Cursor, Zed), so an assistant can query a running app's live performance data in
conversation. Opt-in and versioned independently (see
[`packages/sleuth_mcp/CHANGELOG.md`](packages/sleuth_mcp/CHANGELOG.md), current
0.7.2). The in-app overlay remains sleuth's primary UX.

This release also brings the MCP integration surface and snapshot controls
(consolidates 0.32.0–0.35.0; per-version detail in `CHANGELOG.archive.md`):

- Seven `ext.sleuth.*` extensions — `snapshot`, `issues`, `routeHealth`,
  `explain`, `encyclopedia`, `causalGraph`, `diagnose`. Debug/profile only
  (`kReleaseMode` no-op). Every response stamps `connectionMode`,
  `schemaVersion: 1`, and a per-session `sessionUuid`.
- Wire-shape lock — `doc/mcp_schema.{json,md}` codify the envelope and every
  handler's data shape (nested `recurrenceTrends` / `sessionSummary` /
  `routeSessions` included), audit-enforced.
- Snapshot projection + pagination — `sections` / `maxIssueCount` /
  `maxRouteCount` keep long sessions under the MCP client token cap;
  backward-compatible (no args = full payload).
- `SleuthConfig.showOverlay` (default `true`): set `false` to hide the in-app
  overlay (trigger button + dashboard) while detectors and `ext.sleuth.*` keep
  running — for MCP-only sessions where the AI client is the consumer.

`kSleuthPackageVersion` → 0.36.0; envelope `schemaVersion` stays `1`. Sidecar
`sleuth_mcp` (current 0.7.2) pins 0.36.0.

## 0.30.1

pub.dev README polish — no detector or distribution change.

- `doc/logo.png` now ships in the published archive (`.pubignore` whitelist) so the README hero image renders on pub.dev instead of falling back to the alt text.
- Tests-passing badge refreshed to the current count (3,001).

## 0.30.0

`TrackedResourceDetector.tracked_resource_long_lived.warning` raised to runtimeVerified via `additionalBrackets[0]`. Distribution: 15/20 effective runtimeVerified family-severity pairs across 12 unique stableIds.

- Long-lived bracket: threshold 300 (matches default `longLivedSeconds`), unit `seconds`, atTolerance 0.5 (at-band [300, 450]), aboveCeilingMultiplier 3.0 (ceiling 900). `observedAxisArgKey: 'oldestInstanceAgeSeconds'`, `requireUniqueDetectedAtMicros: true`. Three iPhone 12 / iOS 17.5 / Flutter 3.41.4 captures with real-time waits past the 300 s production threshold.
- Detector behaviour change: `_evaluateLongLived` overwrites `longLivedFirstCrossMicros = nowMicros` each sweep (was `??=` first-cross-only). A long-lived overshoot now produces an emission per sweep with monotonically-increasing age — captures get a real ascending-age series (`observedAxisReduction: 'max'` picks the leg-end value), and a lingering leak re-flags every sweep with the current elapsed retention. UI cards unchanged (same stableId, age refreshes).
- `captureTraceStableId: longLivedStableId` re-added to `_evaluateLongLived` so parametric `tracked_resource_long_lived:<name>` emissions route through the bare family for the bracket validator's byte-exact filter.
- New public API: `lastObservedAgeSecondsFor(name)` / `peakObservedAgeSecondsFor(name)` per-name age observables. `_sweep()` records each pass; `untrackAll(name)` drops entries; `resetCaptureState()` clears them.
- Capture screen long-lived legs: register 1 ref + real-time wait (250 / 380 / 600 s for below / at / above) at the production threshold. `dispose()` clears per-name override defensively via `Sleuth.setResourceThreshold(_kResourceName)` (both null = remove).

## 0.29.1

`IssueEncyclopediaPage` "Learn more" navigation now resolves to the correct entry for parametric stableIds (`tracked_resource_concurrent:<name>`, `excessive_keep_alive:<i>`, `excessive_global_keys:<i>`) and dynamic-suffix stableIds (`repaint_debug_<typeName>`, `rebuild_debug_<typeName>`). Previously the page used byte-exact `scrollToStableId` against `IssueExplanationBuilder.allExplanations` (bare-family keys), so parametric/dynamic variants never expanded or scrolled the target entry.

- New public `IssueExplanationBuilder.canonicalId(String)` — strips parametric `:<param>` and dynamic widget-type suffixes, mapping a `PerformanceIssue.stableId` to the encyclopedia key.
- `IssueEncyclopediaPage._scrollTargetKey` getter resolves `widget.scrollToStableId` through `canonicalId`; `initState` `containsKey` check, `_scrollToTarget`, and per-row `isScrollTarget` comparison all use the normalized key.

## 0.29.0

`TrackedResourceDetector.tracked_resource_concurrent.warning` raised to runtimeVerified via `perStableIdTier`. Distribution: 14/20 effective runtimeVerified family-severity pairs across 11 unique stableIds.

- Bracket: threshold 6 (smallest count > default `maxConcurrent` 5 that triggers emission), unit `instances`, atTolerance 0.5 (at-band [6, 9]), aboveCeilingMultiplier 3.0 (ceiling 18). `observedAxisArgKey: 'liveInstanceCount'`, `requireUniqueDetectedAtMicros: true`. Three iPhone 12 / iOS 17.5 / Flutter 3.41.4 captures.
- New `PerformanceIssue.captureTraceStableId` optional field. When set, `CaptureHelper.composeIssueEvent` uses it (instead of `stableId`) to compose the `sleuth.issue.<id>.<severity>` trace-event name. Parametric stableId detectors (`tracked_resource_concurrent:<name>`) route the trace event through the bare family so the bracket validator's byte-exact filter matches every member. UI cards still key on the parametric `stableId`; equality + hashCode unchanged.
- Detector capture plumbing: `flushConcurrentEvaluation()` (synchronous sweep, bypasses the 10 s sweep-timer); `untrackAll(name)` (drop bucket + detach Finalizers — leg isolation for capture screens); `resetCaptureState()` (clears per-name observables + every bucket's `concurrentFirstCrossMicros` / `longLivedFirstCrossMicros`, propagated from `SleuthController.resetCaptureState`); per-name getters `lastObservedLiveCountFor(name)` / `peakObservedLiveCountFor(name)` plus aggregate `lastObservedLiveCount` / `peakObservedLiveCount` for back-compat. Capture screens MUST use the per-name getter — the aggregate would track an unrelated bucket if another `Sleuth.trackResource(...)` registration is active.
- `tracked_resource_long_lived` family stays reproducerOnly — 300 s threshold exceeds an on-device scenario window. `_evaluateLongLived` does NOT set `captureTraceStableId`, so its emissions never land as bare-family `sleuth.issue.tracked_resource_long_lived.warning` events in capture mode (which would be unclaimed evidence: no bracket, no `coveredThresholds` entry).
- New `example/lib/demos/tracked_resource_capture_screen.dart`. Per-leg flow: `untrackAll` + clear strong-refs → `suspendNonEssentialTimelineStreams` → `markScenarioBegin` → synchronous allocate + register → `flushConcurrentEvaluation` → 3 × 32 ms frame yields → `flushTimelineNow` → read `peakObservedLiveCountFor(name)` → `markScenarioEnd` → 600 ms drain → `exportCaptureJson`.

## 0.28.0

New `Sleuth.setResourceThreshold(name, {int? maxConcurrent, int? longLivedSeconds})` per-name threshold override for `TrackedResourceDetector`. `trackResource` / `untrackResource` API unchanged.

- **Merge semantics**: omitted or invalid axis preserves the prior value for that axis. Explicit both-null clears the override. Subsequent calls update one axis without losing the other.
- Override is bucket-independent — survives empty-bucket sweep eviction, LRU bucket drops, and `isEnabled = false` toggle. `dispose()` clears.
- Per-axis validation: invalid values (`<= 0`) drop that axis (counted via `droppedOverridesCount`). Cap at 1000 distinct names — new-name overflow silently drops; updates to existing names always succeed. Runtime guard (release-safe).
- Issue `extraTraceArgs` always stamps `effectiveMaxConcurrent` / `effectiveLongLivedSeconds` + `thresholdSource` (`'override'` or `'global'`).
- Pre-init calls (before `Sleuth.init`) drop with a once-per-session debug warning.
- Cross-isolate / `kReleaseMode` no-op (matches `trackResource` shape).

## 0.27.0

New `TrackedResourceDetector` (runtime, opt-in) + public `Sleuth.trackResource` / `Sleuth.untrackResource` API. 19 → 20 detectors.

- `Sleuth.trackResource(name, resource)` registers; tracker keeps `WeakReference` + Finalizer token + first-seen timestamp per registration. Token is the registration identity (allocation-unique, collision-resistant); shared `Finalizer` dispatches release on GC reclaim. `Sleuth.untrackResource(name, resource)` is the optional explicit decrement.
- Two emission paths, both `confirmed`:
  - `tracked_resource_concurrent.warning` — live count under one name > `trackedResourceMaxConcurrent` (default 5).
  - `tracked_resource_long_lived.warning` — single instance alive past `trackedResourceLongLivedSeconds` (default 300 s).
- LRU cap (`trackedResourceMaxDistinctNames`, default 1000) bounds the in-memory bucket map; eviction detaches per-ref Finalizer entries so VM-side state stays bounded. Periodic sweep (`trackedResourceSweepIntervalSeconds`, default 10 s) drives evaluation.
- Pure Dart — no VM service dependency. Cross-isolate registration is a no-op (one controller per isolate).
- Primitive / record targets silently dropped via `droppedTargetsCount`.
- New `CausalGraphRule` edges `tracked_resource_concurrent → heap_growing` and `tracked_resource_long_lived → heap_growing`.
- Tier `reproducerOnly`.

## 0.26.0

`stream_resource_growth.warning` raised to runtimeVerified; `gc_pressure` default 30 → 60/min.

- `StreamResourceDetector`: `stream_resource_growth.warning` → runtimeVerified via `perStableIdTier`. Three iPhone 12 / iOS 17.5 / Flutter 3.41.4 captures bracket threshold 50 (unit `instances`) on `topGrowthDelta` axis; atTolerance 0.6, aboveCeilingMultiplier 3.0.
- BREAKING-ISH: magnitude gate switched from summed `netDelta` to dominant-class `top.delta` so the firing axis matches the bracketed axis. Multi-class growth (≥2 watchlist classes ascending) stays as a structural precondition. A balanced 25+25 multi-class workload no longer fires; a single 60-instance leak with any other grower still does.
- `MemoryPressureDetector.gcRateThresholdPerMin` default 30 → 60. Dart's `EventStreams.kGC` emits per young-gen scavenge; ~30/min is steady-state for a moderately allocating UI. Pre-v0.26.0 sensitivity available via `SleuthConfig(gcRateThresholdPerMin: 30)`.
- `StreamResourceCaptureScreen`: 1024 KB/sec byte pressure (256 KB × 4 Hz, 1024-entry rotating cap) reliably re-arms heap_growing inside scenario. Heap-growing readiness wait moved INSIDE scenario span (`markScenarioBegin → resetCaptureState` wipes the prior latch). Direct `flushStreamResourceEvaluation()` dropped — emissions route through `pollStreamResourceAllocationProfileNowWithCapture`. JSON post-process aligns `expectedMagnitude.observed` to detector-stamped `topGrowthDelta`.
- `'instances'` added to `ProfileCaptureSchema.approvedUnits`.

## 0.25.0 (BREAKING)

Multi-parent causal UI + removal of deprecated `rootCauseId` singular field.

**BREAKING** — `PerformanceIssue.rootCauseId` (deprecated since v0.24.2) and `effectiveRootCauseIds` getter removed. JSON `rootCauseId` key no longer read or emitted. Migration:
- `PerformanceIssue(rootCauseId: 'x')` → `rootCauseIds: ['x']` (also covers `copyWith`).
- `issue.rootCauseId` getter → `issue.rootCauseIds?.firstOrNull`.
- v0.24.x-or-earlier snapshots carrying only the singular key must re-export through v0.24.2 (singular → plural coercion) before importing on v0.25.0+. Debug builds emit a warning when fromJson sees the legacy key without the plural.

UI:
- `IssueCard.parentIssues` + `_causedBySection` widget (mirrors `_downstreamSection`; cap at 5 + "and N more"; "(+N suppressed)" annotation when resolved parents < `rootCauseIds.length`).
- `computeVisibleIssues`: ≥2 parents always visible (multi-parent badge); 1 parent collapses under visible parent or surfaces as orphan; 0 parents visible.
- `FloatingIssuesCard`: resolves `parentIssues` via `stableIdToIssue` map; counts unresolved parents.
- `AiContextBuilder` reads `rootCauseIds` directly.

Contract:
- `rootCauseIds` documented invariant: null or non-empty. `fromJson` coerces empty/all-non-string lists to null.
- `_resortRootCauseIdsByCurrentSeverity` keeps `rootCauseIds[0]` highest-severity post-escalation so the "Caused by" badge and AI-prompt cap-at-5 truncation stay accurate.

Tests: +9 (5 `_causedBySection` render + 4 fromJson normalization). Visibility-filter triad updated. ~10 sites migrated singular→plural; singular-only regression tests removed (now compile errors).

## 0.24.2

Multi-parent causal-graph annotation (metadata layer). `CausalGraphRule.apply` now claims every reaching root for each downstream effect, removing the v0.24.1 export-vs-UI asymmetry at the data model layer. Top-level UI rendering of multi-parent badges is deferred to v0.25.0+ — the visibility filter still collapses each downstream under any visible reaching root.

- `PerformanceIssue.rootCauseIds: List<String>?` (plural) joins the schema; singular `rootCauseId` is `@Deprecated` and removed in v0.25.0. Constructor accepts both for back-compat. `fromJson` reads `rootCauseIds` if present, falls back to a singleton-list coercion of `rootCauseId` for v0.24.1-and-earlier snapshots. `toJson` derives singular from `rootCauseIds.first` (post-v0.24.2 canonical) so v0.24.1 readers see the highest-severity root after re-export — eliminates singular/plural drift.
- `CausalGraphRule.apply()`: `downstreamOwners` is now `Map<int, Set<int>>` (multi-parent) instead of `Map<int, int>` (single-owner). BFS from each root accumulates every reach. Each downstream issue carries every reaching root, sorted severity desc then stableId asc. Confidence suppression skips the root's `downstreamIds` listing for a `possible` downstream when any reaching root is `confirmed` or `likely`. Intermediate nodes in multi-hop chains are not surfaced as parents — only originating roots are (matches BFS-from-roots model; surfacing intermediates ships in v0.25.0+).
- `FloatingIssuesCard`: precomputed `stableIdToIssue` map (O(1) downstream lookup, drops itemBuilder cost from O(n²) to O(n)). `computeVisibleIssues` filter extended for multi-parent semantics: a downstream is hidden from top-level when any reaching root is visible; surfaces standalone only when every parent is suppressed.
- `AiContextBuilder`: prompt section uses singular "Root cause issue" / plural "Root cause issues" label depending on `rootCauseIds.length`; caps the joined list at 5 with `(+N more)` suffix.
- Tests: +5 (multi-parent 3×3 fan-in pin, rule-ordering invariant under input-shuffle, multi-parent confidence suppression, full-pipeline integration via correlator, multi-parent visibility-filter triad). ~70 existing assertions migrated from `.rootCauseId` → `.rootCauseIds`.

## 0.24.1

Cross-detector polish for `stream_resource_growth`.

- `CausalGraphRule`: 3 new edges so retained-stream emissions surface as causes of co-firing memory issues. `stream_resource_growth → heap_growing`, `stream_resource_growth → heap_near_capacity`, `stream_resource_growth → gc_pressure`. Mirrors the `uncached_images` and `excessive_keep_alive:*` patterns.
- Edge enumeration is asymmetric across consumers: `CausalGraphRule.activeEdges` (Markdown export, session summaries) returns every distinct cause→effect pair, so a 3-cause × 3-effect memory co-fire surfaces all 9 edges. `CausalGraphRule.apply` (UI annotation) remains single-owner — each downstream gets one `rootCauseId` chosen by severity-then-index, and losing roots render as standalone cards. Multi-parent UI rendering is deferred to a future cut.
- Schema regression guard: `ProfileCaptureSchema.parseFile` round-trip test for the 4 detector-side `extraTraceArgs` keys (`topGrowthClass`, `topGrowthDelta`, `watchlistClassesGrowing`, `samplesInWindow`) so a future schema tightening with a key allowlist cannot silently disable the detector's trace args.
- Tests: +6 (4 `activeEdges` edge tests + 1 negative control, 1 `apply()` single-owner pin for the 3-cause memory fan-in, 1 schema round-trip).

## 0.24.0

New `StreamResourceDetector` (vmOnly) flags likely retained async resources via `getAllocationProfile` class-instance diff, gated on a recent `MemoryPressureDetector.heap_growing` emission. 18 → 19 detectors.

- `StreamResourceDetector`: polls allocation profile at most once per `streamResourceSampleSeconds` (default 10s); tracks `instancesCurrent` for a hardcoded watchlist of dart:async / dart:io / web_socket_channel suffixes (`StreamSubscription`, `_BroadcastSubscription`, `_ControllerSubscription`, `StreamController`, `_SyncBroadcastStreamController`, `_AsyncBroadcastStreamController`, `_WebSocketImpl`, `WebSocketChannel`) plus rxdart `PublishSubject` / `BehaviorSubject` / `ReplaySubject` when `classRef.library.uri` contains rxdart. Emits `stream_resource_growth.warning` only when (a) `MemoryPressureDetector.isHeapGrowingActive` returns true within the recency window (default 30s), (b) ≥2 watchlist classes show ≥3 of 3 ascending transitions across a K=4 sample window, (c) sum of per-class net deltas exceeds `streamResourceMinDelta` (default 50). Confidence `likely`. Tier `reproducerOnly`.
- Suffix-match (`endsWith`) shields against private-class renames across Flutter SDK versions. 20s warmup window suppresses cold-start subscription accumulation; window/warmup re-engage on `pause()` / `resume()` / `resetCaptureState()`. Re-entrancy guard (`_pollInFlight`) + 3-failure backoff (60s default). 3-cycle cooldown holds `dedupIdentityMicros` stable so the controller dedup composite key collapses successive fires to one trace record.
- `MemoryPressureDetector`: new public `bool isHeapGrowingActive([int? windowMicros])` getter backed by `_lastHeapGrowingEmittedAtMicros` stamp. Decoupled from `_issues.any(...)` retention so a long-resolved heap_growing cannot latch downstream gating. Cleared on `vmConnected=false` / `reset()` / `dispose()`.
- `Sleuth.streamResourceDetector` static accessor (kReleaseMode-guarded). `StreamResourceDetector` exported from the public barrel.
- 5 new `DetectorThresholds` fields: `streamResourceSampleSeconds`, `streamResourceMinDelta`, `streamResourceWarmupSeconds`, `streamResourceHeapGrowingRecencyMicros`, `streamResourcePollFailureBackoffSeconds`.
- New `FixHintBuilder.streamResourceGrowth` cross-references `heap_growing` / `native_memory_growing` as alternative memory-pressure causes.
- IssueEncyclopediaPage entry for `stream_resource_growth` in `issue_explanation_builder.dart`.
- Library-URI gate on core watchlist: `endsWith` matches only fire when `classRef.library.uri` is `dart:async`, `package:web_socket_channel`, or (for WebSocket only) `dart:io`. dart:io's `_HttpClientStreamSubscription` is explicitly excluded — it self-cancels on response completion and would otherwise produce false positives on every network-heavy app.
- Cooldown semantics: wall-clock deadline (`cooldownSeconds`, default 30 s) — survives VmService disconnect mid-cooldown without leaving a stale issue pinned to `_issues` until the next non-null poll arrives. Re-emit during cooldown refreshes `detectedAt` (so UI does not show a stale stamp) while preserving `dedupIdentityMicros` for controller composite-key dedup.
- Reset-generation guard: in-flight `_pollAllocationProfile` snapshots `_resetGeneration` at start; if `_clearRetainedState` runs between the `await` and the result handler, the result is discarded. Without this, leg-N-1 sample data could write into leg-N's freshly-cleared `_perClassWindow` and break capture-mode scenario isolation.
- `windowSize` constructor assertion: `assert(windowSize >= 2)` rules out the empty-list `RangeError` path in `_evaluateWindow` if a future caller passes 0 or 1.
- `_ingestProfile` per-poll aggregation: sums `instancesCurrent` across every class that maps to the same suffix bucket and appends exactly one sample per suffix per poll. For suffixes previously seen but absent from the current poll (the leak was fixed and GC reclaimed every instance), appends `0` so a stale ascending window ages out instead of re-firing every cooldown cycle. All-zero windows are dropped to bound map growth.
- `_matchWatchlist` longest-suffix-match: a class named `_SyncBroadcastStreamController` matches the specific suffix instead of being shadowed by the generic `StreamController` bucket. First-match would also collapse multiple distinct controller flavors into one window, corrupting the ascending-transitions check.
- `_dropEmissionState` helper consolidates clears across cooldown lapse + transient gate failure + window underflow paths, eliminating drift between code paths that previously cleared a subset of emission fields.
- `@visibleForTesting` annotation on `allocationProfileFetcherForTest` constructor parameter so production callers cannot inject a custom fetcher.
- Tests: +17 unit (warmup, sample-rate gate, single-class-no-emit, heap_growing-off-no-emit, sub-threshold-no-emit, co-fire emission, extraTraceArgs key set, cooldown stable identity within window, cooldown detectedAt refresh, wall-clock cooldown expiry, non-monotone-no-emit, null-fetcher backoff, rxdart library-URI gate × 2, `_HttpClientStreamSubscription` exclusion, resetCaptureState, disabled, vmConnected-false). +5 reproducer (deliberate-leak harness, heap_growing-off, flat-no-emit, rxdart, cooldown).

## 0.23.0

`GpuPressureDetector.raster_dominance` idle false-positive fixed; `HeavyComputeDetector` issues persist past one VM batch.

- `GpuPressureDetector`: ratio numerator uses MAX-of-frame raster gated by `maxFrameRasterFloorUs` (default 8000us). New ctor param tunable for 120Hz / Impeller / low-power-mode.
- `RenderPipelineAnalyzer`: raster admitted as `suspectedPhase` only when one frame crosses 8000us.
- `HeavyComputeDetector`: emissions persist `emissionPersistence` (default 10s) via monotonic `Stopwatch` — survives VM poll cadence + system clock jumps. Retained state clears on `isEnabled=false` / `vmConnected=false`.
- `PerformanceIssue.sourceRoute`: detectors that retain issues stamp the route at emission. Aggregator prefers `sourceRoute` over live route, so post-emission navigation cannot reattribute. Wired through `HeavyComputeDetector` + `PlatformChannelDetector` via `sourceRouteProvider`.
- CSV Import demo row choices `[50K, 200K, 500K]` + post-parse sort. 500K cap avoids OOM / iOS watchdog.
- Tests: +5 gpu_pressure (idle-suppression, floor-triad, spike+idle, 12ms critical); +7 persistence (heavy_compute Stopwatch TTL × 3, lifecycle clear × 2, route-during-TTL × 2; platform_channel route-during-cooldown × 2).
- Doc cleanup: 21 historical spec files + `HANDOFF.md` removed; example/README aligned with 18-detector + 500K demo cap; README logo path switched to relative (`doc/logo.png`) for pub.dev rendering against private repo. Added Fastlane `TRACK_WIDGET_CREATION` patch tip for iOS profile archives. README accuracy fixes: Repaint detector moved from VM-Only to Hybrid section (matches `DetectorLifecycle.hybrid`); `heavyComputeGapMs` config example corrected to 8 (was drift-stamped 200). Pubspec description sharpened — leads with in-app overlay differentiator, drops abstract layer names.
- `doc/validation_ledger.md` Non-Detector Components: dropped stale v0.16.7 promise; framework live, 0 components registered; tier raises deferred to next non-detector formula change (4 candidates listed: `IssueRanker`, `RouteSession.healthScore`, `RecurrenceTrend`, FPS formulas).
- Reference-device matrix slimmed to **iPhone 12 / iOS 17.5 only** (`approvedDevicePairs`). iPhone 13 mini + Pixel 7 removed — never used by real captures (only synthetic fixtures, swapped). Anchor fixture re-pinned (SHA-256 updated). Android coverage gap explicitly documented in `doc/reference_devices.md`. 5 device-mismatch tests skipped pending second approved device pair. `doc/validation_matrix.md` + `doc/capture_procedure.md` + `example/lib/custom_detectors/README.md` swept for stale 23-detector / iPhone 13 mini / Pixel 7 references.

2,883 tests; `fvm flutter analyze` clean.

## 0.22.0

`sustained_jank.critical` runtimeVerified raise withdrawn. Bracket axis (sliding 240-frame-window severeCount) cannot composably bracket against operator-claimed K — ambient severe frames accumulate in the same window. Future raise needs detector-level baseline subtraction (`RebuildDetector.setBaseline(int)` pattern).

- Removed: 3 `sustained_jank` capture JSONs, `frame_timing_sustained_jank_capture_screen.dart`, example-app tile, retainedOrphans manifest entries.
- Reproducer-tier coverage of `sustained_jank` retained in `test/validation/frame_timing_reproducer_test.dart`.
- Distribution unchanged (12 family-severity pairs across 9 stableIds).
- README distribution paragraph + frame_timing_detector source comment refreshed to current state.

## 0.21.0

`RepaintDetector.excessive_repaint.warning` raised to runtimeVerified via `perStableIdTier` on three iPhone 12 / iOS 17.5 / Flutter 3.41.4 captures. Base tier stays `reproducerOnly`; `excessive_repaint_debug` and parametric `repaint_debug_<typeName>` are not over-claimed.

- Capture-mode plumbing: `lastObservedPaintCount` + `peakObservedPaintCount` getters, `flushPaintEvaluation()` (refreshes only `lastObservedPaintCount`; never updates peak so the exported magnitude always matches an emitted `observedPaintCount` arg), `resetCaptureState()` (per-leg accumulator clear, also called from `SleuthController.resetCaptureState` for cross-detector parity). VM emission stamps `extraTraceArgs.observedPaintCount` + `dedupIdentityMicros`.
- Bracket: `threshold: 30 paints`, `bracketAtTolerance: 0.50` (at-band [30, 45]), `aboveCeilingMultiplier: 2.0` (above-band ceiling 60 sits strictly under the `> 60` critical-tier fire boundary). Capture screen mounts 32 distinct `CustomPaint` widget classes so the per-widget debug gate stays sub-threshold and emission flows through the VM aggregate path.
- `Sleuth.repaintDetector` static getter (capture-screen access). `Sleuth.lastCaptureExportFailure` surfaces the most-recent `exportCaptureJson` null-return reason in-app.
- 12 effective runtimeVerified family-severity pairs across 9 unique stableIds. Base distribution unchanged (16/18 reproducerOnly, 2/18 runtimeVerified).

2,870 tests passing; `fvm flutter analyze` clean.

## 0.20.2

Example-app polish. No detector logic, public API, or schema change.

- `example/lib/main.dart` tile subtitles trimmed to ≤40 chars so 360 dp phones render single-line without ellipsis. Combined-chat tile keeps `SetState` (drops `Image`) to advertise actual detector coverage.
- `example/lib/demos/heavy_compute_demo.dart` description drops the hard "300 ms" claim → "complete in under a few hundred ms on modern devices" so CPU-throttled devices don't break the promise.
- `example/lib/demos/network_stress_demo.dart` search builds URL via `Uri.parse(...).replace(queryParameters: {'q': query})` — RFC 3986 percent-encoding for special chars (`+`, `&`, `=`, `#`, unicode).

2,862 unit + integration tests passing; `fvm flutter analyze` clean.

## 0.20.1

`FrameTimingDetector` and `RebuildDetector` stamp `extraTraceArgs.lifecyclePhase: 'startup' | 'steady'` on each emission. README + dartdoc gain a "Measurement window" note: Sleuth reports frame total duration from `FrameTiming` (build-to-raster span), not vsync delivery cadence.

- New `DetectorThresholds.startupPhaseWindowSeconds` (default 5). Classification reads `Timeline.now` at emission time — emission-time semantics, not event-time. A startup-phase frame whose callback delivery is delayed past the window boundary tags `'steady'`. Differs from `ShaderJankDetector.shaderWarmupContext` (per-event timestamp); the two tags are related but not aligned at the boundary.
- Buffer-aggregated emissions (`sustained_jank` 60-frame, `rebuild_activity` 1-second, raster-cache 30+ frames) tag from emission-time `Timeline.now`. A buffer straddling the boundary tags `'steady'` once `Timeline.now` exceeds the threshold.
- Null `Sleuth.dartEntryMonotonicUs` (init not called) or negative delta omits the key rather than fabricating a value.
- `rebuild_activity` runtimeVerified bracket axis (`observedRebuildRate`) co-exists with the new key. Audit-gate `validateBracket` reads named keys directly; multi-key emissions remain extractable.
- The tag is observable in capture-mode trace records and audit-gate replay; not serialized into saved JSON snapshots.
- Both detectors expose `appStartMonotonicUsForTest` constructor parameter for deterministic tests.

2,862 unit + integration tests passing; `fvm flutter analyze` clean. No detector logic, public API, or schema-version change.

## 0.20.0

**BREAKING**: 5 low-value detectors removed. Distribution: 23 → 18 detectors.

### Removed

- `DetectorType.animatedBuilder` — subset of `rebuild_detector` (AnimatedBuilder misuse manifests as rebuild storms; covered upstream).
- `DetectorType.opacity` — symptom-of-symptom (`Opacity` → `saveLayer` → jank already caught by `frame_timing.jank_detected`).
- `DetectorType.shallowRebuildRisk` — predictive heuristic; real signal caught by `rebuild_detector` from VM-timeline evidence.
- `DetectorType.nestedScroll` — Flutter's own `Vertical viewport was given unbounded height` diagnostic is more authoritative.
- `DetectorType.globalKey` — correctness lint, not perf; framework throws on duplicate `GlobalKey`.

Orphaned config fields removed: `SleuthConfig.maxGlobalKeys`, `DetectorThresholds.shallowRebuildMaxDepth`, `DetectorThresholds.animatedBuilderMinSubtreeSize`.

### Migration

Drop the 5 removed `DetectorType` references from `enabledDetectors`. `rebuild_detector` + `frame_timing` still surface AnimatedBuilder, opacity-jank, and rebuild-storm patterns from runtime evidence.

```dart
// BEFORE (v0.19.x):
SleuthConfig(enabledDetectors: {
  DetectorType.opacity, DetectorType.rebuild, DetectorType.frameTiming,
});

// AFTER (v0.20.0):
SleuthConfig(enabledDetectors: {
  DetectorType.rebuild, DetectorType.frameTiming,
});
```

v0.19 snapshots remain readable in v0.20 — serialization is `stableId`-keyed; encyclopedia + causal-graph rules retain removed-stableId entries for replay context. Users pinned at `^0.19.x` will not auto-upgrade.

### Distribution

16/18 reproducerOnly base + 2/18 runtimeVerified base. 11 effective runtimeVerified family-severity pairs across 8 unique stableIds (unchanged — none of the 5 removed carried raises).

2,851 unit + integration tests passing; `fvm flutter analyze` clean. Benchmark thresholds in `test/benchmark/` are machine-load-sensitive and may flake on slower hardware.


---

Releases prior to v0.20.0 are archived in [`CHANGELOG.archive.md`](https://github.com/Harrys76/sleuth/blob/main/CHANGELOG.archive.md).
