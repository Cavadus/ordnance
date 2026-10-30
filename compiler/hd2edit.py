# Reusable HD2 offline-edit primitives (persistent; rebuild artifacts under this dir, NOT /tmp)
import struct
import numpy as np
from nacl.bindings import crypto_box_seal_open, crypto_box_seal

GAME=None

# The game's sealed-box keypair (hex), as shipped in the game itself.
PK = bytes.fromhex('2dc9aa7c30e6eed5f7fd0e0e95c7287299b126f79520cc41de750982ee7ff50c')
SK = bytes.fromhex('a0296b81310b58f013d8a9b343a1c292008003dfd9ab15fcf351543048b49b64')
MUL=0xC6A4A7935BD1E995
INV=0x5F7A0EA7E59B19BD
SEED=16045690983977655786
MASK=0xFFFFFFFFFFFFFFFF
NEEDLE=b'LDLD\x01\x00\x00\x00'
MUL_np=np.uint64(MUL); INV_np=np.uint64(INV)

def mix(v):
    v=(v*MUL)&MASK; v^=v>>47; v=(v*MUL)&MASK; return v
def unmix(v):
    v=(v*INV)&MASK; v^=v>>47; v=(v*INV)&MASK; return v
def rd64(p,o): return struct.unpack_from('<Q',p,o)[0]
def wr64(p,o,v): struct.pack_into('<Q',p,o,v&MASK)
def u32(p,o): return struct.unpack_from('<I',p,o)[0]
def f32(p,o): return struct.unpack_from('<f',p,o)[0]
def put_u32(p,o,v): struct.pack_into('<I',p,o,v)
def put_f32(p,o,v): struct.pack_into('<f',p,o,v)

def tail_word(p,n):
    t=0; whole=n-n%8
    for i in range(n-1,whole-1,-1): t=(t<<8)|p[i]
    return t,whole
def forward(h,p,a,b):
    for i in range(a,b,8):
        h=((h^mix(rd64(p,i)))*MUL)&MASK
    return h
def backward(h,p,a,b):
    for i in range(b-8,a-8,-8):
        h=((h*INV)&MASK)^mix(rd64(p,i))
    return h
def murmur64(p):
    n=len(p); h=(SEED^((n*MUL)&MASK))&MASK
    t,whole=tail_word(p,n); h=forward(h,p,0,whole)
    if whole<n: h=((h^t)*MUL)&MASK
    h^=h>>47; h=(h*MUL)&MASK; h^=h>>47
    return h
def before_final(target,p,n):
    h=target; h^=h>>47; h=(h*INV)&MASK; h^=h>>47
    t,whole=tail_word(p,n)
    if whole<n: h=((h*INV)&MASK)^t
    return h,whole
def headers(p):
    n=len(p); out=[]; at=p.find(NEEDLE,0,64)
    while at!=-1 and at+24<=n:
        typ,size=struct.unpack_from('<II',p,at+8); out.append((at,typ,size))
        nxt=at+24+size; at=p.find(NEEDLE,nxt,nxt+64)
    return out

def correct(p, target, edited_floats=None):
    """Generalized in-place hash correction. p bytearray; target = pre-edit murmur64.
    Handles multi-header (byte-pair salt) and single-header (float-salt) files."""
    n=len(p); hs=headers(bytes(p))
    for at,typ,size in hs:
        assert p[at+16]==1
        for k in range(17,24): assert p[at+k]==0
    if murmur64(p)==target: return (0,0)
    X=None; aligned=False
    for at,typ,size in reversed(hs):
        if at%8==0 and at>0: X=at; aligned=True; break
    if X is None: X=hs[-1][0]; aligned=False
    words_end=X+24 if aligned else X+28
    first=X+16 if aligned else X+12
    final,whole=before_final(target,p,n)
    start=(SEED^((n*MUL)&MASK))&MASK
    slots=[('bytes',at+17,at+18) for at,typ,size in hs if at!=X]
    for o in (edited_floats or []): slots.append(('float',o))
    slots.sort(key=lambda s: abs(s[1]-X))
    fixed12=hi20=varr=None
    if not aligned:
        fixed12=rd64(p,X+12)&0xFFFFFFFFFF
        hi20=rd64(p,X+20)>>32
        w12=np.uint64(fixed12)|(np.arange(1<<24,dtype=np.uint64)<<np.uint64(40))
        a=(w12*MUL_np); del w12
        a^=(a>>np.uint64(47)); varr=(a*MUL_np); del a
    for slot in slots:
        if slot[0]=='bytes':
            _,s1,s2=slot; lo=s1-s1%8; hi=(s2-s2%8)+8
            orig_b=[p[s1],p[s2]]; is_float=False; tries=65535
            before_slot=forward(start,p,0,lo)
            after_slot=backward(final,p,words_end,whole)
        else:
            _,fo=slot; lo=fo-fo%8; hi=lo+8
            orig_fp=u32(p,fo); is_float=True; tries=4095
            before_slot=forward(start,p,0,first)
            after_slot=backward(final,p,hi,whole)
        def put(salt):
            if is_float: put_u32(p,fo,orig_fp^salt)
            else: p[s1]=salt&0xFF; p[s2]=(salt>>8)&0xFF
        def restore():
            if is_float: put_u32(p,fo,orig_fp)
            else: p[s1]=orig_b[0]; p[s2]=orig_b[1]
        hi_after_first=hi>first
        for salt in range(1,tries+1):
            put(salt)
            if hi_after_first:
                h_before=before_slot
                after=backward(after_slot,p,words_end,hi)
            else:
                h_before=forward(before_slot,p,lo,first)
                after=after_slot
            if aligned:
                m=((after*INV)&MASK)^h_before; w=unmix(m)
                if (w&0xFF)==1:
                    wr64(p,X+16,w); return (salt,0)
            else:
                need=(after*INV)&MASK
                m20=((np.uint64(h_before)^varr)*MUL_np)^np.uint64(need)
                u=(m20*INV_np); u^=(u>>np.uint64(47)); u=(u*INV_np)
                hit=(u>>np.uint64(32))==np.uint64(hi20)
                idx=np.flatnonzero(hit)
                if idx.size:
                    t=int(idx[0])
                    wr64(p,X+12,fixed12|(t<<40)); wr64(p,X+20,int(u[idx[0]]))
                    return (salt,t)
        restore()
    raise RuntimeError('no hash correction found')

print('hd2edit primitives loaded')
