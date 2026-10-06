# Launch posts for Sleuth and sleuth_mcp

Drafts for announcing the pub.dev release. Pick one per platform and adjust the voice.
The post bodies below are plain text. LinkedIn and Threads show `**`, `*` and backticks as typed, so the bodies leave them out. Copy each body as it is.

- Package: https://pub.dev/packages/sleuth
- Source: https://github.com/Harrys76/sleuth
- Attached image: the promo card (`~/Desktop/sleuth_promo.png`). Its headline "Ask your AI why your Flutter app is slow." sits over a terminal that shows the checkout-route example. The captions below go with the card without repeating its text.
- If you can, lead with a 15 to 25 s screen recording of a real conversation, and use the card as the static fallback or as a carousel slide.

---

## LinkedIn

### Primary (leads with MCP and adds to the card)

Debugging Flutter performance usually means stopping the app, opening DevTools, reconnecting and reading a flame chart. I wanted to ask a question instead.

So I built sleuth_mcp, an MCP sidecar that lets Claude Code, Cursor or Zed read a running app's live performance data during a conversation. You ask in plain language. The assistant attaches to the running app, reads its ranked issues and answers with the fix hint each issue carries. (The card shows an example exchange.)

The data comes from Sleuth, my in-app performance diagnostics overlay for Flutter. The overlay and the sidecar read the same detectors:

• In-app overlay, added with one line:
runApp(Sleuth.track(child: MyApp()));
20 detectors cover frame timing, memory, network and GPU, plus structural patterns DevTools does not flag (non-lazy lists, oversized images, missing RepaintBoundary). Every issue has a fix hint. Sleuth does nothing in release builds.

• MCP sidecar: your AI assistant reads the same issues.

Both are open source (MIT). Feedback and issues are welcome.

#Flutter #Dart #MCP #AI #DeveloperTools #PerformanceEngineering #OpenSource

### Shorter alt (opens with the question)

Ask your AI "why is this route janky?" and it reads your running Flutter app's live performance data to answer.

That is sleuth_mcp, an MCP sidecar that gives Claude Code, Cursor or Zed a running app's live issues (each with a fix hint), route health and snapshots.

The data comes from Sleuth, my in-app performance overlay (20 detectors, one line to add). Your editor's AI can now query it.

Open source, on pub.dev: https://pub.dev/packages/sleuth

#Flutter #Dart #MCP #OpenSource

---

## Threads

(Threads allows about 500 characters per post and also shows markdown as typed. These bodies are plain text and fit.)

### Primary (leads with MCP)

Flutter performance debugging usually means stopping the app, opening DevTools, reconnecting and reading a flame chart. I wanted to ask instead.

sleuth_mcp is an MCP sidecar that lets Claude Code or Cursor read a running app's live performance data in a chat: ranked issues, each with a fix hint. (The card shows an example run.)

The data comes from Sleuth, my in-app performance overlay. Open source.

pub.dev/packages/sleuth

#Flutter #Dart #MCP

### Casual alt

flutter performance debugging in 2026: tell your AI "this route feels janky" and it reads the running app's live data to answer, with fix hints.

that's sleuth_mcp, an MCP sidecar for Sleuth (my in-app performance overlay: 20 detectors, a fix hint on every issue, one line to add).

your editor's AI can now query the same detectors.

pub.dev/packages/sleuth

#Flutter #MCP

---

## Notes

- MCP is what sets Sleuth apart, so lead with it. Keep the overlay in every variant as the part that measures the app.
- The caption adds to the card. It does not restate the headline, the example prompt or the findings the image already shows. The image shows the demo, and the caption adds the reason, the overlay and the call to action. Use the card's term "MCP sidecar".
- Post bodies are plain text on purpose, with no `**bold**`, `*italics*` or backticks, because LinkedIn and Threads show them raw. Use line breaks, `•` bullets and quotes for emphasis.
- The findings on the card (CartTile 34×/s, CheckoutCubit +2.1 MB/s, /rates 1.8s) are illustrative. Replace them with a real `get_issues` capture if you want the card to be literal, and keep the card and the captions in sync. Sleuth 0.37 reports a profile build's rebuild cost as the share of UI-thread time spent building (`rebuild_activity`); a per-widget rate such as "34×/s" appears only in a debug build (`rebuild_debug_<Type>`).
- Hashtags: Threads supports them, but the custom there is one to three relevant tags rather than the LinkedIn block, and they count toward the 500-character limit. The drafts use #Flutter #Dart #MCP (primary) and #Flutter #MCP (casual). LinkedIn accepts the longer set.
- Publish state on 2026-10-06: pub.dev has sleuth 0.36.0 and sleuth_mcp 0.7.2. The posts describe 0.37.0 (oversized images), so publish sleuth 0.37.0 and sleuth_mcp 0.8.0 before they go out.
