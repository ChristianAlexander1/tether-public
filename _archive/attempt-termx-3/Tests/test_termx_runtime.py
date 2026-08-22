import asyncio, pathlib, subprocess, sys, tempfile, unittest
sys.path.insert(0, str(pathlib.Path(__file__).parents[1]))
from termx_runtime import WorkspaceStore, CommandEngine

class TermXRuntimeTests(unittest.TestCase):
    def test_workspace_persistence_and_path_escape_protection(self):
        with tempfile.TemporaryDirectory() as d:
            state=pathlib.Path(d)/'state.json'; root=pathlib.Path(d)/'repo'; root.mkdir(); (root/'x').write_text('ok')
            s=WorkspaceStore(state); w=s.add(str(root)); self.assertEqual(s.resolve(w.mount_path+'/x'), str(root/'x')); self.assertIsNone(s.resolve(w.mount_path+'/../secret'))
            self.assertEqual(len(WorkspaceStore(state).restore_all()),1)
    def test_shell_pipeline_and_status(self):
        with tempfile.TemporaryDirectory() as d:
            e=CommandEngine(d); self.assertEqual(e.run("printf 'a\\nb\\n' | grep b > out"),0); self.assertEqual((pathlib.Path(d)/'out').read_text(),'b\n')
    def test_cd_and_python(self):
        with tempfile.TemporaryDirectory() as d:
            sub=pathlib.Path(d)/'sub'; sub.mkdir(); e=CommandEngine(d); self.assertEqual(e.run('cd sub'),0); self.assertEqual(pathlib.Path(e.cwd),sub); self.assertEqual(e.run("python3 -c 'print(2+2)'"),0)
    def test_node_dispatch_if_available(self):
        if not subprocess.run(['sh','-lc','command -v node'],capture_output=True).stdout: self.skipTest('node unavailable')
        with tempfile.TemporaryDirectory() as d: self.assertEqual(CommandEngine(d).run("node -e 'console.log(2+2)'"),0)
    def test_linux_fallback_creates_root(self):
        with tempfile.TemporaryDirectory() as d:
            root=pathlib.Path(d)/'linux'; e=CommandEngine(d,{'TERMX_LINUX_ROOT':str(root)}); self.assertEqual(e.run("linux /bin/sh -lc 'printf linux-ok'"),0); self.assertTrue(root.is_dir())

if __name__=='__main__': unittest.main()
