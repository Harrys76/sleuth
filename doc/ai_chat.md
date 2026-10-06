# AI chat

Tap "Ask AI" on any issue card to open a chat about that issue. The package builds the system prompt from the issue's metrics, its encyclopedia entry and the causal graph; your AI provider only needs to stream a response. The README shows how to configure an adapter. The built-in adapters exclude their provider URLs from network monitoring. When no adapter is configured, the "Ask AI" link is hidden.

## Replies

While a reply is arriving, the send button becomes Stop. The input stays editable so you can draft the next question, and sending it shows a notice with Stop. Stop keeps the text received so far, marked "(stopped)", and so does closing the chat mid-reply.

By default a reply times out after 30 s without a first token or 15 s between tokens; set `firstTokenTimeout` and `stallTimeout` on the adapter for slow local or reasoning models (null turns a timeout off). After 5 s the chat shows "Still waiting for a reply".

A failed reply shows a short reason with **Retry** and **Copy error**:

| Reason | Cause |
| --- | --- |
| API key rejected | HTTP 401 or 403 |
| Rate limited | HTTP 429 |
| Provider error | HTTP 5xx |
| Offline | The host lookup failed or the network is down |
| Can't reach the provider | Another connection error, such as a refused or reset connection |
| No reply in 30 s | The first-token timeout |
| Reply stalled | The stall timeout |
| Reply failed | Anything else, including a reply that ends without text |

The error text never enters the conversation, so it is not sent back to the provider. A question left unanswered shows "Reply did not finish" with Retry when the chat reopens. A question asked after an unanswered one keeps its own bubble, and the request joins the two into one user turn, so no provider receives two user turns in a row.

To report a failure from a custom adapter, throw from its stream. An error whose text reads `returned 429` or `status 429` gets the reason for that code (Sleuth maps 401, 403, 429 and 5xx), and a `SocketException` reads Offline or Can't reach the provider, depending on its cause. A custom adapter can also throw `AiProviderException(status)` to get the matching short reason.

## What is sent

The system prompt holds the issue (title, detail, fix hint, widget, route, ancestor chain, causes and effects), its encyclopedia entry, up to five other active issues by title, and a Session section. It never lists an issue you hid, and it names related issue ids only for issues it already lists.

The Session section has the current route (without query or fragment), the whole-app frame rate while the overlay is open, the first line of the latest frame verdict with its phase timings, active issue counts by severity, the number of reported issues you hid (not their titles), the build mode (debug or profile), the connection mode and the platform. A caption above the input summarises it (`Context: /home · 58 FPS · 12 issues`), and once a message has been sent, Copy conversation ends with the context sent.

Route names (without query or fragment), widget names and issue text go to your provider. If your route paths carry user data, use a custom adapter that redacts `request.systemPrompt`.
