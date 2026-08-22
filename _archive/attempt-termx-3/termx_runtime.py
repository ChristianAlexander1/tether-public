#!/usr/bin/env python3
"""Runnable TermX reference runtime for development and integration testing."""
from __future__ import annotations
import argparse, asyncio, json, os, pathlib, readline, shlex, signal, subprocess, sys, tempfile
from dataclasses import dataclass, asdict

@dataclass
class Workspace:
    id: str
    name: str
    mount_path: str
    real_path: str

class WorkspaceStore:
    def __init__(self, state_file: pathlib.Path|None=None):
        self.state_file = state_file or pathlib.Path.home()/'.termx'/'workspaces.json'
        self.state_file.parent.mkdir(parents=True, exist_ok=True)
        self.workspaces: dict[str, Workspace] = {}
        self._load()
    def _load(self):
        if self.state_file.exists():
            for d in json.loads(self.state_file.read_text()):
                self.workspaces[d['id']] = Workspace(**d)
    def _save(self): self.state_file.write_text(json.dumps([asdict(x) for x in self.workspaces.values()], indent=2))
    def add(self, path: str) -> Workspace:
        p=pathlib.Path(path).expanduser().resolve()
        if not p.is_dir(): raise ValueError(f'workspace is not a directory: {p}')
        import uuid
        w=Workspace(str(uuid.uuid4()),p.name,'/workspaces/'+p.name,str(p)); self.workspaces[w.id]=w; self._save(); return w
    def restore_all(self): return list(self.workspaces.values())
    def resolve(self, virtual: str) -> str|None:
        p=pathlib.PurePosixPath(virtual)
        parts=[x for x in p.parts if x not in ('/', '')]
        if len(parts)<2 or parts[0]!='workspaces': return None
        for w in self.workspaces.values():
            if w.name==parts[1]:
                candidate=(pathlib.Path(w.real_path)/pathlib.Path(*parts[2:])).resolve()
                if candidate==pathlib.Path(w.real_path) or pathlib.Path(w.real_path) in candidate.parents: return str(candidate)
        return None

class CommandEngine:
    def __init__(self, cwd: str, env: dict[str,str]|None=None):
        self.cwd=str(pathlib.Path(cwd).resolve()); self.env=os.environ.copy(); self.env.update(env or {})
        self.env.setdefault('TERM','xterm-256color'); self.env.setdefault('LANG','C.UTF-8'); self.last_status=0; self.jobs={}; self.next_job=1
    def run(self, command: str, interactive=False) -> int:
        command=command.strip()
        if not command: return 0
        if command in ('exit','quit'): raise EOFError
        if command.startswith('cd '):
            target=command[3:].strip() or os.path.expanduser('~'); p=pathlib.Path(target).expanduser(); p=p if p.is_absolute() else pathlib.Path(self.cwd)/p
            if p.is_dir(): self.cwd=str(p.resolve()); return 0
            print(f'cd: no such directory: {target}',file=sys.stderr); return 1
        if command=='pwd': print(self.cwd); return 0
        if command=='jobs':
            for jid,p in list(self.jobs.items()):
                if p.poll() is None: print(f'[{jid}] running pid={p.pid}')
                else: print(f'[{jid}] done ({p.returncode})'); del self.jobs[jid]
            return 0
        if command.startswith('python') and command.split()[0] in ('python','python3'):
            return self._spawn([sys.executable]+shlex.split(command)[1:], interactive)
        if command.split()[0] in ('node','nodejs'):
            return self._spawn(['node']+shlex.split(command)[1:], interactive)
        if command.split()[0]=='claude':
            return self._claude(shlex.split(command)[1:], interactive)
        if command.split()[0]=='linux':
            args=shlex.split(command)[1:]; return self._linux(args, interactive)
        background=command.endswith('&'); command=command[:-1].rstrip() if background else command
        p=subprocess.Popen(['/bin/sh','-lc',command],cwd=self.cwd,env=self.env,stdin=None if interactive else subprocess.DEVNULL)
        if background: jid=self.next_job; self.next_job+=1; self.jobs[jid]=p; print(f'[{jid}] {p.pid}'); return 0
        try: return p.wait()
        except KeyboardInterrupt: p.send_signal(signal.SIGINT); return p.wait()
    def _spawn(self, argv, interactive):
        p=subprocess.Popen(argv,cwd=self.cwd,env=self.env,stdin=None if interactive else subprocess.DEVNULL)
        try:return p.wait()
        except KeyboardInterrupt:p.send_signal(signal.SIGINT); return p.wait()
    def _claude(self,args,interactive):
        cli=shutil_which('claude') or shutil_which('npx')
        if not cli: print('Claude Code is not installed. Install it with: npm install -g @anthropic-ai/claude-code',file=sys.stderr); return 127
        argv=[cli]+(['@anthropic-ai/claude-code'] if pathlib.Path(cli).name=='npx' else [])+args; return self._spawn(argv,interactive)
    def _linux(self,args,interactive):
        root=pathlib.Path(self.env.get('TERMX_LINUX_ROOT',pathlib.Path.home()/'.termx'/'linux')); root.mkdir(parents=True,exist_ok=True)
        if not args: args=['sh']; print(f'TermX Linux-compatible environment: {root}')
        return self._spawn(args,interactive)

def shutil_which(name):
    for d in os.environ.get('PATH','').split(os.pathsep):
        p=pathlib.Path(d)/name
        if p.is_file() and os.access(p,os.X_OK): return str(p)
    return None

def main():
    ap=argparse.ArgumentParser(prog='termx'); ap.add_argument('workspace',nargs='?'); ap.add_argument('-c','--command'); ns=ap.parse_args()
    store=WorkspaceStore(); path=ns.workspace or os.getcwd(); w=store.add(path) if not any(x.real_path==str(pathlib.Path(path).resolve()) for x in store.restore_all()) else next(x for x in store.restore_all() if x.real_path==str(pathlib.Path(path).resolve()))
    e=CommandEngine(w.real_path, {'HOME':os.path.expanduser('~')})
    if ns.command: return e.run(ns.command)
    print(f'TermX workspace: {w.real_path}'); print('Type commands; built-ins: cd, pwd, jobs, linux, claude, exit')
    while True:
        try: e.last_status=e.run(input(f' termx:{pathlib.Path(e.cwd).name}$ '));
        except EOFError: print(); return 0
        except KeyboardInterrupt: print(); e.last_status=130
        except Exception as ex: print(f'termx: {ex}',file=sys.stderr); e.last_status=1

if __name__=='__main__': raise SystemExit(main())
