#!/usr/bin/env python3
"""Exercise the account bridge with a real helper and isolated config; no cloud credentials."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--engine',type=Path,required=True)
    parser.add_argument('--rclone',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args(); results=[]
    args.output.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='rbn-account-') as tmp:
        root=Path(tmp); config=root/'accounts.conf'; config.write_text('',encoding='utf-8')
        target=root/'data';target.mkdir();(target/'keep.txt').write_text('keep',encoding='utf-8')
        env={k:v for k,v in os.environ.items() if not k.upper().startswith('RCLONE_')}
        process=subprocess.Popen([str(args.engine.resolve()),'--state-dir',str(root/'state'),'--engine-dir',str(args.rclone.resolve().parent)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,encoding='utf-8',env=env)
        replies=queue.Queue(); events=[]; sequence=0
        def read():
            for line in process.stdout:
                data=json.loads(line)
                if 'event' in data:events.append(data['event'])
                else:replies.put(data)
        threading.Thread(target=read,daemon=True).start()
        def call(method,*args):
            nonlocal sequence
            sequence+=1; ident=str(sequence)
            process.stdin.write(json.dumps({'id':ident,'method':method,'args':args})+'\n');process.stdin.flush()
            reply=replies.get(timeout=90)
            assert reply['id']==ident
            if reply.get('error'):raise RuntimeError(reply['error'])
            return reply.get('result')
        def check(name,callback):
            started=time.monotonic();callback()
            results.append({'name':name,'passed':True,'seconds':round(time.monotonic()-started,3)})
            print('PASS',name,flush=True)
        def wait(session):
            end=time.monotonic()+40
            while time.monotonic()<end:
                state=call('accountStatus',session['id'])
                if state['phase'] not in ['working','saving','cancelling']:return state
                time.sleep(.05)
            raise TimeoutError('Account setup did not settle')
        def begin(name,provider='alias',mode='create'):
            return wait(call('accountBegin',{'name':name,'provider':provider,'mode':mode}))
        def cancel(session):
            state=wait(call('accountCancel',session['id']));assert state['phase']=='cancelled',state
        def answer(state,value=None):
            assert state['phase']=='question',state
            return wait(call('accountAnswer',state['id'],{'step':state['step'],'useDefault':value is None,'value':value}))
        def finish(state):
            for _ in range(15):
                if state['phase']=='ready':return state
                state=answer(state,str(target) if state['option']['Name']=='remote' else None)
            raise AssertionError('Too many alias steps')
        try:
            call('saveSettings',{'rclonePath':str(args.rclone.resolve()),'rcloneDirectory':str(args.rclone.resolve().parent),'configPath':str(config),'autoCheckUpdates':False,'language':'en'})
            def catalog():
                value=call('accountCatalog');assert Path(value['configPath'])==config
                assert {'alias','drive','onedrive'}.issubset({p['name'] for p in value['providers']})
                assert not value['remotes']
            check('provider catalog and selected config use the native bridge',catalog)
            def create():
                s=begin('test_alias');assert s['phase']=='question'; assert call('_state')['configuring']
                assert s['option']['Required'];assert 'State' not in s
                try:call('accountAnswer',s['id'],{'step':s['step'],'value':'','useDefault':False})
                except RuntimeError:pass
                else:raise AssertionError('Required empty answer accepted')
                try:call('saveSettings',{'configPath':str(root/'different.conf')})
                except RuntimeError:pass
                else:raise AssertionError('Config changed during setup')
                s=finish(s);assert config.read_text()==''
                assert call('accountCommit',s['id'])['phase']=='saved'
                assert not call('_state')['configuring']
                assert 'test_alias' in {r['name'] for r in call('accountCatalog')['remotes']}
            check('create validates required fields and commits only after Save',create)
            def cancelled():
                baseline=config.read_bytes();s=begin('test_alias',mode='edit');cancel(s)
                assert config.read_bytes()==baseline and not call('_state')['configuring']
                assert not list(root.glob('.rbn-account-*'))
            check('cancel preserves config and releases maintenance',cancelled)
            def conflict():
                s=finish(begin('conflict'));new=config.read_bytes()+b'\n# concurrent change\n';config.write_bytes(new)
                try:call('accountCommit',s['id'])
                except RuntimeError:pass
                else:raise AssertionError('Concurrent edit overwritten')
                assert config.read_bytes()==new;cancel(s)
            check('external config edits prevent lost updates',conflict)
            def providers():
                for provider in ['drive','onedrive']:
                    s=begin('auth_'+provider,provider);saw=False
                    for _ in range(18):
                        assert s['phase']=='question',s
                        q=s['option'];assert 'Value' not in q
                        if q['Name']=='config_is_local' or (q['Name']=='client_id' and q.get('Required')):saw=True;break
                        s=answer(s)
                    assert saw;cancel(s)
            check('Google and Microsoft reach credential or browser steps',providers)
            def delete():
                s=begin('test_alias',mode='delete');assert s['phase']=='ready'
                assert 'test_alias' in config.read_text();cancel(s)
                s=begin('test_alias',mode='delete');call('accountCommit',s['id'])
                assert 'test_alias' not in config.read_text()
                assert (target/'keep.txt').read_text()=='keep'
                assert not list(root.glob('.rbn-account-*'))
            check('delete confirmation changes account entry, never stored files',delete)
            check('terminal config remains available after GUI lease ends',lambda:(call('_beginConfiguration'),call('_endConfiguration')))
            call('_shutdown');process.stdin.close();process.wait(timeout=20);assert process.returncode==0
        finally:
            if process.poll() is None:process.terminate();process.wait(timeout=20)
    report={'passed':True,'sourceCommit':os.environ.get('GITHUB_SHA'),'engineSHA256':hashlib.sha256(args.engine.read_bytes()).hexdigest(),'cases':results,'cloudCredentialsUsed':False}
    args.output.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print('RESULT',len(results),'passed, 0 failed')

if __name__=='__main__':main()
