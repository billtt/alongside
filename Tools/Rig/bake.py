"""Compile shared, layered skins and skeletal keys from Dada's hand-drawn reference.
Run with python3 Tools/Rig/bake.py (Pillow, NumPy, SciPy). The app only needs the output.
"""
from pathlib import Path
import json, math
from functools import lru_cache
import numpy as np
from scipy.ndimage import gaussian_filter, distance_transform_edt, map_coordinates
from PIL import Image
from side import walk_bind, walk_layers, walk_segments, walking_targets
from views import PARENTS,VIEWS

ROOT=Path(__file__).resolve().parents[2]
PET=ROOT/'Resources/Pets/Dada'
DEST=PET/'Rig'
DEST.mkdir(exist_ok=True)
SPEC=json.loads((PET/'pet.json').read_text())
BONES=list(PARENTS)
DRAW='farRear farRearFoot farArm farForearm farPaw trunk chest rear rearFoot tail tip arm forearm paw head'.split()
SIZE=112
yy,xx=np.mgrid[0:SIZE,0:SIZE].astype(float)
@lru_cache(None)
def img(f):return Image.open(PET/f).convert('RGBA')
@lru_cache(None)
def thumb(f):
    im=img(f).resize((SIZE,SIZE),Image.Resampling.LANCZOS)
    a=np.asarray(im,dtype=float)/255
    return a[:,:,3]*(.85-.48*a[:,:,:3].mean(axis=2)) + .45*a[:,:,3]*np.clip(a[:,:,0]-a[:,:,2],0,1)
def filename(s):return s+'.png'
def group(f):
    n=f.removesuffix('.png').split('/')[-1]
    if f in VIEWS:return [f]
    # The middle drawing shows the chest front-on. Preserve its place in the turn.
    turn_sequence={'turn-0':'settle-8','turn-1':'turn-2',
                   'prone-turn-1':'Motion/prone-turn-2','prone-turn-3':'settle-8',
                   'sit-turn-3':'settle-0','stand-turn-4':'Motion/stand-turn-3',
                   'stand-turn-6':'Motion/stand-turn-5','paw-high-1':'paw-aim-1',
                   'paw-high-3':'Motion/paw-high-2','paw-rest-3':'paw-rest-reach',
                   'nip-low-3':'nip-aim-0'}
    if n in turn_sequence:return [turn_sequence[n]+'.png']
    def candidates(*keys):return [filename(k) for k in keys]
    if n.startswith('walk-') and not n.startswith('walk-sit'):return candidates('walk-1')
    if n.startswith('step-down'):return candidates('walk-1','Motion/step-down-2','Motion/step-down-5','Motion/step-down-8')
    if n in ('hop-up-6','hop-up-7'):return candidates('Motion/hop-up-7','leap-2','Motion/hop-up-5')
    if n.startswith('hop-up') or n.startswith('leap'):return candidates('walk-1','leap-0','leap-1','Motion/hop-up-1','Motion/hop-up-3','Motion/hop-up-5','Motion/step-down-2','leap-2')
    if n.startswith('carry'):return candidates('carry-0','carry-2')
    if n.startswith('release'):return candidates('carry-0','Motion/release-1','Motion/release-2','leap-0','leap-2','walk-1')
    if 'back' in n:return candidates('turn-5','back-2','Motion/back-wake-2')
    if n.startswith('stand-turn'):
        i=int(n.split('-')[-1])
        if i<=3:return candidates('settle-8','settle-6','Motion/walk-sit-2','Motion/hop-up-1','Motion/stand-turn-5')
        if i<=7:return candidates('Motion/stand-turn-5','Motion/stand-turn-8','walk-1','Motion/hop-up-7')
        if i<=10:return candidates('Motion/stand-turn-9','Motion/stand-turn-11')
        return candidates('Motion/stand-turn-11','Motion/stand-turn-13','turn-5')
    if n.startswith('walkToTurn'):return candidates('walk-1','Motion/stand-turn-5','Motion/stand-turn-8')
    if n.startswith(('walk-sit','sitToStand')):return candidates('walk-1','leap-0','settle-4','settle-0','nip-1','Motion/stand-turn-5','Motion/walk-sit-2','Motion/hop-up-1')
    if n.startswith('settle'):return candidates('settle-0','settle-2','settle-4','settle-6','settle-8')
    if n.startswith('turn-'):return candidates('settle-8','turn-2','turn-3','turn-4','turn-5')
    if n.startswith('sit-turn'):return candidates('settle-0','Motion/sit-turn-2')
    if n.startswith('prone-turn'):return candidates('settle-8')
    if n.startswith('side-prone'):return candidates('side-0','settle-8')
    if n.startswith('loaf-prone'):return candidates('loaf-0','settle-8')
    action=n.split('-')[0]
    if '-rest' in n or '-flank' in n:
        peak='Motion/'+action+'-flank-3' if '-flank' in n else action+'-rest-reach'
        return candidates('settle-8',peak)
    if action in ('paw','swat','nip'):
        direction=n.split('-')[1]
        idx={'low':0,'mid':1,'high':2}.get(direction)
        if direction=='side' and action in ('paw','swat'):return candidates('settle-0','Motion/'+action+'-side-2',action+'-1')
        if idx is None:return candidates('settle-0',action+'-aim-1',action+'-1','swat-0','Motion/'+action+'-side-2') if action in ('paw','swat') else candidates('settle-0','nip-1')
        return candidates('settle-0',action+'-aim-'+str(idx),action+'-aim-1','swat-0')
    raise ValueError(f)
def nearest(f):
    dst=thumb(f)
    def cost(s):
        diff=thumb(s)-dst
        return np.mean(gaussian_filter(diff,1.5)**2)+.3*np.mean(diff**2)
    return min(group(f),key=cost)
def flow(source,target):
    # Coarse-to-fine local Lucas-Kanade. Smoothed flow carries joint landmarks
    # between paintings with different crops, leaving the texture itself rigid.
    dx=np.zeros_like(xx);dy=np.zeros_like(xx)
    for blur,window,iters in [(3.5,7,10),(1.65,4.8,9),(.7,3.5,7)]:
        a=gaussian_filter(source,blur);b=gaussian_filter(target,blur);gy,gx=np.gradient(b)
        def local(q):return gaussian_filter(q,window)
        for _ in range(iters):
            coords=[yy+dy,xx+dx]
            def at(field):return map_coordinates(field,coords,order=1,mode='nearest')
            ex=at(gx);ey=at(gy);err=a-at(b)
            ax=local(ex*ex)+.00011;ay=local(ey*ey)+.00011;axy=local(ex*ey)
            bx=local(ex*err);by=local(ey*err);det=ax*ay-axy*axy
            dx=gaussian_filter(dx+np.clip((ay*bx-axy*by)/det,-2,2),1.0)
            dy=gaussian_filter(dy+np.clip((ax*by-axy*bx)/det,-2,2),1.0)
    return np.stack([dx,dy])
def guides(s):
    w,h=img(s).size; src=VIEWS[s];g={}
    for n in BONES:
        if n in src:g[n]=np.array(src[n],float)*[w/100,h/100]
        else:
            p=g[PARENTS[n]][0]
            g[n]=np.array([p,p+np.array([w*.06,h*.06])])
    return g

def compile_skin(s,index):
    rgba=np.array(img(s));h,w=rgba.shape[:2];alpha=rgba[:,:,3]
    y,x=np.mgrid[:h,:w];g=guides(s);fields=[]
    # Assign visible pixels to anatomical pieces. Rear pieces extend beneath
    # foreground pieces, filled from their own fur at the joint boundary.
    widths={'trunk':.31,'chest':.24,'head':.245,'tail':.10,'tip':.09,'rear':.16,'rearFoot':.09,
            'arm':.12,'forearm':.11,'paw':.083,'farArm':.11,'farForearm':.095,'farPaw':.076,'farRear':.13,'farRearFoot':.08}
    for n in DRAW:
        a,b=g[n];v=b-a
        t=np.clip(((x-a[0])*v[0]+(y-a[1])*v[1])/np.dot(v,v),0,1)
        # Nearer limbs own their outline and the face owns both ears and muzzle.
        sx,sy=(1.0,1.0)
        if n=='head':sx,sy=(1.20,1.08)
        score=(((x-a[0]-t*v[0])/(w*sx))**2+((y-a[1]-t*v[1])/(h*sy))**2)/widths[n]**2
        if n in ['head','paw','farPaw']:score-=.12
        if n not in VIEWS[s]:score[:]=1e6
        fields.append(score)
    owner=np.argmin(fields,axis=0)
    images=[];entries=[];pads=[]
    order=list(range(len(DRAW)))
    if 'aim-2' in s and ('paw' in s or 'swat' in s):order.remove(DRAW.index('head'));order.insert(order.index(DRAW.index('arm')),DRAW.index('head'))
    for layer,i in enumerate(order):
        n=DRAW[i];own=(owner==i)&(alpha>0)
        if own.sum()<8:continue
        dist,near=distance_transform_edt(~own,return_indices=True)
        under=np.isin(owner,order[layer+1:])
        reach=max(5,min(w,h)*(.14 if n in ('trunk','chest') else .075))
        opacity=np.where(own,1,np.where(under,np.clip(1-dist/reach,0,1),0))
        solid=own&(alpha>160)
        pigment=distance_transform_edt(~solid,return_distances=False,return_indices=True) if solid.any() else near
        color=np.where(own[:,:,None],rgba[:,:,:3],rgba[pigment[0],pigment[1],:3])
        # Hidden joint caps sit below all the visible layers. If either neighbour
        # swings away, the newly exposed area still has the moving piece's fur.
        seam=(dist>0)&(dist<reach)&(alpha>40)
        support=np.uint8(np.clip((1-dist/reach)*4,0,1)*alpha*seam)
        if support.any():
            pad=Image.fromarray(np.dstack([color,support]))
            bb=pad.getchannel('A').getbbox()
            pads.append((pad.crop(bb),dict(bone=BONES.index(n),origin=list(bb[:2]))))
        part=np.dstack([color,np.rint(opacity*alpha).astype(np.uint8)])
        piece=Image.fromarray(part);box=piece.getchannel('A').getbbox();piece=piece.crop(box)
        entries.append(dict(bone=BONES.index(n),origin=list(box[:2])))
        images.append(piece)
    images=[pad for pad,_ in pads]+images;entries=[item for _,item in pads]+entries
    return pack(s.removesuffix('.png').replace('Motion/','')+'-parts.png',images,entries,g,(w,h))

def pack(name,images,entries,g,size):
    # Shelf atlas with transparent gutters. Atlas coordinates are top-left pixels.
    cap=max(768,max(i.width for i in images));px=py=height=0
    for im,item in zip(images,entries):
        if px+im.width>cap:px=0;py+=height+2;height=0
        item['crop']=[px,py,im.width,im.height];px+=im.width+2;height=max(height,im.height)
    atlas=Image.new('RGBA',(max(e['crop'][0]+e['crop'][2] for e in entries),py+height))
    for im,item in zip(images,entries):atlas.paste(im,item['crop'][:2])
    atlas.save(DEST/name,optimize=True)
    return dict(atlas=name,size=size,parts=entries,bind=[basis(g[n]) for n in BONES])
def basis(seg):
    a,b=seg;v=b-a;l=np.linalg.norm(v)
    return [round(float(x),5) for x in [*a,math.atan2(v[1],v[0]),l,l]]
def pose(f,s,spec):
    w,h=img(f).size;sw,sh=img(s).size;g=guides(s);base=thumb(s);dst=thumb(f)
    reversed_view=f in ['Motion/sit-turn-3.png','Motion/prone-turn-3.png']
    if reversed_view:dst=dst[:,::-1]
    delta=flow(base,dst) if f!=s else np.zeros((2,SIZE,SIZE))
    points={}
    for n,(a,b) in g.items():
        seg=np.array([a,b]);uv=seg/[sw,sh]
        xy=uv*SIZE-.5
        shifts=np.stack([map_coordinates(channel,[xy[:,1],xy[:,0]],order=1,mode='nearest') for channel in delta],axis=1)
        # Bound independently estimated motion at occlusion boundaries. A tip
        # that disappears behind a leg must not inherit the leg's flow vector.
        shift=np.clip(shifts[0]/SIZE,-.016,.016)
        A=(uv[0]+shift)*[w,h]
        rest=(uv[1]-uv[0])*[w,h]
        observed=rest+(shifts[1]-shifts[0])/SIZE*[w,h]
        ang=math.atan2(rest[1],rest[0]);raw=math.atan2(observed[1],observed[0])-ang
        theta=ang+np.clip(math.atan2(math.sin(raw),math.cos(raw)),-.055,.055)
        length=np.clip(np.linalg.norm(observed),np.linalg.norm(rest)*.98,np.linalg.norm(rest)*1.02)
        points[n]=[A,A+length*np.array([math.cos(theta),math.sin(theta)])]
    # Fit local width independently of rotation. Large aspect changes occur when
    # the animal sits or projects a paw toward the viewer.
    world=[]
    for n in BONES:
        a,b=g[n];A,B=points[n];v=b-a;L=max(1,np.linalg.norm(v));v=v/L
        natural=(b-a)*[w/sw,h/sh];new=B-A;length=max(1,np.linalg.norm(new))
        angle=math.atan2(new[1],new[0]);normal=np.array([-v[1],v[0]])*[w/sw,h/sh]
        width=max(1,L*np.linalg.norm(normal))
        world.append([round(float(x),5) for x in [*A,angle,length,width]])
    return dict(skin=s,mirrored=reversed_view,size=[w,h],bones=world)
def main():
    refs={v['file']:v for vals in SPEC['clips'].values() for v in vals}
    chosen={f:nearest(f) for f in refs}
    skins={s:compile_skin(s,i) for i,s in enumerate(sorted(set(chosen.values())))}
    poses={f:pose(f,s,refs[f]) for f,s in chosen.items()}
    side='walk-1.png';g=walk_bind(guides(side));sw,sh=img(side).size
    layers=walk_layers(img(side))
    skins['walking']=pack('walking-parts.png',[im for _,im,_ in layers],
                          [dict(bone=BONES.index(n),origin=list(o)) for n,_,o in layers],g,(sw,sh))
    strides={f'walk-{i}.png':i for i in range(6)}
    strides.update({'Motion/hop-up-0.png':0,'Motion/step-down-11.png':0,
                    'Motion/walkToTurn-0.png':0,'Motion/walkToTurn-1.png':1,
                    'Motion/walk-sit-0.png':0})
    # Six key poses are shared with the behaviour graph. Intermediate samples
    # store joint transforms for the same cutouts and give IK an accurate arc.
    strides={key:i*6 for key,i in strides.items()}
    strides.update({f'gait-{i}':i for i in range(36) if i%6})
    reference=refs[side]
    travel=SPEC['temperament']['walkSpeed']*1.14/reference['unitsPerPixel']
    for key,i in strides.items():
        virtual=key.startswith('gait-')
        w,h=(sw,sh) if virtual else img(key).size
        phase=i/36
        targets=walking_targets(phase,(sw,sh),travel)
        segments=walk_segments(g,phase,targets,np.array([sw,sh]))
        bones=[]
        for n in BONES:
            if virtual or key.startswith('walk-'):
                # Crop changes across the source drawings must not expand the
                # skull or move a planted toe. Keep the anchor and floor fixed.
                anchor=refs.get(key,reference)['anchorX']
                segment=segments[n]+[anchor-reference['anchorX'],h-sh]
                joint=basis(segment)
                joint[4]=basis(g[n])[4]
            else:
                joint=basis(segments[n]*[w/sw,h/sh])
                axis=g[n][1]-g[n][0]
                joint[4]=round(float(np.linalg.norm(np.array([-axis[1],axis[0]])*[w/sw,h/sh])),5)
            bones.append(joint)
        poses[key]=dict(skin='walking',mirrored=False,size=[w,h],bones=bones)
    (DEST/'rig.json').write_text(json.dumps(dict(bones=[dict(name=n,parent=BONES.index(PARENTS[n]) if PARENTS[n] else -1) for n in BONES],skins=skins,poses=poses),separators=(',',':'))+'\n')
    print(len(skins),'layered skins,',len(poses),'poses,',sum(len(s['parts']) for s in skins.values()),'attachments')
if __name__=='__main__':main()
