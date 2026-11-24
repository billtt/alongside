"""Draw actual simulated body poses in a shared, stationary camera."""
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont


def write_comparison(path, edge, examples):
    width, height = 810, 505
    scale, origin = 346, 132
    background, ink, muted = "#f9f8f2", "#26312f", "#51605b"
    colors = ("#2d6d64", "#e1a248")
    cjk = Path("/System/Library/Fonts/Hiragino Sans GB.ttc")

    def font(size):
        return ImageFont.truetype(str(cjk), size) if cjk.exists() else ImageFont.load_default(size=size)

    def local(chinese, english):
        return chinese if cjk.exists() else english

    title_font, label_font, tiny = font(23), font(16), font(13)
    labels = (local("平地", "Flat ground"), local("4 cm 台阶 · 无预看", "4 cm step / no preview"),
              local("4 cm 台阶 · 预看落爪高度", "4 cm step / landing-height preview"))
    frames = []
    for group in zip(*(r.frames for r in examples)):
        image = Image.new("RGB", (width, height), background)
        draw = ImageDraw.Draw(image)
        draw.text((23, 13), local("同一段学到的步态，遇到台阶会怎样？",
                                    "How does the same learned gait handle a step?"), font=title_font, fill=ink)
        draw.text((24, 49), local("二维四足物理样机    指令速度 0.22 m/s    相机与比例固定",
                                   "Planar physics model    0.22 m/s command    Same fixed camera"),
                  font=tiny, fill=muted)
        draw.text((width-78, 19), f"{group[0][0]:.2f} s", font=label_font, fill=muted)
        for row, (time, torso, pitch, head, legs) in enumerate(group):
            base = 187 + row*136

            def xy(point):
                return (round(origin + scale*point[0]), round(base - scale*point[1]))

            start = xy((edge, 0))[0]
            draw.line((22, base, width-22, base), fill="#7b887e", width=2)
            if row:
                raised = xy((0, .04))[1]
                draw.rectangle((start, raised, width-22, base), fill="#e0dfce")
                draw.line((start, base, start, raised, width-22, raised), fill="#5e665d", width=2)
            else:
                for y in range(base-19, base, 6):
                    draw.line((start, y, start, y+3), fill="#aeb2a5", width=1)
            draw.text((23, base-109), labels[row], fill=ink, font=label_font)
            draw.text((width-92, base-109), f"x {torso[0]:.2f} m", font=tiny, fill=muted)
            for mark in (0, .5, 1., 1.5):
                x = xy((mark, 0))[0]
                draw.line((x, base+1, x, base+5), fill="#9aa298")
                draw.text((x-5, base+5), f"{mark:g}", font=tiny, fill=muted)

            def draw_leg(index, far):
                p = [xy(v) for v in legs[index]]
                color = "#a2b4ae" if far else colors[0]
                draw.line(p, fill=color, width=3 if far else 5)
                for j, (x, y) in enumerate(p[1:]):
                    radius = 3 if j == 0 else 4
                    draw.ellipse((x-radius, y-radius, x+radius, y+radius),
                                 fill=color if j == 0 or far else colors[1])

            for index in (1, 3):
                draw_leg(index, True)

            # Draw the same sagittal cross-sections used for torso and head contact.
            angle = np.arange(48) * 2*math.pi/48
            contour = np.stack([.197*np.cos(angle), .060*np.sin(angle)])
            c, s = math.cos(pitch), math.sin(pitch)
            rotated = np.array([[c, s], [-s, c]]) @ contour + torso[:, None]
            draw.polygon([xy(p) for p in rotated.T], fill="#d2ded6", outline=colors[0], width=2)
            x, y = xy(head)
            r = round(scale*.053)
            draw.ellipse((x-r, y-r, x+r, y+r), fill="#ccd9d1", outline=colors[0], width=2)
            for index in (0, 2):
                draw_leg(index, False)
        draw.text((23, height-21), local("横轴单位为米，爪端与躯干来自模拟记录。",
                                           "Horizontal scale in metres. Body and paw positions from simulation."),
                  font=tiny, fill=muted)
        frames.append(image)
    # Each recorded pose is four 20 ms control ticks apart.
    frames[0].save(path, save_all=True, append_images=frames[1:], duration=80, loop=0,
                   optimize=True, disposal=1)
