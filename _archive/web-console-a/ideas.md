# TermX Design Direction

## Three stylistic approaches

### Theme Name: Terminal Atelier
Very dark, editorial, tactile, and precise; a developer workspace that feels like a crafted instrument rather than a generic dashboard.
Probability: 0.04

### Theme Name: Paper Protocol
Light, archival, and documentation-led; a calm developer notebook with warm paper tones and restrained monospace accents.
Probability: 0.07

### Theme Name: Signal Garden
A bright, optimistic system of folders, command signals, and soft botanical color; approachable without becoming playful.
Probability: 0.03

## Chosen approach: Terminal Atelier

### Design Movement
Contemporary editorial software design with Swiss typographic structure, dark instrument-panel materials, and tactile print-like texture.

### Core Principles
1. Every surface should feel purposeful and tool-like, with strong hierarchy instead of decorative chrome.
2. Contrast is functional: warm ivory is for reading, chartreuse is for active state, coral is for attention.
3. Layouts should be asymmetric and spatial, with a persistent rail and a command canvas that owns the page.
4. Motion should communicate state changes, not entertain: fast, small, and physically plausible.

### Color Philosophy
TermX uses near-black graphite as the working surface so code and status remain legible for long sessions. Warm ivory softens the darkness and evokes paper documentation; chartreuse marks active execution and successful paths; coral is reserved for interrupts, warnings, and destructive intent. The signature accent is not a gradient but a signal color that behaves like a hardware indicator.

### Layout Paradigm
A persistent left rail anchors navigation while the main area is split into a command canvas and a narrow context column. On the launcher, an offset hero block and stacked workspace cards create a deliberate editorial rhythm instead of a centered marketing grid.

### Signature Elements
- The TermX mark: a terminal chevron fused with a folder tab.
- A thin chartreuse execution line that appears beside live sessions and active commands.
- Small uppercase section labels with generous tracking, like labels on a studio instrument.

### Interaction Philosophy
Actions should feel immediate and reversible. Workspace cards open with a crisp lift, tabs respond like physical labels, and command execution produces a visible state change in the prompt line. Keyboard-first behavior is implied throughout, with clear focus rings and shortcut hints.

### Animation
Use 160–220ms ease-out transitions for buttons, tabs, and cards. On first load, reveal the rail, hero copy, and workspace rows with 40ms staggered offsets. Avoid animating layout dimensions. The terminal cursor uses a restrained opacity pulse, and the running indicator uses a short horizontal shimmer only when a command is active. Respect reduced-motion preferences.

### Typography System
Use Space Grotesk for display and interface labels, with IBM Plex Mono for terminal content, paths, metadata, and keyboard hints. Headlines are compact and bold; body copy is relaxed and short. Uppercase labels use 0.14em tracking and never carry more than one line.

### Brand Essence
TermX is a local-first terminal workspace for developers who want real command-line power inside a focused, approachable interface. Personality: exacting, warm, quietly powerful.

### Brand Voice
Headlines are direct and confident. CTAs describe the action and the result rather than using generic activation language. Microcopy is concise, calm, and honest about what is local or still being prepared.

Example lines:
- “Your files. Your shell. One focused surface.”
- “Open a folder and make it executable.”

### Wordmark & Logo
The mark is a chevron prompt nested into a folder tab, with a small open notch that implies a cursor. The wordmark uses a custom-spaced “TermX” lockup in Space Grotesk with the X slightly offset upward like a command caret; the symbol is always able to stand alone.

### Signature Brand Color
Signal chartreuse: `#C6F36B` — bright enough to read against graphite, unusual enough to own, and emotionally associated with an active process rather than generic success.

## Style Decisions

- Use generated TermX mark and launcher artwork as the primary visual assets.
- Keep the default product view dark and instrument-like; do not introduce purple gradients.
- Treat coral as an interrupt/warning color only.
