"""Make matched-scale previews from Review.swift exports and the original pngs.
python3 Tools/Rig/compare.py <review output directory> <comparison.gif> <back-look.gif>
"""
import json
import sys
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFont

pet=Path(__file__).resolve().parents[2]/'Resources/Pets/Dada'
rendered,comparison,back_look=map(Path,sys.argv[1:])
spec=json.loads((pet/'pet.json').read_text())
refs={f'{name}-{i}':frame for name,clip in spec['clips'].items() for i,frame in enumerate(clip)}
timeline=json.loads((rendered/'samples.json').read_text())
font=ImageFont.truetype('/System/Library/Fonts/STHeiti Light.ttc',17)
small=ImageFont.truetype('/System/Library/Fonts/STHeiti Light.ttc',14)
names={'high':'坐着抬爪','mirror':'左右转身','interrupt':'伸爪中途转趴','walk':'行走','reach':'趴着伸爪','turn':'背睡回头','turnBody':'趴姿起身转背','jump':'上 Dock','descend':'下 Dock'}
paper='#faf6ef'
def paint(canvas,image,scale,anchor,height,center,floor,unit):
    w,h=image.size
    cropped=image.crop((0,0,w,height))
    factor=scale*unit
    im=cropped.resize((max(1,round(w*factor)),max(1,round(height*factor))),Image.Resampling.LANCZOS)
    canvas.paste(im,(round(center-anchor*factor),round(floor-im.height)),im)
def ground(im):
    alpha=np.asarray(im)[:,:,3]
    rows=np.where((alpha>=184).sum(axis=1)>=max(2,np.ceil(im.width*.06)))[0]
    return int(rows[-1])+1 if len(rows) else im.height
def save(frames,times,path):
    # GIF delays are centiseconds; alternating 30/40 ms retains the 30 Hz timing.
    frames[0].save(path,save_all=True,append_images=frames[1:],duration=times,loop=0,disposal=1,optimize=True)
out=[];delays=[];memorial=[];rest_delays=[]
for s in timeline:
    name=s['segment'];ref=refs[s['old']]
    old=Image.open(pet/ref['file']).convert('RGBA')
    new=Image.open(rendered/(s['sample']+'.png')).convert('RGBA')
    canvas=Image.new('RGB',(752,290),paper)
    draw=ImageDraw.Draw(canvas)
    draw.text((17,12),'原逐帧',font=font,fill='#44413b')
    draw.text((393,12),'分件骨骼',font=font,fill='#44413b')
    draw.text((735,14),names[name],font=small,anchor='rt',fill='#666052')
    draw.line((376,11,376,276),fill='#dcd4c7')
    unit=181;floor=273-s['lift']*unit
    for x in [0,377]:draw.line((x+14,273,x+361,273),fill='#d2c8b9')
    old_anchor=ref['anchorX'];new_anchor=s['anchor']
    if s.get('oldMirror'):
        old=old.transpose(Image.Transpose.FLIP_LEFT_RIGHT);old_anchor=old.width-old_anchor
    if s.get('newMirror'):
        new=new.transpose(Image.Transpose.FLIP_LEFT_RIGHT);new_anchor=new.width-new_anchor
    paint(canvas,old,ref['unitsPerPixel'],old_anchor,ground(old) if s.get("grounded",True) else old.height,185,floor,unit)
    paint(canvas,new,s['scale'],new_anchor,s['height'],561,floor,unit)
    out.append(canvas)
    delay=(round(len(out)*100/30)-round((len(out)-1)*100/30))*10;delays.append(delay)
    if name=='turn':
        canvas=Image.new('RGB',(460,298),paper)
        ImageDraw.Draw(canvas).rectangle((0,279,460,298),fill='#eee7dc')
        paint(canvas,new,s['scale'],new_anchor,s['height'],230,279,292)
        memorial.append(canvas);rest_delays.append(delay)
rest_delays[-1]+=780
save(out,delays,comparison)
save(memorial,rest_delays,back_look)
