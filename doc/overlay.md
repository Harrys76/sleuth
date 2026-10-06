# Using the overlay

Tap the trigger button to open the dashboard. Each issue is a card: tap it to expand the detail, fix hint, causes and "About this detection" section. Drag the trigger to either screen edge; drag the card header to move the card and the corner grip to resize it.

## The FPS number

Sleuth reports two frame-rate metrics:

- **Actual FPS** is the number of frames presented in the last second, counted from `FrameTiming.rasterFinish` timestamps in a rolling window. It is what the device drew.
- **Throughput FPS** is a capacity estimate from the average frame duration (`1e6 / avg(frame_duration_us)`). It is what the engine could produce at the current per-frame cost.

The overlay shows **Throughput FPS** as the main number, coloured against `fpsTarget`. Idle screens read as smooth because Flutter repaints only on change; Actual FPS would drop to a few frames per second on a static screen even though rendering is healthy. Tap the info icon to show both metrics side by side (ACTUAL and TPUT). Session exports (`SessionSnapshot` schema v5) carry both metrics plus `actualFpsRaw`, the device rate capped at 240 Hz. It matters on 120 Hz ProMotion hardware, where the overlay clamps to `fpsTarget`.

Jank thresholds follow the frame rate the app actually renders at. Sleuth measures the vsync cadence from the fastest recent frames and uses it as the budget, bounded below by `fpsTarget` and above by the display's reported refresh rate. Sleuth judges a 120 Hz device rendering at 120 against 8.33 ms, and a ProMotion device rendering at 60 keeps 16.67 ms. iOS reports 120 Hz for ProMotion panels even while the app renders at 60, so the display rate alone never tightens the budget. When the budget tightens, the raster-dominance floor and the default heavy-compute threshold become half the budget. `fpsTarget` still caps the overlay FPS number and its colours. Set `autoFrameBudget: false` to always use `1000 / fpsTarget` ms; capture mode always does. `ext.sleuth.diagnose` reports `frameBudgetUs`, `effectiveFrameRateHz` and `frameRateSource`.

[Internals](internals.md#frame-budget) covers how the cadence is measured, and [FPS troubleshooting](internals.md#fps-troubleshooting) covers unexpected numbers.

## Filtering by severity

The counts in the summary bar are toggles. Tap one to show or hide that severity; at least one stays on. "Showing X of Y" appears when the list shows fewer cards than it would with every severity on and nothing hidden. The filter is saved with the rest of the overlay state.

## Hiding cards

To move a card out of the way only while you work, expand it and tap **Hide**. The card leaves the overlay (with Undo for 4 s) and the footer shows `N hidden`; tap the footer to restore hidden cards (Restore all also offers Undo). A hide covers the card at the severity you hid it at, so a hidden warning shows again if the same card turns critical. Hiding affects only the overlay: `ext.sleuth.issues`, snapshots, MCP budgets, route sessions and recurrence still see the issue. To drop an issue everywhere, use [`suppressedIssues`](configuration.md#suppressing-issues).

Keep-alive issue ids name the scrollable (`excessive_keep_alive:PageView~1`, or `~k-feed` for a `ValueKey('feed')`). When the overlay state loads, it drops hides saved under the older positional ids (`excessive_keep_alive:3`).

## Card order

While the dashboard is open, the overlay holds the order of collapsed cards, so a card does not move under your finger. New issues enter at the top (below any expanded cards) with a wider accent for 2 s, a severity promotion moves a card up at once (never down), and other rank changes apply after 10 s of quiet while the list is scrolled to the top. Any touch, scroll or trackpad gesture on the list restarts the 10 s wait, and a list scrolled away from the top keeps the order until it is back at the top. Collapsing the last expanded card keeps the order on screen.

Under a screen reader, held cards do not move on their own. Opening the dashboard, changing the severity filter, and hiding or restoring a card are then the only points that show the ranker's order, as they are without a screen reader, and a new issue enters at its rank position instead of the top. Exports, `ext.sleuth.*` and MCP always use the ranker's order.

## System back and Escape

With the dashboard open, the system back gesture or button closes the innermost overlay layer before the app's own navigation sees it: first a focused text field, then a full-screen page (encyclopedia, guide, AI chat, Hidden list), then the dashboard. With the dashboard closed, back goes to the app unchanged. On Android, Sleuth claims predictive back swipes while a layer is open, also after the app navigates underneath it (for example back to its root route). On Flutter versions that offer the swipe to every listener, an app route that can pop may pop as well. After the dashboard closes at the app's root route, Android's back-to-home preview returns once the app navigates; back itself still leaves the app.

On a hardware keyboard, Escape first unfocuses a focused overlay text field, then closes the open page, then the dashboard. A focused text field or an open dialog or sheet in your app keeps its Escape.

## Theme and accessibility

The header toggle cycles the overlay theme through System, Light and Dark. [Configuration](configuration.md#overlay-theming) covers custom themes and how they combine with the toggle. [Overlay accessibility](accessibility.md) covers screen readers, text size, touch targets, contrast and reduced motion.
