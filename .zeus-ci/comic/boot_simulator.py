"""Boot only an available test simulator, with bounded waits and real failover."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


def boot(candidates, run=subprocess.run, clock=time.monotonic, budget=660):
    deadline=clock()+budget
    def remaining():return deadline-clock()
    for udid in dict.fromkeys(candidates):
        if remaining()<45:break
        if not re.fullmatch(r'[0-9a-fA-F-]{36}',udid):raise ValueError('Invalid simulator identifier')
        print('Booting simulator '+udid,flush=True)
        try:
            run(['xcrun','simctl','boot',udid],check=False,timeout=max(1,min(25,remaining()-40)))
            run(['xcrun','simctl','bootstatus',udid,'-b'],check=True,timeout=max(1,min(240,remaining()-40)))
            return udid
        except (subprocess.TimeoutExpired,subprocess.CalledProcessError) as error:
            print('Simulator did not become ready: '+type(error).__name__,flush=True)
            # A blocked bootstatus used to consume the entire step: none of the
            # shell loop's "retries" could ever run. Bound cleanup as well.
            for action in ['shutdown','erase']:
                if remaining()<5:break
                try:run(['xcrun','simctl',action,udid],check=False,timeout=min(20,remaining()-1))
                except (subprocess.TimeoutExpired,subprocess.CalledProcessError):pass
    raise RuntimeError('No selected iOS simulator became ready within the boot budget')


def main(preferred):
    result=subprocess.run(['xcrun','simctl','list','devices','available','-j'],check=True,capture_output=True,text=True,timeout=30)
    devices=json.loads(result.stdout)['devices']
    available=[d['udid'] for runtime,rows in devices.items() if 'iOS-26' in runtime for d in rows if 'iPhone' in d['name'] and 'Clone' not in d['name'] and d.get('isAvailable',True)]
    candidates=[value for value in preferred if value in available]+available
    chosen=boot(list(dict.fromkeys(candidates))[:3])
    with Path(os.environ['GITHUB_ENV']).open('a') as output:output.write('COMIC_SIMULATOR='+chosen+'\n')
    print('Ready: '+chosen,flush=True)

if __name__=='__main__':main(sys.argv[1:])
