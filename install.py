#!/usr/bin/env python3
"""Preview or install an exact local mod candidate. No downloads or save edits."""
import argparse, datetime, hashlib, json, os, sys, uuid
from pathlib import Path, PurePosixPath

def sha(data): return hashlib.sha256(data).hexdigest()
def bounded(path):
    if path.stat().st_size > 16*1024*1024: raise ValueError('File exceeds size limit: '+str(path))
    return path.read_bytes()
def safe(root, relative):
    p=PurePosixPath(relative)
    if not relative or p.is_absolute() or '\\' in relative or any(x in ('..','.') for x in relative.split('/')):
        raise ValueError('Unsafe path: '+relative)
    result=root.joinpath(*p.parts)
    current=root
    if root.is_symlink(): raise ValueError('Symlink root is not supported')
    for part in p.parts:
        current=current/part
        if current.is_symlink(): raise ValueError('Symlink is not supported: '+str(current))
    if not result.resolve().is_relative_to(root.resolve()): raise ValueError('Path escapes root')
    return result

def assemble(before, entry):
    if 'edits' not in entry: raise ValueError('Missing patch instructions')
    lines=before.decode('utf-8').splitlines(keepends=True); out=[]; pos=0
    for change in entry['edits']:
        a,b,text=change
        if not isinstance(a,int) or not isinstance(b,int) or not pos<=a<=b<=len(lines) or not isinstance(text,str):
            raise ValueError('Invalid patch range')
        out.extend(lines[pos:a]);out.append(text);pos=b
    out.extend(lines[pos:]);return ''.join(out).encode()

def plan(package, game):
    manifest=json.loads(bounded(package/'install-manifest.json'))
    if manifest.get('schema')!=1: raise ValueError('Unsupported manifest')
    mod=manifest['mod']
    if mod not in ('SPRITE_VARIETY','DRAMATIC_MINI','FORTUNES_FAVOR','DECK_TILT','DRAMATIC_SHAPE','STADIUM_BATTLE_FX'):
        raise ValueError('Unsupported mod id')
    if not (game/'main.lua').is_file() or not (game/'mods').is_dir(): raise ValueError('Choose the game directory containing main.lua and mods/')
    # Fingerprint every known upstream host source file, not just its version label.
    for item in manifest['host_checks']:
        if not item['path'].startswith('src/'): raise ValueError('Invalid host check')
        p=safe(game,item['path'])
        if not p.is_file() or sha(bounded(p)) not in item['accepted']:
            raise ValueError('Host source differs from pinned 0.2.36/local baseline: '+item['path'])
    for item in manifest.get('dependency_checks',[]):
        if not item['path'].startswith('mods/'+mod+'/'): raise ValueError('Invalid dependency check')
        p=safe(game,item['path'])
        if not p.is_file() or sha(bounded(p)) not in item['accepted']:
            raise ValueError('Dependency differs from pinned baseline: '+item['path'])
    changes=[]; seen=set()
    for entry in manifest['files']:
        rel=entry['path']
        if rel in seen: raise ValueError('Duplicate target: '+rel)
        seen.add(rel)
        if not (rel.startswith('src/') and rel.endswith('.lua') or rel.startswith('mods/'+mod+'/')):
            raise ValueError('Target outside selected code: '+rel)
        target=safe(game,rel)
        if target.exists() and not target.is_file(): raise ValueError('Not a file: '+rel)
        before=bounded(target) if target.exists() else None
        actual=sha(before) if before is not None else None
        if actual==entry['after']: continue
        if actual not in entry['before']: raise ValueError('Unrecognized existing file; preserved without changes: '+rel)
        if 'source' in entry:
            source=safe(package,entry['source'])
            if not entry['source'].startswith('source/'+mod+'/'): raise ValueError('Invalid payload source')
            data=bounded(source)
        else: data=assemble(before or b'',entry)
        if sha(data)!=entry['after']: raise ValueError('Payload checksum mismatch: '+rel)
        changes.append((target,rel,before,data))
    return changes,manifest

def apply(game, changes, manifest):
    if not changes:return None
    backup=safe(game.parent,'mod-install-backups')
    backup.mkdir(exist_ok=True,mode=0o700)
    backup=backup/(datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')+'-'+uuid.uuid4().hex[:8]);backup.mkdir(mode=0o700)
    entries=[]
    # Keep every original before the first replacement. Recheck concurrent edits.
    for target,rel,before,data in changes:
        current=bounded(target) if target.exists() else None
        if current!=before: raise ValueError('File changed during preflight: '+rel)
        if before is not None:
            original=safe(backup,'before/'+rel);original.parent.mkdir(parents=True,exist_ok=True)
            with original.open('xb')as f:f.write(before);f.flush();os.fsync(f.fileno())
            if bounded(original)!=before:raise OSError('Backup verification failed')
        staged=safe(backup,'staged/'+rel);staged.parent.mkdir(parents=True,exist_ok=True)
        with staged.open('xb')as f:f.write(data);f.flush();os.fsync(f.fileno())
        entries.append({'path':rel,'before':sha(before) if before is not None else None,'after':sha(data)})
    journal={'mod':manifest['mod'],'files':entries,'status':'originals preserved; installation starting'}
    with(backup/'plan.json').open('x')as f:json.dump(journal,f,indent=2)
    for target,rel,before,data in changes:
        safe(game,rel)
        if (bounded(target) if target.exists() else None)!=before: raise ValueError('Concurrent change; stopped with backups at '+str(backup))
        target.parent.mkdir(parents=True,exist_ok=True)
        staged=safe(backup,'staged/'+rel)
        os.replace(staged,target)
        if sha(bounded(target))!=sha(data): raise OSError('Write verification failed: '+rel)
    with(backup/'completed.json').open('x')as f:json.dump({'status':'complete','files':len(changes)},f)
    return backup

def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--game',help='directory containing main.lua and mods/');ap.add_argument('--apply',action='store_true',help='apply the displayed plan with exact before-copies');args=ap.parse_args()
    package=Path(__file__).resolve().parent
    value=args.game or input('Game directory (contains main.lua and mods/): ').strip()
    raw=Path(value).expanduser().absolute()
    # Resolve a directory only after rejecting symlinks in its supplied path.
    current=Path(raw.anchor)
    for part in raw.parts[1:]:
        current=current/part
        if current.is_symlink():raise ValueError('Choose a real directory, not a symlink')
    game=raw.resolve();changes,manifest=plan(package,game)
    print(manifest['name']+' '+manifest['version']+' — '+str(len(changes))+' file changes')
    for _,rel,before,_ in changes:print(('ADD ' if before is None else 'PATCH ')+rel)
    if args.apply:
        backup=apply(game,changes,manifest)
        print('Installed. Original files: '+str(backup) if backup else 'Already matches this candidate.')
    else:print('Preview only. Apply this exact plan by repeating with --apply. Saves and settings are outside the plan.')
if __name__=='__main__':
    try:main()
    except (ValueError,OSError,KeyError,TypeError,UnicodeError)as e:
        print('Stopped: '+str(e),file=sys.stderr);sys.exit(1)
