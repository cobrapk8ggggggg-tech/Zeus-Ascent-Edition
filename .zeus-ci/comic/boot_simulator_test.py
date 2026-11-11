import importlib.util
from pathlib import Path
import subprocess
import unittest

spec=importlib.util.spec_from_file_location('boot_simulator',Path(__file__).with_name('boot_simulator.py'))
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
A='00000000-0000-0000-0000-000000000001'
B='00000000-0000-0000-0000-000000000002'

class BootTests(unittest.TestCase):
    def test_blocked_boot_uses_another_device(self):
        calls=[]
        def run(command,**kwargs):
            calls.append((command,kwargs))
            if command[2]=='bootstatus' and A in command:raise subprocess.TimeoutExpired(command,kwargs['timeout'])
        self.assertEqual(module.boot([A,B],run=run),B)
        self.assertTrue(any(c[2]=='erase' and A in c for c,_ in calls))
        self.assertTrue(all(0<options['timeout']<=240 for _,options in calls))

    def test_global_deadline_stops_retrying(self):
        now=[0];statuses=[]
        def run(command,**kwargs):
            if command[2]=='bootstatus':
                statuses.append(command);now[0]=100
                raise subprocess.TimeoutExpired(command,kwargs['timeout'])
        with self.assertRaises(RuntimeError):module.boot([A,B],run=run,clock=lambda:now[0],budget=100)
        self.assertEqual(len(statuses),1)

    def test_success_does_not_reset_a_healthy_device(self):
        calls=[]
        self.assertEqual(module.boot([A,B],run=lambda cmd,**kw:calls.append(cmd)),A)
        self.assertEqual([c[2] for c in calls],['boot','bootstatus'])

if __name__=='__main__':unittest.main()
