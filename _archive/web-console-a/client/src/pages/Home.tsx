/* Terminal Atelier: the command canvas owns the page; ivory is for reading, chartreuse is active state, coral is interrupt-only. */
import { useEffect, useMemo, useState } from "react";
import { toast } from "sonner";
import {
  Apple,
  ArrowUpRight,
  ChevronRight,
  Command,
  FileCode2,
  Folder,
  FolderOpen,
  GitBranch,
  HardDrive,
  Keyboard,
  LayoutGrid,
  Menu,
  MoreHorizontal,
  PanelLeft,
  Play,
  Plus,
  Search,
  Settings2,
  ShieldCheck,
  Sparkles,
  TerminalSquare,
  X,
  Zap,
} from "lucide-react";

const workspaces = [
  { name: "termx-core", path: "~/workspaces/termx-core", files: "142 files", branch: "main", time: "2m ago", accent: "lime" },
  { name: "agent-lab", path: "~/workspaces/agent-lab", files: "38 files", branch: "feat/pty", time: "Yesterday", accent: "coral" },
  { name: "scratchpad", path: "~/workspaces/scratchpad", files: "9 files", branch: "main", time: "Aug 18", accent: "blue" },
];

const initialLines = [
  { kind: "muted", text: "Last login: Thu Aug 21 09:41:06 on ttys001" },
  { kind: "prompt", text: "~/workspaces/termx-core" },
  { kind: "output", text: "  ✓ workspace mounted with read / write access" },
  { kind: "output", text: "  ✓ TermXCore 0.4.2 · SwiftTerm 1.6.0" },
  { kind: "output", text: "  ↳ 142 files · git branch main · clean" },
  { kind: "blank", text: "" },
  { kind: "prompt", text: "~/workspaces/termx-core" },
  { kind: "command", text: "git status --short" },
  { kind: "output", text: "  (no changes)" },
  { kind: "blank", text: "" },
  { kind: "prompt", text: "~/workspaces/termx-core" },
];

type Workspace = (typeof workspaces)[number];

const commands = [
  { label: "ls", description: "List directory contents", icon: FolderOpen },
  { label: "git status", description: "Show workspace state", icon: GitBranch },
  { label: "python3", description: "Run a Python script", icon: FileCode2 },
  { label: "node", description: "Run a Node program", icon: Zap },
];

export default function Home() {
  const [activeTab, setActiveTab] = useState(() => localStorage.getItem("termx-active-tab") ?? "termx-core");
  const [lines, setLines] = useState(initialLines);
  const [input, setInput] = useState("");
  const [showSettings, setShowSettings] = useState(false);
  const [showLauncher, setShowLauncher] = useState(false);
  const [running, setRunning] = useState(false);
  const [mobileRail, setMobileRail] = useState(false);
  const [history, setHistory] = useState<string[]>(() => JSON.parse(localStorage.getItem("termx-history") ?? "[\"git status --short\"]"));
  const [historyIndex, setHistoryIndex] = useState(-1);
  const [paletteOpen, setPaletteOpen] = useState(false);
  const [paletteQuery, setPaletteQuery] = useState("");
  const [splitPane, setSplitPane] = useState(false);
  const [enabledRuntimes, setEnabledRuntimes] = useState({ python: true, node: true, linux: false });
  const [workspaceList, setWorkspaceList] = useState<Workspace[]>(() => JSON.parse(localStorage.getItem("termx-workspaces") ?? "null") ?? workspaces);
  const [newWorkspaceName, setNewWorkspaceName] = useState("");
  const [cwd, setCwd] = useState(() => localStorage.getItem("termx-cwd") ?? "~/workspaces/termx-core");
  const [showFiles, setShowFiles] = useState(false);
  const [filePreview, setFilePreview] = useState<string | null>(null);

  const currentWorkspace = useMemo(() => workspaceList.find((item) => item.name === activeTab) ?? workspaceList[0], [activeTab, workspaceList]);
  const filteredCommands = useMemo(() => commands.filter((command) => `${command.label} ${command.description}`.toLowerCase().includes(paletteQuery.toLowerCase())), [paletteQuery]);

  useEffect(() => {
    localStorage.setItem("termx-workspaces", JSON.stringify(workspaceList));
    localStorage.setItem("termx-history", JSON.stringify(history));
    localStorage.setItem("termx-active-tab", activeTab);
    localStorage.setItem("termx-cwd", cwd);
  }, [workspaceList, history, activeTab, cwd]);

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") { event.preventDefault(); setPaletteOpen(true); }
      if (event.key === "Escape") { setPaletteOpen(false); setShowLauncher(false); setShowSettings(false); }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, []);

  function runCommand(value = input) {
    const command = value.trim();
    if (!command) return;
    setRunning(true);
    setHistory((prev) => [command, ...prev.filter((item) => item !== command)].slice(0, 30));
    setHistoryIndex(-1);
    let output = `  running ${command} …`;
    if (command === "ls") output = "  App  Packages  Frameworks  NOTICES  docs";
    if (command === "pwd") output = `  /workspaces/${currentWorkspace.name}`;
    if (command === "whoami") output = "  alex";
    if (command === "git status") output = "  On branch main\n  nothing to commit, working tree clean";
    if (command === "git status --short") output = "  (no changes)";
    if (command === "clear") { setLines([{ kind: "prompt", text: cwd }]); setInput(""); setRunning(false); return; }
    if (command.startsWith("cd ")) { const next = command.slice(3).trim() || "~"; const resolved = next === ".." ? "~/workspaces" : next.startsWith("~") ? next : `${cwd}/${next}`; setCwd(resolved); output = `  changed directory to ${resolved}`; }
    setLines((prev) => [...prev, { kind: "command", text: command }, { kind: "output", text: output }, { kind: "prompt", text: cwd }]);
    setInput("");
    window.setTimeout(() => setRunning(false), 850);
  }

  function createWorkspace() {
    const name = newWorkspaceName.trim().replace(/\s+/g, "-").toLowerCase();
    if (!name) return;
    const next = { name, path: `~/workspaces/${name}`, files: "0 files", branch: "main", time: "Just now", accent: "lime" };
    setWorkspaceList((prev) => [...prev, next]);
    setNewWorkspaceName("");
    openWorkspace(name);
  }

  function openWorkspace(name: string) {
    setActiveTab(name);
    setCwd(`~/workspaces/${name}`);
    setShowLauncher(false);
    toast.success(`${name} mounted`, { description: "Read / write access is active for this session." });
  }

  return (
    <div className="termx-app">
      <aside className={`termx-rail ${mobileRail ? "rail-open" : ""}`}>
        <div className="rail-top">
          <button className="brand-lockup" onClick={() => setShowLauncher(true)} aria-label="Open TermX launcher">
            <span className="brand-mark"><img src="/manus-storage/termx-mark_65baddda.png" alt="" /></span>
            <span className="brand-name"><span className="brand-term">Term</span><span className="brand-x">X</span><span className="brand-caret">_</span></span>
          </button>
          <button className="icon-button mobile-close" onClick={() => setMobileRail(false)} aria-label="Close navigation"><X size={17} /></button>
        </div>
        <div className="rail-label">Workspace</div>
        <nav className="rail-nav" aria-label="Primary navigation">
          <button className="rail-item active" onClick={() => setShowLauncher(false)}><TerminalSquare size={17} /><span>Terminal</span><kbd>⌘1</kbd></button>
          <button className="rail-item" onClick={() => toast.info("Workspace browser is ready in the launcher.")}><LayoutGrid size={17} /><span>Workspaces</span></button>
          <button className="rail-item" onClick={() => toast.info("Command palette opened", { description: "Try running ls, pwd, git status, or python3." })}><Command size={17} /><span>Commands</span><kbd>⌘K</kbd></button>
        </nav>
        <div className="rail-label rail-label-spaced">Pinned</div>
        <div className="pinned-list">
          {workspaceList.slice(0, 2).map((workspace) => <button key={workspace.name} className={`pinned-item ${activeTab === workspace.name ? "current" : ""}`} onClick={() => openWorkspace(workspace.name)}><span className={`workspace-dot ${workspace.accent}`} />{workspace.name}</button>)}
          <button className="pinned-item muted-item" onClick={() => setShowLauncher(true)}><Plus size={14} /> Add workspace</button>
        </div>
        <div className="rail-bottom">
          <div className="sync-status"><span className="status-dot" /><div><strong>Local first</strong><span>Nothing leaves your device</span></div></div>
          <button className="rail-item" onClick={() => setShowSettings(true)}><Settings2 size={17} /><span>Settings</span></button>
          <div className="profile-chip"><span className="profile-avatar">A</span><div><strong>Alex Morgan</strong><span>Developer</span></div><MoreHorizontal size={15} /></div>
        </div>
      </aside>

      <main className="termx-main">
        <header className="topbar">
          <div className="topbar-left"><button className="icon-button mobile-menu" onClick={() => setMobileRail(true)} aria-label="Open navigation"><Menu size={18} /></button><div className="crumb"><span className="crumb-muted">Workspaces</span><ChevronRight size={14} /><span>{currentWorkspace.name}</span></div></div>
          <div className="topbar-actions"><button className="shortcut-button" onClick={() => toast.info("Command palette opened", { description: "⌘K to search commands" })}><Search size={15} /><span>Search commands</span><kbd>⌘K</kbd></button><button className="icon-button" onClick={() => setShowFiles(true)} aria-label="Browse files"><FolderOpen size={18} /></button><button className="icon-button" onClick={() => setShowSettings(true)} aria-label="Open settings"><Settings2 size={18} /></button><button className="avatar-button" onClick={() => toast("Signed in locally", { description: "Your workspace grants stay on this device." })}>AM</button></div>
        </header>

        <section className="session-strip">
          <div className="session-tabs">
            {workspaceList.slice(0, 2).map((workspace) => <button key={workspace.name} className={`session-tab ${activeTab === workspace.name ? "selected" : ""}`} onClick={() => setActiveTab(workspace.name)}><span className={`workspace-dot ${workspace.accent}`} />{workspace.name}<span className="tab-close" onClick={(event) => { event.stopPropagation(); if (workspaceList.length === 1) { toast.info("Keep one session open", { description: "Create another workspace before closing this tab." }); return; } const remaining = workspaceList.filter((item) => item.name !== workspace.name); setWorkspaceList(remaining); if (activeTab === workspace.name) setActiveTab(remaining[0].name); }}>×</span></button>)}
            <button className="new-tab" onClick={() => setShowLauncher(true)} aria-label="New terminal tab"><Plus size={16} /></button>
          </div>
          <div className="session-meta"><span className="live-pill"><span className="live-dot" />Live</span><span>zsh · {currentWorkspace.branch}</span><button className="icon-button tiny" onClick={() => toast("Session controls", { description: "Split panes and profiles are available from the command bar." })}><MoreHorizontal size={16} /></button></div>
        </section>

        <section className="workspace-header">
          <div><div className="eyebrow"><span className="eyebrow-line" />Active workspace <span className="execution-chip"><span className="live-dot" />Executing locally</span></div><h1>{currentWorkspace.name}</h1><div className="execution-line"><span /></div><p className="workspace-path"><Folder size={15} />{currentWorkspace.path}<button onClick={() => navigator.clipboard?.writeText(currentWorkspace.path).then(() => toast.success("Path copied"))}>copy</button></p></div>
          <div className="header-actions"><button className="secondary-button" onClick={() => toast("Folder picker", { description: "On iOS this opens the Files folder picker." })}><FolderOpen size={16} /> Open folder</button><button className="primary-button" onClick={() => runCommand("git status")}><Play size={15} /> Run command</button></div>
        </section>

        <section className={`console-layout ${splitPane ? "split-active" : ""}`}>
          <div className="console-card">
            <div className="console-topbar"><div className="console-signal"><span /></div><div className="window-lights"><span /><span /><span /></div><span className="console-title">termx-core — zsh</span><div className="console-tools"><span className="cpu-meter"><span style={{ width: "23%" }} /></span><span>23% CPU</span><button className={`console-tool ${splitPane ? "tool-active" : ""}`} onClick={() => setSplitPane((value) => !value)} aria-label="Toggle split pane"><PanelLeft size={15} /></button><button className="console-tool" onClick={() => setShowSettings(true)}><MoreHorizontal size={15} /></button></div></div>
            <div className="console-body" onClick={() => document.getElementById("command-input")?.focus()}>
              {lines.map((line, index) => <div className={`console-line ${line.kind}`} key={`${line.text}-${index}`}>{line.kind === "prompt" && <span className="prompt-symbol">›</span>}<span>{line.text}</span>{line.kind === "prompt" && index === lines.length - 1 && <span className={`cursor ${running ? "running" : ""}`} />}</div>)}
              <div className="command-entry"><span className="prompt-symbol">›</span><input id="command-input" value={input} onChange={(event) => setInput(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter") runCommand(); if (event.key === "ArrowUp") { event.preventDefault(); const next = Math.min(historyIndex + 1, history.length - 1); setHistoryIndex(next); setInput(history[next] ?? ""); } if (event.key === "ArrowDown") { event.preventDefault(); const next = Math.max(historyIndex - 1, -1); setHistoryIndex(next); setInput(next < 0 ? "" : history[next]); } if (event.key === "c" && event.ctrlKey && running) { setRunning(false); setLines((prev) => [...prev, { kind: "interrupt", text: "^C  process interrupted" }, { kind: "prompt", text: currentWorkspace.path }]); } }} placeholder="Type a command…" aria-label="Terminal command" autoComplete="off" /><span className="entry-hint">↵</span></div>
            </div>
            <div className="console-footer"><div><span className={`footer-active ${running ? "interrupt-ready" : ""}`}><span className="live-dot" />{running ? "Process running" : "Process ready"}</span><span>UTF-8</span><span>Ln 1, Col 1</span></div><div><button className="footer-action" onClick={() => { setHistory([]); toast.success("Command history cleared"); }}>clear history</button><button className="footer-action interrupt-action" onClick={() => { if (running) { setRunning(false); setLines((prev) => [...prev, { kind: "interrupt", text: "^C  process interrupted" }, { kind: "prompt", text: currentWorkspace.path }]); } }}>⌃C interrupt</button><span>⌘↵ run</span></div></div>
          </div>
          {splitPane && <div className="console-card secondary-console"><div className="console-topbar"><div className="console-signal"><span /></div><span className="console-title">agent-lab — zsh</span><div className="console-tools"><span className="live-pill"><span className="live-dot" />Live</span></div></div><div className="console-body"><div className="console-line muted">Split session · focused pane</div><div className="console-line prompt"><span className="prompt-symbol">›</span>~/workspaces/agent-lab</div><div className="console-line output">  ✓ ready for a second workflow</div><div className="command-entry"><span className="prompt-symbol">›</span><span className="placeholder-command">Type a command…</span></div></div><div className="console-footer"><div><span className="footer-active"><span className="live-dot" />Process ready</span></div></div></div>}
          <aside className="context-column">
            <div className="context-card context-card-highlight"><div className="context-heading"><div><span className="eyebrow-small">Workspace health</span><h3>Everything is local</h3></div><ShieldCheck size={19} /></div><p>Folder access is scoped to <strong>{currentWorkspace.name}</strong>. No sync, no account required.</p><div className="health-row"><span>Storage</span><span>1.8 GB free</span></div><div className="health-bar"><span style={{ width: "34%" }} /></div><div className="health-note"><HardDrive size={13} /> Sandboxed Documents</div></div>
            <div className="context-card"><div className="context-heading"><div><span className="eyebrow-small">Quick commands</span><h3>Keep moving</h3></div><Zap size={18} /></div><div className="quick-list">{commands.map((command) => <button key={command.label} className="quick-command" onClick={() => { setInput(command.label); document.getElementById("command-input")?.focus(); }}><span className="quick-icon"><command.icon size={15} /></span><span><strong>{command.label}</strong><small>{command.description}</small></span><ArrowUpRight size={14} /></button>)}</div></div>
            <div className="context-card runtime-card"><div className="context-heading"><div><span className="eyebrow-small">Runtime lanes</span><h3>Ready to execute</h3></div><Sparkles size={18} /></div><div className="runtime-row"><span className="runtime-icon python">Py</span><div><strong>Python 3.12</strong><small>Native runtime</small></div><button className={`runtime-toggle ${enabledRuntimes.python ? "on" : ""}`} onClick={() => setEnabledRuntimes((prev) => ({ ...prev, python: !prev.python }))}>{enabledRuntimes.python ? "Ready" : "Off"}</button></div><div className="runtime-row"><span className="runtime-icon node">JS</span><div><strong>Node 22</strong><small>Embedded runtime</small></div><button className={`runtime-toggle ${enabledRuntimes.node ? "on" : ""}`} onClick={() => setEnabledRuntimes((prev) => ({ ...prev, node: !prev.node }))}>{enabledRuntimes.node ? "Ready" : "Off"}</button></div><div className="runtime-row muted-runtime"><span className="runtime-icon linux"><Apple size={15} /></span><div><strong>Linux lane</strong><small>{enabledRuntimes.linux ? "Compatibility enabled" : "Enable in Settings"}</small></div><button onClick={() => setEnabledRuntimes((prev) => ({ ...prev, linux: !prev.linux }))}>{enabledRuntimes.linux ? "Disable" : "Configure"}</button></div></div>
          </aside>
        </section>
      </main>

      {showFiles && <div className="overlay" onClick={() => setShowFiles(false)}><section className="file-sheet" onClick={(event) => event.stopPropagation()}><div className="sheet-top"><div><span className="eyebrow-small">Workspace files</span><h2>{currentWorkspace.name}</h2><p>{cwd} · local read / write scope</p></div><button className="icon-button" onClick={() => setShowFiles(false)} aria-label="Close file browser"><X size={18} /></button></div><div className="file-toolbar"><span><FolderOpen size={14} /> Files</span><span>142 items</span></div><div className="file-list"><button onClick={() => setFilePreview("README.md")}><FileCode2 size={16} /><span><strong>README.md</strong><small>Markdown · 4.2 KB</small></span><ChevronRight size={15} /></button><button onClick={() => setFilePreview("Package.swift")}><FileCode2 size={16} /><span><strong>Package.swift</strong><small>Swift package manifest · 2.1 KB</small></span><ChevronRight size={15} /></button><button onClick={() => setFilePreview("Sources/TermXCore.swift")}><FileCode2 size={16} /><span><strong>Sources/TermXCore.swift</strong><small>Swift source · 18.4 KB</small></span><ChevronRight size={15} /></button><button onClick={() => setFilePreview("Tests/TermXCoreTests.swift")}><FileCode2 size={16} /><span><strong>Tests/TermXCoreTests.swift</strong><small>Test suite · 7.8 KB</small></span><ChevronRight size={15} /></button></div>{filePreview && <div className="file-preview"><div><span className="eyebrow-small">Preview</span><strong>{filePreview}</strong></div><pre>{filePreview === "README.md" ? "# TermXCore\n\nA local command engine for terminal sessions.\n\n## Getting started\n\nRun the acceptance suite on iOS Simulator." : filePreview === "Package.swift" ? "let package = Package(\n  name: \"TermXCore\",\n  platforms: [.iOS(.v16)],\n  products: [.library(name: \"TermXCore\")]\n)" : "public protocol TerminalEngine {\n  func startShell(cwd: String, env: [String: String],\n    ptySlave: Int32, onExit: @escaping (Int32) -> Void) throws -> Int32\n}"}</pre></div>}</section></div>}
      {paletteOpen && <div className="overlay palette-overlay" onClick={() => setPaletteOpen(false)}><section className="palette-sheet" onClick={(event) => event.stopPropagation()}><div className="palette-input"><Search size={17} /><input autoFocus value={paletteQuery} onChange={(event) => setPaletteQuery(event.target.value)} placeholder="Search commands, runtimes, or actions…" aria-label="Search commands" /><kbd>esc</kbd></div><div className="palette-list">{filteredCommands.map((command) => <button key={command.label} className="palette-command" onClick={() => { setInput(command.label); setPaletteOpen(false); window.setTimeout(() => document.getElementById("command-input")?.focus(), 0); }}><span className="quick-icon"><command.icon size={15} /></span><span><strong>{command.label}</strong><small>{command.description}</small></span><kbd>↵</kbd></button>)}<button className="palette-command" onClick={() => { setShowLauncher(true); setPaletteOpen(false); }}><span className="quick-icon"><FolderOpen size={15} /></span><span><strong>Open workspace</strong><small>Mount another local folder</small></span><kbd>↵</kbd></button><button className="palette-command" onClick={() => { setShowSettings(true); setPaletteOpen(false); }}><span className="quick-icon"><Settings2 size={15} /></span><span><strong>Open settings</strong><small>Configure runtimes and appearance</small></span><kbd>↵</kbd></button></div><div className="palette-footer"><span><kbd>↑</kbd><kbd>↓</kbd> navigate</span><span><kbd>↵</kbd> choose</span><span><kbd>esc</kbd> close</span></div></section></div>}
      {showLauncher && <div className="overlay" onClick={() => setShowLauncher(false)}><section className="launcher-sheet" onClick={(event) => event.stopPropagation()}><div className="sheet-top"><div><span className="eyebrow-small">TermX launcher</span><h2>Choose a workspace</h2><p>Mount a folder and open a new local terminal session.</p></div><button className="icon-button" onClick={() => setShowLauncher(false)} aria-label="Close launcher"><X size={18} /></button></div><div className="launcher-art"><img src="/manus-storage/termx-launcher_38025006.jpg" alt="Folder and terminal illustration" /><div><span className="eyebrow-small">New session</span><strong>Open a folder and make it executable.</strong><button className="primary-button" onClick={() => toast("Folder picker", { description: "On iOS this opens the system Files picker." })}><FolderOpen size={15} /> Open folder</button></div></div><div className="workspace-grid">{workspaceList.map((workspace) => <button className="workspace-card" key={workspace.name} onClick={() => openWorkspace(workspace.name)}><div className="workspace-card-top"><span className={`workspace-icon ${workspace.accent}`}><Folder size={19} /></span><ArrowUpRight size={16} /></div><strong>{workspace.name}</strong><span>{workspace.path}</span><div><small>{workspace.files}</small><small>{workspace.time}</small></div></button>)}</div><div className="new-workspace-row"><input value={newWorkspaceName} onChange={(event) => setNewWorkspaceName(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter") createWorkspace(); }} placeholder="workspace-name" aria-label="New workspace name" /><button className="secondary-button" onClick={createWorkspace}><Plus size={15} /> Create workspace</button></div><div className="sheet-foot"><Keyboard size={15} /> Tip: use <kbd>⌘</kbd><kbd>K</kbd> to jump to any command <button onClick={() => toast.info("Keyboard shortcuts", { description: "⌘K command palette · ⌘1 terminal · Ctrl+C interrupt" })}>View shortcuts <ArrowUpRight size={13} /></button></div></section></div>}
      {showSettings && <div className="overlay" onClick={() => setShowSettings(false)}><section className="settings-sheet" onClick={(event) => event.stopPropagation()}><div className="sheet-top"><div><span className="eyebrow-small">Configuration</span><h2>Settings</h2><p>Make TermX feel like your own instrument.</p></div><button className="icon-button" onClick={() => setShowSettings(false)} aria-label="Close settings"><X size={18} /></button></div><div className="settings-list"><div className="setting-row"><div><strong>Appearance</strong><span>Graphite · Signal chartreuse</span></div><span className="setting-value">Dark</span></div><div className="setting-row"><div><strong>Shell profile</strong><span>Default command interpreter</span></div><span className="setting-value">zsh</span></div><div className="setting-row"><div><strong>Font</strong><span>Terminal reading experience</span></div><span className="setting-value">IBM Plex Mono</span></div><div className="setting-row"><div><strong>Linux compatibility lane</strong><span>Run Alpine tools through Blink</span></div><button className={`toggle ${enabledRuntimes.linux ? "enabled" : ""}`} onClick={() => setEnabledRuntimes((prev) => ({ ...prev, linux: !prev.linux }))}><span /></button></div>
          <div className="setting-row"><div><strong>Command history</strong><span>{history.length} local entries · use ↑ and ↓ in the console</span></div><button className="secondary-button compact-button" onClick={() => { setHistory([]); toast.success("Command history cleared"); }}>Clear</button></div>
          <div className="setting-row"><div><strong>App Store notices</strong><span>Licenses and third-party attribution</span></div><button className="secondary-button compact-button" onClick={() => toast.info("Licenses", { description: "TermX uses permissive MIT, BSD, ISC, Apache-2.0, and PSF components. Notices are bundled with the app." })}>View</button></div></div><div className="settings-note"><ShieldCheck size={16} /><span><strong>Privacy by design</strong>TermX executes locally. Network access only happens when your command asks for it.</span></div></section></div>}
    </div>
  );
}
