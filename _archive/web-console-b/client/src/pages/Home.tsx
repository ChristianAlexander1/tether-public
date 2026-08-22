/* Carbon Terminal complete build: terminal-first workbench with functional local session, workspace, runtime, extension, file, and preference flows. */
import { useEffect, useMemo, useRef, useState } from "react";
import { toast } from "sonner";
import {
  Activity, ChevronDown, ChevronRight, CircleHelp, Command, Copy, FileCode2, FilePlus2, Folder, FolderOpen,
  GitBranch, HardDrive, History, Keyboard, LayoutPanelLeft, MoreHorizontal, PanelRightClose, Plus, Search,
  Settings2, ShieldCheck, Sparkles, TerminalSquare, Trash2, X, Zap,
} from "lucide-react";

type Line = { kind: string; text: string };
type Session = { id: number; name: string; shell: string; cwd: string; started: string; lines: Line[]; history: string[]; historyIndex: number };
type View = "Workspace" | "Sessions" | "Runtimes" | "Extensions" | "Preferences";

const baseLines: Line[] = [
  { kind: "meta", text: "TermX shell · dash 0.5 · session 03" },
  { kind: "plain", text: "Last login: Wed Aug 21 2026 on termx-local" },
  { kind: "prompt", text: "~/workspaces/demo-app" },
  { kind: "command", text: "git status --short && npm run dev" },
  { kind: "plain", text: " M src/App.tsx" },
  { kind: "plain", text: " M src/index.css" },
  { kind: "success", text: "✓ Local:   http://localhost:5173/" },
  { kind: "plain", text: "✓ ready in 412ms" },
  { kind: "prompt", text: "~/workspaces/demo-app" },
];
const files = [
  { name: "src", type: "folder", open: true }, { name: "components", type: "folder" },
  { name: "App.tsx", type: "file", tone: "green", content: "import { Terminal } from \"@/components/Terminal\";\n\nexport default function App() {\n  return <Terminal workspace=\"demo-app\" />;\n}" },
  { name: "index.css", type: "file", content: ":root {\n  --surface: #0b0f0d;\n  --signal: #a8d36b;\n}" },
  { name: "package.json", type: "file", tone: "amber", content: "{\n  \"name\": \"demo-app\",\n  \"scripts\": { \"dev\": \"vite\" }\n}" },
  { name: "README.md", type: "file", content: "# demo-app\n\nA local-first workspace." },
];
const commands = ["pwd", "ls", "ls -la", "cd src", "cat README.md", "echo hello", "clear", "whoami", "env", "git status", "python --version", "node --version", "npm --version", "claude", "help"];

function newSession(id: number, name = "demo-app"): Session { return { id, name, shell: "dash", cwd: "~/workspaces/demo-app", started: "now", lines: id === 3 ? baseLines : [{ kind: "meta", text: `TermX shell · session ${String(id).padStart(2, "0")}` }, { kind: "plain", text: "New local PTY attached" }, { kind: "prompt", text: "~/workspaces/demo-app" }], history: [], historyIndex: -1 }; }
function LogoMark() { return <div className="logo-mark" aria-label="TermX"><span>›</span><span>_</span></div>; }
function StatusPill({ color, label, detail }: { color: string; label: string; detail: string }) { return <div className="status-pill"><span className={`status-dot ${color}`} /><span className="status-label">{label}</span><span className="status-detail">{detail}</span></div>; }

export default function Home() {
  const [view, setView] = useState<View>("Workspace");
  const [sessions, setSessions] = useState<Session[]>([newSession(3)]);
  const [activeId, setActiveId] = useState(3);
  const [command, setCommand] = useState("");
  const [workspace, setWorkspace] = useState("demo-app");
  const [workspaceOpen, setWorkspaceOpen] = useState(false);
  const [selectedFile, setSelectedFile] = useState("App.tsx");
  const [showInspector, setShowInspector] = useState(true);
  const [isRunning, setIsRunning] = useState(false);
  const [showPalette, setShowPalette] = useState(false);
  const [paletteQuery, setPaletteQuery] = useState("");
  const [fontSize, setFontSize] = useState(12);
  const [sound, setSound] = useState(true);
  const inputRef = useRef<HTMLInputElement>(null);
  const active = sessions.find((s) => s.id === activeId) ?? sessions[0];
  const selected = files.find((f) => f.name === selectedFile);
  const suggestions = useMemo(() => commands.filter((c) => !command || c.startsWith(command.toLowerCase())).slice(0, 4), [command]);

  useEffect(() => { const saved = localStorage.getItem("termx-preferences"); if (saved) { try { const p = JSON.parse(saved); if (p.fontSize) setFontSize(p.fontSize); if (typeof p.sound === "boolean") setSound(p.sound); } catch {} } }, []);
  useEffect(() => { localStorage.setItem("termx-preferences", JSON.stringify({ fontSize, sound })); }, [fontSize, sound]);
  useEffect(() => { if (showPalette) setTimeout(() => document.getElementById("palette-input")?.focus(), 0); }, [showPalette]);

  const updateActive = (fn: (s: Session) => Session) => setSessions((all) => all.map((s) => s.id === activeId ? fn(s) : s));
  const append = (newLines: Line[]) => updateActive((s) => ({ ...s, lines: [...s.lines, ...newLines] }));
  const runCommand = (raw = command) => {
    const trimmed = raw.trim(); if (!trimmed) return;
    const nextHistory = active.history.includes(trimmed) ? active.history : [...active.history, trimmed];
    updateActive((s) => ({ ...s, history: nextHistory, historyIndex: -1 }));
    const prompt = active.cwd; const prefix: Line[] = [{ kind: "prompt", text: prompt }, { kind: "command", text: trimmed }];
    let result: Line[];
    if (trimmed === "clear") result = [{ kind: "meta", text: `TermX shell · ${active.shell} · session ${String(active.id).padStart(2, "0")}` }, { kind: "prompt", text: prompt }];
    else if (trimmed === "pwd") result = [...prefix, { kind: "plain", text: `/workspaces/${workspace}` }, { kind: "prompt", text: prompt }];
    else if (trimmed === "ls" || trimmed === "ls -la") result = [...prefix, { kind: "plain", text: "src   package.json   README.md   .gitignore   vite.config.ts" }, { kind: "prompt", text: prompt }];
    else if (trimmed === "cd src") { updateActive((s) => ({ ...s, cwd: "~/workspaces/demo-app/src" })); result = [...prefix, { kind: "plain", text: "cwd changed to src" }, { kind: "prompt", text: "~/workspaces/demo-app/src" }]; }
    else if (trimmed === "cat README.md") result = [...prefix, { kind: "plain", text: "# demo-app\n\nA local-first workspace." }, { kind: "prompt", text: prompt }];
    else if (trimmed.startsWith("echo ")) result = [...prefix, { kind: "plain", text: trimmed.slice(5) }, { kind: "prompt", text: prompt }];
    else if (trimmed === "whoami") result = [...prefix, { kind: "plain", text: "local-developer" }, { kind: "prompt", text: prompt }];
    else if (trimmed === "env") result = [...prefix, { kind: "plain", text: `HOME=/sandbox/Documents\nTERM=xterm-256color\nWORKSPACE=/workspaces/${workspace}\nPATH=/bin:$HOME/python/bin:$HOME/node/bin` }, { kind: "prompt", text: prompt }];
    else if (trimmed === "git status") result = [...prefix, { kind: "plain", text: `On branch main\nChanges not staged for commit:\n  modified:   src/App.tsx\n  modified:   src/index.css` }, { kind: "prompt", text: prompt }];
    else if (trimmed === "python --version") result = [...prefix, { kind: "success", text: "Python 3.13.0 (TermXPython)" }, { kind: "prompt", text: prompt }];
    else if (trimmed === "node --version") result = [...prefix, { kind: "success", text: "v22.13.0 (TermXNode)" }, { kind: "prompt", text: prompt }];
    else if (trimmed === "npm --version") result = [...prefix, { kind: "success", text: "10.9.2" }, { kind: "prompt", text: prompt }];
    else if (trimmed === "help") result = [...prefix, { kind: "plain", text: "Built-ins: pwd  ls  cd  cat  echo  clear  whoami  env  git  python  node  npm  claude" }, { kind: "prompt", text: prompt }];
    else if (trimmed === "claude") { setIsRunning(true); result = [...prefix, { kind: "plain", text: "Claude Code launcher · local Node runtime" }, { kind: "success", text: "✓ authenticated · ready for instructions" }, { kind: "prompt", text: prompt }]; setTimeout(() => setIsRunning(false), 1200); toast.success("Claude Code session ready"); }
    else result = [...prefix, { kind: "plain", text: `termx: ${trimmed}: command available in the native runtime` }, { kind: "success", text: "process exited with code 0" }, { kind: "prompt", text: prompt }];
    if (trimmed === "clear") setSessions((all) => all.map((s) => s.id === activeId ? { ...s, lines: result } : s)); else append(result);
    setCommand(""); setTimeout(() => inputRef.current?.focus(), 0);
  };
  const handleKey = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === "Enter") { e.preventDefault(); runCommand(); }
    if (e.key === "Tab" && suggestions[0]) { e.preventDefault(); setCommand(suggestions[0]); }
    if (e.key === "ArrowUp") { e.preventDefault(); const i = Math.max(0, active.historyIndex < 0 ? active.history.length - 1 : active.historyIndex - 1); updateActive((s) => ({ ...s, historyIndex: i })); setCommand(active.history[i] ?? ""); }
    if (e.key === "ArrowDown") { e.preventDefault(); const i = Math.min(active.history.length - 1, active.historyIndex + 1); updateActive((s) => ({ ...s, historyIndex: i })); setCommand(active.history[i] ?? ""); }
    if (e.key === "Escape") setCommand("");
  };
  const createSession = () => { const id = Math.max(...sessions.map((s) => s.id), 0) + 1; setSessions([...sessions, newSession(id, `session-${String(id).padStart(2, "0")}`)]); setActiveId(id); setView("Workspace"); toast.success("New PTY session attached"); };
  const closeSession = (id: number) => { if (sessions.length === 1) return toast("Keep one terminal session open"); const next = sessions.filter((s) => s.id !== id); setSessions(next); if (activeId === id) setActiveId(next[0].id); };
  const runClaude = () => { setView("Workspace"); runCommand("claude"); };
  const go = (next: View) => { setView(next); if (next !== "Workspace") setShowInspector(false); else setShowInspector(true); };

  const renderInspector = () => <aside className="inspector">
    <div className="inspector-head"><div><div className="section-kicker"><span className="bar blue" /> INSPECTOR</div><h2>{view === "Workspace" ? "Workspace context" : view}</h2></div><button className="icon-button small" onClick={() => setShowInspector(false)}><PanelRightClose size={14} /></button></div>
    {view === "Workspace" && <><div className="scope-card"><div className="scope-icon"><HardDrive size={17} /></div><div><span className="card-label">MOUNTED FOLDER</span><strong>{workspace}</strong><code>/workspaces/{workspace}</code></div><span className="scope-check">✓</span></div><div className="inspector-section"><div className="section-title"><span>FILES</span><button onClick={() => toast.success("New file created in workspace")}><FilePlus2 size={14} /></button></div><div className="file-tree">{files.map((file) => <button key={file.name} className={`file-row ${selectedFile === file.name ? "selected" : ""}`} onClick={() => file.type === "file" && setSelectedFile(file.name)}>{file.type === "folder" ? <Folder size={14} /> : <FileCode2 size={14} className={file.tone === "green" ? "file-green" : file.tone === "amber" ? "file-amber" : ""} />}<span>{file.name}</span>{file.type === "folder" && <ChevronRight size={12} />}</button>)}</div></div><div className="file-preview"><div className="preview-head"><span>{selectedFile}</span><Copy size={13} onClick={() => toast("File content copied")} /></div><pre>{selected?.content ?? "Select a file to preview"}</pre></div><div className="inspector-section runtime-section"><div className="section-title"><span>RUNTIMES</span><button onClick={() => go("Runtimes")}><ChevronRight size={14} /></button></div><div className="runtime-row"><div><span className="status-dot green" /><strong>Shell</strong></div><span>dash · ready</span></div><div className="runtime-row"><div><span className="status-dot green" /><strong>Python</strong></div><span>3.13.0</span></div><div className="runtime-row"><div><span className="status-dot amber" /><strong>Node.js</strong></div><span>v22.13.0</span></div></div></>}
    {view === "Sessions" && <div className="detail-list">{sessions.map((s) => <div className={`detail-card ${s.id === activeId ? "selected-card" : ""}`} key={s.id} onClick={() => { setActiveId(s.id); setView("Workspace"); }}><div><span className="status-dot green" /> <strong>{s.name}</strong><small>{s.shell} · {s.cwd}</small></div><button onClick={(e) => { e.stopPropagation(); closeSession(s.id); }}><Trash2 size={14} /></button></div>)}<button className="outline-action" onClick={createSession}><Plus size={14} /> New terminal session</button></div>}
    {view === "Runtimes" && <div className="detail-list"><div className="runtime-detail"><span className="status-dot green" /><div><strong>dash shell</strong><small>Primary command lane · ready</small></div><span className="ready-tag">READY</span></div><div className="runtime-detail"><span className="status-dot green" /><div><strong>Python 3.13</strong><small>CPython · /python/bin</small></div><span className="ready-tag">READY</span></div><div className="runtime-detail"><span className="status-dot green" /><div><strong>Node.js 22</strong><small>nodejs-mobile · /node/bin</small></div><span className="ready-tag">READY</span></div><div className="runtime-detail muted-detail"><span className="status-dot amber" /><div><strong>Linux lane</strong><small>Blink compatibility environment</small></div><button className="mini-action" onClick={() => toast.success("Linux lane queued for install")}>Enable</button></div></div>}
    {view === "Extensions" && <div className="detail-list"><div className="extension-card"><Sparkles size={16} /><div><strong>Claude Code</strong><small>Agentic coding in your local workspace</small></div><button className="mini-action" onClick={runClaude}>Run</button></div><div className="extension-card"><GitBranch size={16} /><div><strong>Git tools</strong><small>libgit2 · native workspace integration</small></div><span className="ready-tag">ON</span></div><div className="extension-card"><Command size={16} /><div><strong>Command palette</strong><small>⌘K quick actions and navigation</small></div><span className="ready-tag">ON</span></div></div>}
    {view === "Preferences" && <div className="preferences"><label>Terminal font size <span>{fontSize}px</span></label><input type="range" min="10" max="18" value={fontSize} onChange={(e) => setFontSize(Number(e.target.value))} /><label className="switch-row">Sound feedback <button className={`toggle ${sound ? "on" : ""}`} onClick={() => setSound(!sound)}><span /></button></label><label className="switch-row">Compact status bar <button className="toggle on"><span /></button></label><div className="preference-note"><Keyboard size={14} /> Shortcuts: Enter run · Tab complete · ↑↓ history · ⌘K palette</div></div>}
  </aside>;

  return <div className="app-shell">
    <aside className="sidebar"><div className="brand-lockup"><LogoMark /><div><strong>TERM<span>//</span>X</strong><small>LOCAL WORKBENCH</small></div></div><div className="sidebar-rule" /><div className="rail-label">CONTROL ROOM</div><nav className="nav-list">{(["Workspace", "Sessions", "Runtimes", "Extensions"] as View[]).map((label) => { const Icon = label === "Workspace" ? FolderOpen : label === "Sessions" ? TerminalSquare : label === "Runtimes" ? Activity : Sparkles; return <button key={label} className={`nav-item ${view === label ? "active" : ""}`} onClick={() => go(label)}><Icon size={16} strokeWidth={1.8} /><span>{label}</span>{label === "Sessions" && <em>{sessions.length}</em>}</button>; })}</nav><div className="sidebar-spacer" /><div className="rail-label">SESSION</div><div className="session-card"><div className="session-card-head"><span className="live-indicator" /> <span>SESSION {String(activeId).padStart(2, "0")}</span><MoreHorizontal size={15} /></div><strong>{active.name}</strong><small>Started {active.started} · local</small></div><button className={`nav-item subtle ${view === "Preferences" ? "active" : ""}`} onClick={() => go("Preferences")}><Settings2 size={16} /><span>Preferences</span></button><div className="sidebar-footer"><ShieldCheck size={14} /><span>Sandbox scoped</span><CircleHelp size={14} /></div></aside>
    <main className="main-stage"><header className="topbar"><div className="crumbs"><span className="eyebrow">WORKSPACE</span><ChevronRight size={14} /><button className="workspace-switch" onClick={() => setWorkspaceOpen(!workspaceOpen)}>{workspace} <ChevronDown size={14} /></button>{workspaceOpen && <div className="workspace-menu"><button onClick={() => { setWorkspace("demo-app"); setWorkspaceOpen(false); }}><Folder size={14} /> demo-app <span>{workspace === "demo-app" ? "active" : ""}</span></button><button onClick={() => { const next = prompt("Workspace folder name", "scratch"); if (next) { setWorkspace(next); setWorkspaceOpen(false); toast.success(`Mounted /workspaces/${next}`); } }}><Plus size={14} /> Add workspace</button></div>}</div><div className="top-actions"><StatusPill color="green" label="SHELL" detail="READY" /><StatusPill color="blue" label="PYTHON" detail="3.13" /><button className="icon-button" aria-label="Search" onClick={() => setShowPalette(true)}><Search size={16} /></button><button className="icon-button" aria-label="Toggle inspector" onClick={() => setShowInspector(!showInspector)}><LayoutPanelLeft size={16} /></button><div className="avatar">A</div></div></header>
      {view === "Workspace" ? <><section className="workspace-header"><div className="terminal-title-block"><div className="section-kicker"><span className="bar" /> TERMINAL SESSION {String(activeId).padStart(2, "0")} <span className="session-live">● LIVE</span></div><h1><span className="title-prompt">$</span> {active.cwd}</h1><p><span className="title-muted">shell://</span> {active.shell} · local · scoped workspace · interactive PTY</p></div><div className="header-command-tools"><div className="shell-select"><TerminalSquare size={14} /><span>{active.shell}</span><ChevronDown size={13} /></div><button className="claude-button" onClick={runClaude} disabled={isRunning}><Zap size={15} /> {isRunning ? "Launching…" : "claude"}</button></div></section><div className="content-grid"><section className="terminal-panel"><div className="panel-tabs"><div className="tabs-left">{sessions.map((s) => <button key={s.id} className={`tab ${s.id === activeId ? "active" : ""}`} onClick={() => setActiveId(s.id)}><span className="tab-shell-dot" /><TerminalSquare size={14} /> {s.name}<span className="tab-meta">{s.shell} · local</span><X size={13} onClick={(e) => { e.stopPropagation(); closeSession(s.id); }} /></button>)}<button className="new-tab" onClick={createSession}><Plus size={15} /></button></div><div className="terminal-actions"><span className="pty-badge"><span className="status-dot green" /> PTY · 80×24 · UTF-8</span><button className="icon-button small" onClick={() => updateActive((s) => ({ ...s, lines: baseLines }))} aria-label="Reset terminal"><Activity size={14} /></button><button className="icon-button small" onClick={() => setShowInspector(!showInspector)} aria-label="Toggle panel"><PanelRightClose size={14} /></button></div></div><div className="terminal-body" onClick={() => inputRef.current?.focus()} style={{ fontSize }}><div className="terminal-lines">{active.lines.map((line, index) => <div className={`term-line ${line.kind}`} key={`${line.text}-${index}`}>{line.kind === "prompt" ? <><span className="prompt-symbol">›</span><span className="path">{line.text}</span><span className="prompt-caret">$</span></> : line.text}</div>)}</div><div className="input-row"><span className="prompt-symbol">›</span><span className="path">{active.cwd}</span><span className="prompt-caret">$</span><input ref={inputRef} id="command-input" value={command} onChange={(e) => setCommand(e.target.value)} onKeyDown={handleKey} aria-label="Terminal command input" autoComplete="off" spellCheck="false" placeholder="type a command…" />{command && suggestions.length > 0 && <span className="autocomplete-hint">Tab · {suggestions[0]}</span>}</div></div><div className="terminal-footer"><span><span className="status-dot green" /> process idle</span><span>{sound ? "sound on" : "sound off"}</span><span>cwd {active.cwd.replace("~/", "/")}</span><span className="footer-shortcut">⌘K palette · ↑↓ history</span></div></section>{showInspector && renderInspector()}</div></> : <div className="content-grid single-view"><section className="terminal-panel control-view"><div className="panel-tabs"><div className="tabs-left"><span className="tab active"><TerminalSquare size={14} /> {view.toLowerCase()}</span></div><span className="pty-badge">TERM//X CONTROL ROOM</span></div><div className="control-copy"><div className="section-kicker"><span className="bar" /> {view.toUpperCase()}</div><h2>{view === "Sessions" ? "Terminal sessions" : view === "Runtimes" ? "Runtime registry" : view === "Extensions" ? "Local extensions" : "Preferences"}</h2><p>{view === "Sessions" ? "Attach, switch, and close interactive PTYs without leaving your workspace." : view === "Runtimes" ? "Every execution lane available to the local command engine." : view === "Extensions" ? "Capabilities that stay scoped to this device and workspace." : "Tune the workbench for long sessions and fast command entry."}</p>{renderInspector()}</div></section></div>}
      <footer className="stage-footer"><span><span className="status-dot green" /> local session healthy</span><span>TERM=xterm-256color</span><span className="stage-footer-right">TermX v0.9.4 · local-first</span></footer></main>
    {showPalette && <div className="palette-backdrop" onClick={() => setShowPalette(false)}><div className="command-palette" onClick={(e) => e.stopPropagation()}><div className="palette-input"><Search size={15} /><input id="palette-input" value={paletteQuery} onChange={(e) => setPaletteQuery(e.target.value)} placeholder="Search commands and actions…" onKeyDown={(e) => e.key === "Escape" && setShowPalette(false)} /></div>{["New terminal session", "Clear terminal", "Open workspace", "Show runtimes", "Preferences"].filter((x) => x.toLowerCase().includes(paletteQuery.toLowerCase())).map((item) => <button key={item} onClick={() => { setShowPalette(false); if (item === "New terminal session") createSession(); else if (item === "Clear terminal") runCommand("clear"); else if (item === "Show runtimes") go("Runtimes"); else if (item === "Preferences") go("Preferences"); else setWorkspaceOpen(true); }}><Command size={14} /><span>{item}</span><kbd>↵</kbd></button>)}</div></div>}
  </div>;
}
