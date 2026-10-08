#!/usr/bin/env python3
"""Per-screen release check.  usage: python3 release_check.py <previous AdminConsole zip> [--bump NEWVERSION]
Compares every screen file in the tree with the previous release zip IGNORING comments, blank lines, the version header and the VERSIONS list.
  - a file whose real content changed must carry a NEW 'Screen version:' header  -> reported as NEEDS BUMP (with --bump it is bumped to NEWVERSION)
  - a file that did not change must keep its old header                          -> reported as same
Prints the list for the 's' field of the new VERSIONS entry: [["Screen name","updated"|"new"], ...]"""
import sys,re,zipfile,os,json
ROOT=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
zp=sys.argv[1];bump=sys.argv[sys.argv.index('--bump')+1] if '--bump' in sys.argv else None
zf=zipfile.ZipFile(zp);old={}
for n in zf.namelist():
    b=os.path.basename(n)
    if re.match(r'(Screen-.+\.ps1|ActivityLog\.ps1|DistGroups-Worker\.ps1|server\.ps1|index\.html|login\.html)$',b) and not n.startswith('PasswordReset/Tools/'):old[b]=zf.read(n).decode('utf-8-sig')
def core(t):
    out=[]
    for l in t.replace('\r\n','\n').split('\n'):
        s=l.strip()
        if not s or s.startswith('#') or s.startswith('//') or s.startswith('<!--') or s.startswith('const VERSIONS=') or '$AppVersion' in l:continue
        s=re.sub(r'\s+',' ',s);s=re.sub(r'\bv?[0-9]+\.[0-9]+\.[0-9]+\b','V',s);s=re.sub(r'\s+#.*$','',s) if not re.search(r"['\"].*#.*['\"]",s) else s;s=re.sub(r'content="[\d.]+"|content="__APPVER__"','',s)
        out.append(s)
    return '\n'.join(out)
hdr=re.compile(r'(Screen version:\s*)([0-9][0-9.]*)')
res=[]
for dp,dn,fn in os.walk(ROOT):
    for f in fn:
        if f not in old and not re.match(r'(Screen-.+\.ps1|ActivityLog\.ps1|DistGroups-Worker\.ps1|server\.ps1|index\.html|login\.html)$',f):continue
        if '/Tools/' in dp+'/':continue
        p=os.path.join(dp,f);raw=open(p,'rb').read();bom=raw.startswith(b'\xef\xbb\xbf');t=raw.decode('utf-8-sig')
        nm=re.search(r'Screen:\s*([^|\r\n]+?)\s*(?:\||-->|\r|\n|$)',t[:600]);nm=nm.group(1).strip() if nm else f
        cur=hdr.search(t[:900]);cur=cur.group(1+1) if cur else ''
        if f not in old:res.append((nm,'new',cur,'new file'));continue
        oh=hdr.search(old[f][:900]);oh=oh.group(2) if oh else ''
        changed=core(old[f])!=core(t)
        if changed and cur==oh:
            if bump:
                t=hdr.sub(lambda m:m.group(1)+bump,t,count=1);open(p,'wb').write((b'\xef\xbb\xbf' if bom else b'')+t.encode('utf-8'));res.append((nm,'updated',bump,'bumped from '+oh))
            else:res.append((nm,'updated',cur,'NEEDS BUMP (header still %s)'%oh))
        elif changed:res.append((nm,'updated',cur,'ok (header %s -> %s)'%(oh,cur)))
        elif cur!=oh:res.append((nm,'same',cur,'header changed without code change (%s -> %s)'%(oh,cur)))
for r in sorted(res):print('%-8s %-45s %-8s %s'%(r[1],r[0],r[2],r[3]))
print(json.dumps([[r[0],r[1]] for r in res if r[1] in('new','updated')]))
