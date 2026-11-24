"""Compare two native GroomingReview exports, preserving their individual 30 Hz timelines."""
import argparse
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


def cycle(folder, key):
    frames = json.loads((folder / "timeline.json").read_text())
    names = [frame["file"] for frame in frames]
    contact = key + ".png"
    starts = [n for n, name in enumerate(names) if name == contact and (n == 0 or names[n-1] != contact)]
    for a, b in zip(starts, starts[1:]):
        segment = names[a:b]
        if key + "-recover.png" in segment and all(name == contact or name.startswith(key + "-") for name in segment):
            return segment
    raise ValueError(f"No full repeated {key} stroke in {folder}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ("before", "after", "output"):
        parser.add_argument(arg, type=Path)
    args = parser.parse_args()
    font = "/System/Library/Fonts/Hiragino Sans GB.ttc"
    label = ImageFont.truetype(font, 23)
    caption = ImageFont.truetype(font, 16)
    dirs = (args.before, args.after)
    width, height = 840, 376
    cache = {}
    for index, directory in enumerate(dirs):
        for p in directory.glob("*.png"):
            cache[index, p.name] = Image.open(p).convert("RGB").crop((26, 30, 454, 365)).resize((412, 322), Image.Resampling.LANCZOS)
    paper = cache[0, "chest.png"].getpixel((0, 0))
    movie = []
    for key, title in [("lick", "舔前爪"), ("chest", "舔胸口"), ("flank", "回头舔肩"), ("toes", "舔后爪")]:
        strokes = [cycle(directory, key) for directory in dirs]
        # A whole sampled stroke from each version repeats at its own playback speed.
        for tick in range(0, 78, 2):
            frame = Image.new("RGB", (width, height), paper)
            draw = ImageDraw.Draw(frame)
            draw.text((22, 12), title, font=label, fill=(36, 40, 38))
            for index, version in enumerate(("0.1.17", "0.1.18")):
                offset = index * (width // 2)
                draw.text((offset + 325, 18), version, font=caption, fill=(71, 78, 74))
                frame.paste(cache[index, strokes[index][tick % len(strokes[index])]], (offset + 4, 48))
            draw.line((width // 2, 12, width // 2, height - 10), fill=(205, 200, 189))
            movie.append(frame)
    # GIF times are centiseconds. Quantizing each frame to 60 ms would speed up the native motion.
    durations = [(round((n+1)*100/15) - round(n*100/15))*10 for n in range(len(movie))]
    # Share colors across drawings. Independently quantizing each frame makes
    # the stationary torso flicker and defeats GIF's changed-region encoding.
    samples = movie[::4]
    paletteSheet = Image.new("RGB", (210 * 5, 94 * ((len(samples) + 4) // 5)))
    for i, sample in enumerate(samples):
        paletteSheet.paste(sample.resize((210, 94)), (i % 5 * 210, i // 5 * 94))
    palette = paletteSheet.quantize(colors=192)
    indexed = [frame.quantize(palette=palette, dither=Image.Dither.NONE) for frame in movie]
    indexed[0].save(args.output, save_all=True, append_images=indexed[1:], duration=durations,
                    loop=0, optimize=False, disposal=1)


if __name__ == "__main__":
    main()
