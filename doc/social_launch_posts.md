# Launch posts — Sleuth + sleuth_mcp

Drafts for announcing the pub.dev release. Pick one per platform, tweak voice to taste.
Post bodies below are PLAIN TEXT (no markdown) — LinkedIn and Threads render `**`, `*`, and backticks literally, so they're stripped. Copy the body as-is.

- Package: https://pub.dev/packages/sleuth
- Source: https://github.com/Harrys76/sleuth
- Attached image: the promo card (`~/Desktop/sleuth_promo.png`) — headline "Ask your AI why your Flutter app is slow." over a terminal showing the checkout-route example. The copy below mirrors it so caption + visual reinforce each other.
- If you can, lead with a 15–25s screen-rec of the actual conversation instead; use the card as the static fallback / carousel slide.

---

## LinkedIn

### Primary (MCP-led — complements the card, doesn't restate it)

Most Flutter perf debugging is a context-switch tax: stop the app, open DevTools, reconnect, read a flame chart. I wanted to skip all of it and just ask.

So I shipped sleuth_mcp — an MCP sidecar that lets Claude Code, Cursor, or Zed read a running app's live performance data mid-conversation. Ask in plain language; it attaches to the live session, queries it, and answers with ranked issues and a fix hint on each. (The card is a real exchange.)

It's powered by Sleuth, my in-app performance diagnostics overlay for Flutter. Same engine, two front-ends:

• In-app overlay — always on, one line to install:
runApp(Sleuth.track(child: MyApp()));
20 detectors across frame timing, memory, network, GPU, plus structural anti-patterns DevTools won't flag (non-lazy lists, uncached images, missing RepaintBoundary). A fix hint on every issue. Disabled in release.

• MCP sidecar — that same signal, in your AI assistant's hands.

Both open source (MIT). Feedback and issues welcome.

#Flutter #Dart #MCP #AI #DeveloperTools #PerformanceEngineering #OpenSource

### Shorter alt (hook-first)

Ask your AI "why is this route janky?" — and have it read your running Flutter app's live perf data to answer.

That's sleuth_mcp: an MCP sidecar that hands Claude Code / Cursor / Zed live issues, route health, and snapshots from a running app — each with a fix hint.

It's powered by Sleuth, my always-on in-app perf overlay (20 detectors, one line to add). Same engine, now driveable from your editor's AI.

Open source, on pub.dev: https://pub.dev/packages/sleuth

#Flutter #Dart #MCP #OpenSource

---

## Threads

(Threads caps at ~500 chars; also renders markdown literally — these are plain text and fit.)

### Primary (MCP-led)

Flutter perf debugging, usually: stop app, open DevTools, reconnect, read a flame chart. I wanted to just ask.

sleuth_mcp is an MCP sidecar that lets Claude Code / Cursor read a running app's live perf data mid-chat — ranked issues, each with a fix hint. (Card shows a real run.)

Powered by Sleuth, my always-on in-app perf overlay. Open source.

pub.dev/packages/sleuth

#Flutter #Dart #MCP

### Casual alt

flutter perf debugging, 2026: tell your AI "this route feels janky" and it reads the running app's live data to answer — with fix hints.

that's sleuth_mcp, an MCP sidecar for Sleuth (my in-app perf overlay: 20 detectors, fix hint on every issue, one line to add).

same engine, now in your editor's AI.

pub.dev/packages/sleuth

#Flutter #MCP

---

## Notes

- MCP is the differentiator — lead with it. The overlay is the foundation that makes the MCP signal trustworthy; keep it in every variant as the engine, not an afterthought.
- Caption COMPLEMENTS the card — it does NOT restate the headline, the example prompt, or the findings the image already shows. The image carries the demo; the caption adds the why + the overlay foundation + CTA. Keep the "MCP sidecar" term consistent with the card.
- Post bodies are plain text on purpose — no `**bold**`, `*italics*`, or backticks (LinkedIn/Threads show them raw). Emphasis via line breaks, `•` bullets, `→`, and quotes.
- The findings (CartTile 34×/s, CheckoutCubit +2.1 MB/s, /rates 1.8s) are illustrative — swap for a real get_issues capture if you want it literal (keep card + caption in sync).
- Hashtags: Threads supports them but the convention is sparse — 1–3 relevant tags, not the LinkedIn block (and they eat the ~500-char cap). Used #Flutter #Dart #MCP (primary) / #Flutter #MCP (casual). LinkedIn tolerates the fuller set.
- Publish gate: sleuth_mcp is not on pub.dev yet (and sleuth there is several versions behind). Publish both before these go out, or the "shipped sleuth_mcp" claim has nothing to install.
