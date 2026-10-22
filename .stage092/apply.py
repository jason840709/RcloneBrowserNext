from pathlib import Path
import hashlib,json,shutil
root=Path.cwd()
for batch in ['core-edits.json','web-edits.json']:
    for item in json.loads((root/'.stage092'/batch).read_text()):
        p=root/item['path']
        assert p.is_relative_to(root) and '..' not in Path(item['path']).parts
        raw=p.read_bytes();assert hashlib.sha256(raw).hexdigest()==item['before'],item['path']+' before'
        text=raw.decode()
        for a,b,value in reversed(item['edits']):text=text[:a]+value+text[b:]
        raw=text.encode();assert hashlib.sha256(raw).hexdigest()==item['after'],item['path']+' after'
        p.write_bytes(raw)
p=root/'WebSource/renderer/styles.css'
p.write_text(p.read_text()+(root/'.stage092/account-styles.css').read_text())
p=root/'WebSource/tests/ui.spec.ts'
p.write_text(p.read_text().replace("name:'アカウント設定（Config）'","name:'アカウント設定'"))
p=root/'docs/BUILD_COMPATIBILITY.md'
p.write_text(p.read_text().replace("Account setup opens rclone's interactive configuration in a terminal.","The Accounts button opens a graphical setup wizard driven by rclone's JSON protocol. The adjacent config text control retains terminal configuration."))
shutil.rmtree(root/'.stage092')
(root/'.github/workflows/prepare-0.9.2.yml').unlink()
