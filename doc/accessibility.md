# Overlay accessibility

The overlay is a developer tool drawn over a live app, and it works with the platform's accessibility settings turned on.

## Screen readers

Every control has a label. An issue card is one button named by its title (double tap expands it; long press or the Copy details action copies it; the screen reader announces the expanded state).

While a full-screen page is open, it announces its name, hides the app below it from the screen reader, and takes keyboard focus from the app (typing, Tab, Enter and Space no longer reach it); the app gets focus back when the page closes. The floating card leaves the app reachable. Closing a page returns the list to where it was and moves screen-reader focus back to the card that opened it.

Dragging has alternatives: the card header offers Move up / down / left / right and Move to top left, the resize grip offers Taller / Shorter / Wider / Narrower (48 px steps, normal window state only), and the trigger offers Move to left edge / right edge. The header and grip read the card size back, and the header also reads its position.

Toasts are live regions and stay three times longer while a screen reader or other assistive service is on, and a toast with an action (Undo) then stays until it is used or dismissed. The trigger reads how many issues are critical. AI chat announces Thinking and each reply.

## Text size

Overlay text follows the system setting between 0.8× and 2.0×; the app below keeps its own scale. The chrome (card header, status row, summary bar, footer, badges, trigger) stops growing at 1.3× so the issue list stays visible; above that, issue titles take two lines and detail text wraps.

Fixed heights grow with the chrome but never past the screen (on a landscape phone, for example), and the status row and banners scroll when they would squeeze the list. Moving or resizing the card, by touch or with a screen-reader action, keeps the whole card on screen above the keyboard. In AI chat the issue context gives way to the input and Send button when the keyboard is up. A card resized under large text returns to its own height at 1.0×. The smallest text is 10 px.

## Touch targets

Controls are at least 48 × 48 dp. The card header's compact controls (highlight, theme, minimize, maximize, restore) are 36 × 48 so that they fit the default 300 dp card, which is above the WCAG 2.5.8 minimum of 24 dp. Below 280 dp the minimize and maximize controls are hidden. Close is 48 × 48.

## Contrast

Text tokens meet WCAG AA (4.5:1) on every overlay surface in the dark, light and high-contrast themes. Badges draw primary text on a light tint of their colour, with a 1 px border in that colour.

## High contrast

`SleuthThemeData.highContrastDark()` and `highContrastLight()` raise secondary text, strengthen borders, make badge fills opaque and widen the source accent. Sleuth picks them when `MediaQuery.highContrastOf` is true (reported on iOS) and no theme is set, and for the toggle's Light or Dark. On other platforms, pass one to `Sleuth.updateTheme`. State cues (chip borders, chevrons, the pin) stay at full opacity.

## Reduced motion

Sleuth honours both the Android animator duration scale (`disableAnimations`) and iOS Reduce Motion (`AccessibilityFeatures.reduceMotion`). Page entrances, expand and collapse, scrolls to an entry, the toast fade, severity chips and the rebuild count change at once, and the Ask AI shimmer stops. An animation that is already running when the setting changes finishes at its old speed.

## Keyboard

Escape first unfocuses a focused overlay text field, then closes the open page, then the dashboard. A focused text field or an open dialog or sheet in your app keeps its Escape.
