# Design reference

The reference image was generated with the built-in image-generation tool before UI implementation. It guides hierarchy and material tone; it is not used as a raster interface. Real controls remain native SwiftUI/AppKit with SF Symbols and accessible labels.

Saved asset: `docs/images/design-reference.png`.

Final prompt:

> Use case: ui-mockup
> Asset type: design reference for a real native macOS utility called NoSleep.
> Create one high-fidelity desktop app design mockup, a single compact window roughly 520 by 680 logical pixels on a simple neutral background. NoSleep keeps the Mac awake even with lid closed and independently turns off or locks its display. Style: carefully designed physical instrument panel translated into native macOS software; warm off-white surface, graphite typography, fine separators, restrained green status indicator, a very slight tactile quality. Avoid AI dashboard look, gradients, purple, huge rounded cards, illustrations, charts, decorative metrics, excessive shadows. Crisp typography and coherent spacious alignment. Standard small macOS traffic lights and title NoSleep at top. Header subtitle 'Power, under control.' Then a dominant status area with an understated green dot, heading 'Keep Mac awake', line 'On · Display can still sleep', and a large simple green toggle aligned right. A slim inset area explains 'Close the lid. Keep things running.' and 'Your display turns off. Your work continues.' with a small simple laptop outline. Below one hairline divider place two equally readable action buttons stacked: 'Turn display off' and 'Lock & turn display off', with simple monitor and lock glyphs. Bottom compact settings rows: 'When lid closes' value 'Lock & turn display off'; 'Launch at login' small toggle; 'Language' segmented English / 한국어. Footnote 'Sleep prevention stays on when you quit.' Clear visual hierarchy, real usable native macOS controls, no marketing landing page sections. Render readable English UI text. No branding beyond NoSleep.

The implementation adapts this into a compact, scrollable window, uses state-dependent explanatory copy, and keeps permissions and diagnostics secondary. The primary action is sleep prevention; the display actions form a separate pair. The login and lid settings reflect actual available services rather than a decorative mock state.
