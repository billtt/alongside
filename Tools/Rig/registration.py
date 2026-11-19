"""Register neighbouring skeletal projections from the native composited key poses."""
import base64
import json
from functools import lru_cache
from pathlib import Path

import numpy as np
from PIL import Image
from scipy.ndimage import distance_transform_edt, gaussian_filter, map_coordinates, label, center_of_mass

GRID=41
DIST=96

def edges(spec,poses):
    pairs=set()
    def join(files,turn=False):
        for i,(a,b) in enumerate(zip(files,files[1:])):
            flip=bool(turn and i==len(files)-2)
            if a!=b and (poses[a]['skin']!=poses[b]['skin'] or flip or poses[a]['mirrored']!=poses[b]['mirrored']):
                pairs.update(((a,b,flip),(b,a,flip)))
    clips={k:[s['file'] for s in v] for k,v in spec['clips'].items()}
    for files in clips.values():join(files)
    for track in spec['transitions']:
        join([track['start'],*clips[track['through']],track['end']],track.get('turnsAround',False))
    stride=clips['walk'][0]
    join([stride,*clips['stepDown'],stride])
    join([stride,*clips['hopUp'][:4],clips['leap'][1],*clips['hopUp'][4:],stride])
    join([*clips['release'],clips['hopUp'][7],stride])
    return sorted(pairs)

def encode(values):
    return base64.b64encode(np.ascontiguousarray(values).tobytes()).decode('ascii')

def limit_strain(vectors,pins):
    # Bound the displacement gradient in both lattice directions. Each column
    # of its Jacobian has norm <= .52, so I+t*J stays nonsingular for 0<=t<=1.
    # Alternate disjoint edges to preserve translations where the field agrees.
    field=vectors.copy()
    bound=.52/(GRID-1)
    for iteration in range(100):
        excess=0.
        for direction,locked in ((field,pins),(field.swapaxes(0,1),pins.T)):
            for start in (0,1):
                first=direction[start:-1:2]
                last=direction[start+1::2]
                delta=last-first
                norm=np.linalg.norm(delta,axis=2,keepdims=True)
                excess=max(excess,float(norm.max())-bound)
                shift=np.maximum(0.,1-bound/np.maximum(norm,1e-12))*delta
                wa=1-.995*locked[start:-1:2][...,None]
                wb=1-.995*locked[start+1::2][...,None]
                first+=shift*wa/(wa+wb)
                last-=shift*wb/(wa+wb)
        if excess<.00004:break
    max_step=max(np.linalg.norm(np.diff(field,axis=axis),axis=2).max() for axis in (0,1))
    center=np.average(field.reshape(-1,2),axis=0,weights=(1+20*pins).ravel())
    return center+(field-center)*min(1.,bound/max(max_step,1e-12))

def rigid_face(vectors,pose,target,head_index,eyes_a,eyes_b):
    # Match the entire cheek and eye region with one similarity transform.
    # Outside the head the collar blends into the measured motion of the neck.
    size=np.array(pose['size'])
    target_size=np.array(target['size'])
    x,y,angle,length,_=pose['bones'][head_index]
    center=np.array([x,y])+length*.48*np.array([np.cos(angle),np.sin(angle)])
    if pose['mirrored']:center[0]=size[0]-center[0]
    yy,xx=np.mgrid[:GRID,:GRID]/(GRID-1)
    uv=np.stack([xx,yy],axis=-1)
    pts=uv*size
    radius=np.linalg.norm((pts-center)/max(8.,length),axis=2)
    inner=radius<1.05
    if inner.sum()<5:return vectors,np.zeros((GRID,GRID))
    a=pts[inner]
    b=((uv+vectors)*target_size)[inner]
    am,bm=a.mean(axis=0),b.mean(axis=0)
    aa,bb=a-am,b-bm
    denominator=np.sum(aa*aa)
    real=np.sum(aa*bb)/denominator
    imag=np.sum(aa[:,0]*bb[:,1]-aa[:,1]*bb[:,0])/denominator
    turn=np.clip(np.arctan2(imag,real),-.24,.24)
    global_scale=np.sqrt(np.prod(target_size/size))
    scale=np.clip(np.hypot(real,imag),.88*global_scale,1.12*global_scale)
    rotation=scale*np.array([[np.cos(turn),np.sin(turn)],[-np.sin(turn),np.cos(turn)]])
    if len(eyes_a) and len(eyes_b):
        first=eyes_a*size
        last=eyes_b*target_size
        predicted=(first-am)@rotation+bm
        if len(first)==len(last)==2:
            pairs=list(zip(first,last))
            # Eyeline tilt follows the two visible pupils; yaw can narrow their
            # spacing, so the skull scale remains that of the cheek estimate.
            direction_a=first[1]-first[0];direction_b=last[1]-last[0]
            theta=np.arctan2(direction_b[1],direction_b[0])-np.arctan2(direction_a[1],direction_a[0])
            theta=np.clip(np.arctan2(np.sin(theta),np.cos(theta)),-.28,.28)
            rotation=scale*np.array([[np.cos(theta),np.sin(theta)],[-np.sin(theta),np.cos(theta)]])
        else:
            distances=np.linalg.norm((predicted[:,None,:]-last[None,:,:])/target_size,axis=2)
            i,j=np.unravel_index(np.argmin(distances),distances.shape)
            pairs=[(first[i],last[j])]
        source_eye=np.mean([a for a,_ in pairs],axis=0)
        dest_eye=np.mean([b for _,b in pairs],axis=0)
        if np.linalg.norm(((source_eye-am)@rotation+bm-dest_eye)/target_size)<.20:
            am,bm=source_eye,dest_eye
            # Use the visible face to locate the rigidity constraint, including
            # on the three-quarter turn where the nominal joint is occluded.
            width=length*1.45
            if len(first)==2:width=max(width,np.linalg.norm(first[1]-first[0])*1.95)
            # Ears and the whisker pads travel with the skull. Include the
            # transparent margin above the ears so the contour stays registered.
            rel=(pts-source_eye)/max(8.,width)
            radius=np.maximum(abs(rel[:,:,0]),np.maximum(rel[:,:,1],-.64*rel[:,:,1]))

    fit=((pts-am)@rotation+bm)/target_size-uv
    weight=np.clip((1.55-radius)/.5,0,1)
    weight=(weight*weight*(3-2*weight))[...,None]
    return vectors+(fit-vectors)*weight,weight[:,:,0]

def register(spec,poses,rendered,flow,size,head):
    files={s['file']:rendered/(k+'-'+str(i)+'.png') for k,clip in spec['clips'].items() for i,s in enumerate(clip)}
    @lru_cache(None)
    def features(name):
        im=np.asarray(Image.open(files[name]).convert('RGBA').resize((size,size),Image.Resampling.LANCZOS),float)/255
        rgb=im[:,:,:3];alpha=im[:,:,3]
        lum=(1-rgb.mean(axis=2))*alpha
        return .8*lum+np.clip(3*(lum-gaussian_filter(lum,3)),-.32,.32)+alpha*(rgb[:,:,0]-rgb[:,:,2])*.75
    @lru_cache(None)
    def eyes(name):
        im=np.asarray(Image.open(files[name]).convert('RGBA'),dtype=float)
        h,w=im.shape[:2];r,g,b,a=np.moveaxis(im,-1,0)
        gold=(r-b>28)&(g-b>10)&(r>100)&(a>190)
        labels,count=label(gold)
        if not count:return np.empty((0,2))
        ids=np.arange(1,count+1)
        areas=np.bincount(labels.ravel())[1:]
        keep=ids[areas>max(5,w*h*.00016)]
        keep=sorted(keep,key=lambda i:areas[i-1],reverse=True)[:2]
        centers=[(x/w,y/h) for y,x in center_of_mass(gold,labels,keep)] if keep else []
        return np.array(sorted(centers),dtype=float).reshape(-1,2)
    masks={}
    fields={}
    yy,xx=np.mgrid[:GRID,:GRID]*(size/(GRID-1))-.5
    for a,b,flip in edges(spec,poses):
        if a not in masks:
            alpha=Image.open(files[a]).convert('RGBA').getchannel('A').resize((DIST,DIST),Image.Resampling.LANCZOS)
            mask=np.pad(np.asarray(alpha)>127,1)
            sd=(distance_transform_edt(mask)-distance_transform_edt(~mask))[1:-1,1:-1]
            masks[a]=encode(np.int8(np.clip(np.rint(sd*4),-127,127)))
        target=features(b)
        motion=flow(features(a),target[:,::-1] if flip else target)
        # Constrain strain of the registration grid near occluding contours.
        # Motion inside unchanged views is supplied exclusively by the bones.
        smooth=np.stack([gaussian_filter(channel,1.2) for channel in motion])
        vectors=np.stack([map_coordinates(c,[yy,xx],order=1,mode='nearest') for c in smooth],axis=-1)/size
        landmarks=eyes(b).copy()
        if flip and len(landmarks):
            landmarks[:,0]=1-landmarks[:,0]
            landmarks=landmarks[::-1]
        vectors=limit_strain(*rigid_face(vectors,poses[a],poses[b],head,eyes(a),landmarks))
        fields['|'.join((a,b,'1' if flip else '0'))]=encode(np.rint(np.clip(vectors,-.35,.35)*32767).astype('<i2'))
    return dict(grid=GRID,dist=DIST,fields=fields,masks=masks)

if __name__=='__main__':
    import sys
    from bake import SPEC,DEST,SIZE,flow
    rig=json.loads((DEST/'rig.json').read_text())
    data=register(SPEC,rig['poses'],Path(sys.argv[1]),flow,SIZE,[b['name'] for b in rig['bones']].index('head'))
    (DEST/'projection.json').write_text(json.dumps(data,separators=(',',':'))+'\n')
