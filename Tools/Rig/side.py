"""Build the independent, overlapping side-view PNG attachments from Dada's walk painting."""
import re
import numpy as np
from PIL import Image, ImageDraw, ImageFilter
from scipy.ndimage import distance_transform_edt, gaussian_filter

def side_pieces(painting):
    im=painting.convert('RGBA')
    src=np.array(im);H,W=src.shape[:2];Y,X=np.mgrid[:H,:W]
    def shape(spec):
        tokens=iter(re.findall(r'[MLQCZ]|-?\d+(?:\.\d+)?',spec)); pts=[];cur=np.zeros(2)
        def point(): return np.array([float(next(tokens)),float(next(tokens))])
        for cmd in tokens:
            if cmd in ('M','L'): cur=point();pts.append(cur)
            elif cmd in ('C','Q'):
                controls=[cur,point(),point()];controls+=[point()] if cmd=='C' else []
                for t in np.linspace(0,1,16)[1:]:
                    p=np.array(controls)
                    while len(p)>1:p=(1-t)*p[:-1]+t*p[1:]
                    pts.append(p[0])
                cur=controls[-1]
        m=Image.new('L',(W*4,H*4));ImageDraw.Draw(m).polygon([tuple(p*4) for p in pts],fill=255)
        return np.asarray(m.resize(im.size,Image.Resampling.LANCZOS)).astype(float)/255
    def smooth(a,b,x):
        v=np.clip((x-a)/(b-a),0,1);return v*v*(3-2*v)
    # Preserve the existing ink at exposed contours. Paint complete overlaps inside the silhouette.
    def fur(known):
        iy,ix=distance_transform_edt(~known,return_distances=False,return_indices=True)
        nearest=src[iy,ix,:3].astype(float)
        grain=np.random.default_rng(8).normal(0,2.2,(H,W))
        fill=gaussian_filter(nearest,(6,6,0))+grain[:,:,None]
        alpha=gaussian_filter(known.astype(float),2) * known
        return np.clip(src[:,:,:3]*alpha[:,:,None]+fill*(1-alpha[:,:,None]),0,255)
    A=src[:,:,3]/255
    paint=fur(A>.78)
    def save(name,mask,rgb,shade=1):
        out=np.uint8(np.clip(np.dstack([rgb*shade,mask*255]),0,255))
        img=Image.fromarray(out);box=img.getchannel('A').getbbox()
        specs[name]=(img.crop(box), box[:2])
    specs={}
    body=shape('M 74 72 C 74 43 86 21 119 17 C 146 14 157 6 180 9 C 214 11 228 20 252 15 C 276 9 293 4 322 3 C 369 -2 413 17 433 52 C 448 75 453 104 439 131 C 430 153 405 182 367 191 C 332 199 298 205 269 203 C 229 200 199 196 164 188 C 134 183 111 173 94 157 C 76 141 68 108 74 72 Z')
    # On the back, follow the painting's original fur-edged silhouette.
    body=np.where((Y<52)&(X>111)&(X<430),A*shape('M 109 -1 L 442 -1 L 442 57 L 109 57 Z'),body)
    known=(A>.8)&(body>.9)
    known&= ~(((X<154)&(Y>17))|((X>153)&(X<242)&(Y>40+0.28*(X-150)))|((X>304)&(X<430)&(Y>45)))
    valid=known.astype(float)
    den=gaussian_filter(valid,24)
    rgbmean=np.stack([gaussian_filter(src[:,:,channel]*valid,24)/np.maximum(.000001,den) for channel in range(3)],axis=2)
    basecoat=np.array([111.,103.,109.])[None,None,:]-smooth(72,204,Y)[:,:,None]*19
    denWeight=smooth(.025,.22,den)[:,:,None]
    fill=rgbmean*denWeight+basecoat*(1-denWeight)
    grain=gaussian_filter(np.random.default_rng(14).normal(0,2.7,(H,W)),.5)
    keep=smooth(0,15,distance_transform_edt(known))[:,:,None]
    bodyrgb=src[:,:,:3]*keep+(fill+grain[:,:,None])*(1-keep)
    edge=np.clip(distance_transform_edt(body>.5),0,10)
    bodyrgb-=((1-smooth(0,4,edge))*8*((Y>120)|(X>429)))[:,:,None]
    save('torso',body,bodyrgb)
    head=shape('M -2 -2 L 80 -2 Q 83 17 99 24 Q 115 30 123 44 L 121 41 Q 134 59 131 76 L 133 73 Q 133 94 119 110 L 121 106 Q 117 120 106 126 L 109 122 Q 99 133 88 132 Q 75 129 65 124 L -2 150 Z')*A
    head*=1-(1-smooth(0,4,distance_transform_edt(head>.5)))*.64*smooth(74,113,X)*smooth(13,42,Y)
    save('head',head,src[:,:,:3])
    tail=shape('M 403 65 C 417 55 431 53 438 57 C 455 75 461 97 475 122 C 491 150 508 162 530 166 Q 558 171 551 195 Q 542 222 506 215 C 480 209 463 187 452 169 Q 443 153 432 144 Q 406 105 403 65 Z')
    # Only the rear and the underside of the tail are exposed in the reference.
    tail*=np.where((X>446)|(Y>158),A,1)
    save('tail',tail,paint)
    # Each padded joint has an overlapping cap. The same cutouts serve every keyed pose.
    pieces={
    'frontUpper':'M 160 50 Q 174 31 195 44 C 218 51 233 85 236 122 C 239 147 237 164 228 175 Q 206 186 183 169 C 165 154 154 134 151 103 Q 148 71 160 50 Z',
    'frontLower':'M 180 131 Q 200 115 221 128 Q 236 138 236 158 C 238 183 242 211 239 228 Q 237 240 223 240 Q 209 240 201 229 C 196 207 189 192 181 176 Q 168 151 180 131 Z',
    'frontPaw':'M 202 221 Q 211 205 226 209 Q 244 208 241 227 C 240 244 234 252 219 253 L 200 253 Q 185 251 186 241 Q 186 231 199 224 Z',
    'hindUpper':'M 316 59 Q 333 34 364 37 Q 402 35 412 64 C 415 91 400 121 389 143 C 376 168 360 187 342 188 Q 319 186 314 169 C 307 149 306 126 313 99 Q 320 75 316 59 Z',
    'hindShin':'M 322 145 Q 333 127 353 138 Q 372 145 375 166 L 378 192 Q 378 207 364 213 Q 348 217 335 207 Q 326 200 325 188 Q 311 164 322 145 Z',
    'hindHock':'M 341 184 Q 350 170 366 178 Q 379 187 374 202 Q 366 220 351 234 Q 342 246 330 245 Q 310 241 314 228 C 322 212 334 203 341 184 Z',
    'hindPaw':'M 315 222 Q 327 210 344 217 Q 359 220 352 235 Q 346 248 331 252 L 306 252 Q 291 250 292 240 Q 294 229 305 227 Z'}
    for n,path in pieces.items():
        mask=shape(path)
        if n.endswith('Paw'):mask*=np.where(Y>225,A,1)
        if n=='frontLower':mask*=np.where((Y>185)&(X>=237),A,1)
        rgb=np.array(paint,copy=True)
        # Feather the proximal shoulder against the matching torso fur.
        if n=='frontUpper':mask*=.15+.85*smooth(43,95,Y)
        if n=='hindUpper':mask*=.16+.84*smooth(39,100,Y)
        save(n,mask,rgb)
    # The far foreleg has its own extended silhouette and toe ink in the plate.
    # Keep that silhouette through the gait; mirroring the upright near paw
    # makes the forward-reaching leg too broad.
    far_shapes={
        'farUpper':'M 127 68 Q 151 57 166 87 Q 167 111 145 149 Q 135 169 117 182 Q 94 187 80 169 Q 73 154 83 132 Q 99 100 127 68 Z',
        'farLower':'M 90 135 Q 113 124 133 145 Q 142 163 120 184 Q 96 205 72 229 Q 54 241 38 226 Q 32 217 47 194 Q 62 167 74 147 Z',
        'farToes':'M 49 205 Q 61 197 75 208 Q 84 219 71 233 Q 61 252 39 252 L 17 252 Q 4 250 10 233 Q 17 219 37 221 Z'}
    for key,path in far_shapes.items():
        mask=shape(path)
        mask*=np.where((Y>180)|(X<74),A,1)
        save(key,mask,paint)
    return specs

# Bind points measured on walk-1, in painting coordinates.
FORE=np.array([(184,79),(204,150),(222,220),(210,244)],float)
HIND=np.array([(367,80),(334,159),(357,197),(327,241),(316,244)],float)
FAR_FORE=np.array([(137,81),(112,153),(63,220),(36,244)],float)
CHAINS=[('farArm farForearm farPaw',FAR_FORE,'farUpper farLower farToes'),
        ('farRear farShin farHock farHindPaw',HIND,'hindUpper hindShin hindHock hindPaw'),
        ('rear nearShin nearHock nearHindPaw',HIND,'hindUpper hindShin hindHock hindPaw'),
        ('arm forearm paw',FORE,'frontUpper frontLower frontPaw')]

def walk_bind(guides):
    g=guides.copy()
    for bones,rest,_ in CHAINS:
        for i,bone in enumerate(bones.split()):g[bone]=rest[i:i+2]
    g['trunk']=np.array([(367,80),(184,79)],float)
    g['head']=np.array([(115,91),(54,76)],float)
    g['tail']=np.array([(421,88),(463,160)],float)
    g['tip']=np.array([(463,160),(541,193)],float)
    return g

def walk_layers(image):
    art=side_pieces(image)
    def layer(bone,key,far=False):
        tile,origin=art[key]
        if far:
            a=np.array(tile);a[:,:,:3]=(a[:,:,:3]*.84).astype('uint8')
            tile=Image.fromarray(a)
        return bone,tile,origin
    def leg(chain):
        bones,_,names=chain
        return [layer(b,n,b.startswith('far') and not n.startswith('far')) for b,n in reversed(list(zip(bones.split(),names.split())))]
    tail,origin=art['tail']
    parts=[]
    for bone,left,right in [('tail',0,466),('tip',460,600)]:
        a=max(0,left-origin[0]);b=min(tail.width,right-origin[0])
        parts.append((bone,tail.crop((a,0,b,tail.height)),(origin[0]+a,origin[1])))
    return leg(CHAINS[1])+leg(CHAINS[0])+parts+[layer('trunk','torso')]+leg(CHAINS[2])+leg(CHAINS[3])+[layer('head','head')]

def bend(a,c,l1,l2,side):
    axis=c-a;d=max(.001,np.linalg.norm(axis));u=axis/d
    along=np.clip((l1*l1-l2*l2+d*d)/(2*d),-l1,l1)
    return a+along*u+side*np.sqrt(max(0,l1*l1-along*along))*np.array([-u[1],u[0]])

def walk_segments(bind, phase, toes, size):
    g={n:np.array(seg,copy=True) for n,seg in bind.items()}
    bob=1.8*np.sin(4*np.pi*phase)
    for n in ('trunk','chest','head','tail','tip'):g[n][:,1]+=bob
    for bones,rest,_ in CHAINS:
        names=bones.split();fore=len(names)==3;far=bones.startswith('far')
        goal='farPaw' if fore and far else 'paw' if fore else 'farRearFoot' if far else 'rearFoot'
        foot=np.array(toes[goal])*size
        socket=rest[0]+[13 if far and not fore else 0,bob-3 if far else bob]
        # A cat's scapula slides along the ribcage during protraction. Keeping
        # the shoulder fixed forces the entire forward reach into the forearm.
        if fore:
            stride=foot[0]-rest[-1,0]
            socket[0]+=stride*.38
            socket[1]+=min(16,abs(stride)*.10)
        scale=lambda i: np.linalg.norm(rest[i+1]-rest[i])
        ankle=foot+rest[-2]-rest[-1]
        # Keep the flexion branch away from its fully extended singularity.
        # Move the shoulder slightly along the ribcage if the wrist is too far.
        target=ankle if fore else ankle+rest[2]-rest[3]
        distance=np.linalg.norm(target-socket)
        maximum=.985*(scale(0)+scale(1))
        if distance>maximum:
            socket+=(target-socket)*(1-maximum/distance)
        if fore:
            elbow=bend(socket,ankle,scale(0),scale(1),-1)
            joints=[socket,elbow,ankle,foot]
        else:
            hock=ankle+rest[2]-rest[3]
            knee=bend(socket,hock,scale(0),scale(1),1)
            joints=[socket,knee,hock,ankle,foot]
        for i,n in enumerate(names):g[n]=np.array(joints[i:i+2])
    return g

def walking_targets(phase, size, travel):
    """Toe centres in side-view bind pixels. During stance the supporting toe
    travels backwards through the rig at the exact speed the panel moves forward.
    Swing has the same tangent at lift-off and touch-down.
    """
    duty=.64
    config={'paw':(.46,161.,244.), 'farPaw':(.96,123.,239.),
            'rearFoot':(.60,331.,244.), 'farRearFoot':(.10,382.,239.)}
    targets={}
    for name,(offset,center,floor) in config.items():
        t=(phase+offset)%1
        dx=travel*(t-duty/2)
        y=floor
        if t>duty:
            k=(t-duty)/(1-duty)
            dx-=travel*k*k*(3-2*k)
            y-=17*np.sin(np.pi*k)**2
        targets[name]=[(center+dx)/size[0],y/size[1]]
    return targets
