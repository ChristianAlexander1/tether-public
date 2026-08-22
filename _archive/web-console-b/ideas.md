# TermX Console Design Direction

## Three initial approaches

### Theme Name: Carbon Terminal
Very Brief Intro: A dark, focused developer workspace built around near-black graphite, warm green phosphor, and deliberate terminal typography. It feels like a dependable instrument rather than a marketing site.
Probability: 0.07

### Theme Name: Paper Circuit
Very Brief Intro: A bright documentation-inspired interface with warm paper surfaces, ink-blue navigation, and precise utility accents. It makes complex runtime status feel calm, legible, and approachable.
Probability: 0.03

### Theme Name: Signal Room
Very Brief Intro: A cool, atmospheric command center with midnight blue surfaces, electric cyan highlights, and subtle glass layers. It is more cinematic and operational, designed for long sessions and high information density.
Probability: 0.08

## Selected approach: Carbon Terminal

### Design Movement
Neo-industrial software tooling with references to early workstation UIs, print-room labels, and contemporary editorial systems. The interface should feel assembled from durable controls, not decorative dashboard cards.

### Core Principles
1. **Instrument first:** Every surface should support a concrete terminal task or clarify system state.
2. **Layered graphite:** Use deep charcoal planes, hairline separators, and restrained shadows to create hierarchy without clutter.
3. **Human-readable density:** Pair monospace for commands and system output with a warm sans-serif for navigation and status labels.
4. **Visible trust:** Show workspace scope, runtime availability, and execution state explicitly so the user understands what is local and what is active.

### Color Philosophy
The base is a softened graphite-black rather than pure black to reduce fatigue during long sessions. A muted mineral green is the signature signal color, recalling a phosphor display without becoming retro cosplay. Amber marks attention and in-progress work; cool blue is reserved for links and secondary controls. Surfaces are separated by changes in luminance more than by heavy borders.

### Layout Paradigm
A persistent narrow rail establishes orientation. The main workspace is split into a compact context strip and a large terminal canvas, with a right-side inspection column that can collapse on smaller screens. The composition is intentionally asymmetrical: the terminal owns the visual center while runtime and workspace context sit at the edges.

### Signature Elements
- A small square TermX mark made from two offset command-prompt chevrons, used in the rail and browser icon.
- Thin vertical status bars that pulse subtly when a runtime is active.
- Command-line breadcrumbs and compact uppercase labels with generous tracking.

### Interaction Philosophy
Interactions should feel immediate and physical. Buttons compress slightly on press, focused controls gain a clear mineral-green ring, and panels appear by sliding a short distance rather than scaling from nothing. High-frequency terminal interactions remain instant; only panel transitions and status changes receive motion.

### Animation
Use 150–220ms ease-out transitions for hover, selection, and panel entry. New terminal output should fade in at line level only when a command completes, never with a distracting cascade while streaming. Active runtime bars can breathe slowly, but motion must stop under prefers-reduced-motion.

### Typography System
Use Space Grotesk for navigation, headings, and system labels; use JetBrains Mono for terminal output, command prompts, path breadcrumbs, and metrics. Headings use tight tracking and medium-to-bold weights. Labels are uppercase at 10–11px with 0.14em tracking. Terminal text stays at 13–14px with generous line-height.

### Brand Essence
TermX is a local-first developer terminal for people who want a real Unix workspace inside a focused, native-feeling environment. Personality: **capable, grounded, exacting**.

### Brand Voice
Headlines are concise and operational. CTAs describe the action and its scope rather than using generic activation language. Microcopy states what is happening now and what the user can trust.

Example lines:
- “Your workspace, with a real shell underneath.”
- “Run locally · scoped to /workspaces/demo-app”

### Wordmark & Logo
The mark is a compact square containing two offset chevrons that imply a prompt and a forward command. The wordmark uses a custom all-caps “TERM//X” lockup with the second slash slightly raised, suggesting a command separator.

### Signature Brand Color
**Mineral Green — #A8D36B**, a soft phosphor-inspired green that is ownable, readable on graphite, and distinct from generic neon terminal lime.

## Style Decisions
- Use asymmetrical workbench composition instead of a centered landing-page layout.
- Keep the mineral-green accent restrained: active states, command prompt, and successful runtime indicators only.
- Use warm graphite surfaces and typography contrast to make long-session use feel calm.
