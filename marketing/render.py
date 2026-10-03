#!/usr/bin/env python3
"""Compose exact product screenshots/type and encode the Chinese 2.0 campaign."""
import argparse
from functools import lru_cache
import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess
import wave

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'marketing/source'
MINT = '#8FD6C9'
WHITE = '#F2F5F3'
MUTED = '#91A4A4'
URL = 'github.com/RyanZhangNTU/codex-pacer'


def find_font():
    candidates = [Path('/System/Library/Fonts/PingFang.ttc')]
    candidates += list(Path('/System/Library/AssetsV2').glob('com_apple_MobileAsset_Font*/*/AssetData/PingFang.ttc'))
    return next((p for p in candidates if p.exists()), Path('/System/Library/Fonts/STHeiti Medium.ttc'))

FONT = find_font()


@lru_cache(maxsize=96)
def font(size, bold=False):
    return ImageFont.truetype(str(FONT), size, index=(11 if bold else 3) if FONT.name == 'PingFang.ttc' else 0)


def text(im, position, copy, size=36, fill=WHITE, bold=False, anchor=None):
    ImageDraw.Draw(im).text(position, copy, font=font(size, bold), fill=fill, anchor=anchor, stroke_width=0)


@lru_cache(maxsize=8)
def background(w, h):
    yy, xx = np.mgrid[0:h, 0:w]
    glow = np.exp(-(((xx - w * .73) / (w * .53)) ** 2 + ((yy - h * .43) / (h * .72)) ** 2) * 3)
    second = np.exp(-(((xx - w * .06) / (w * .58)) ** 2 + ((yy - h * .04) / (h * .6)) ** 2) * 3)
    pixels = np.zeros((h, w, 3), dtype=np.uint8)
    for c, (base, green, blue) in enumerate(((6, 8, 4), (12, 22, 5), (16, 20, 8))):
        pixels[:, :, c] = (base + green * glow + blue * second).astype(np.uint8)
    im = Image.fromarray(pixels).convert('RGBA')
    overlay = Image.new("RGBA", (w, h))
    d = ImageDraw.Draw(overlay)
    # Quiet editorial grid and a single orbital arc echo the island's curve.
    for x in range(80, w, 160): d.line((x, 0, x, h), fill=(145, 210, 198, 8), width=1)
    d.arc((w * .32, h * .13, w * 1.15, h * .90), 185, 337, fill=(125, 200, 190, 32), width=2)
    im.alpha_composite(overlay)
    return im


@lru_cache(maxsize=12)
def asset(name):
    if name == 'logo': return Image.open(ROOT / 'native/Resources/Pacer.png').convert('RGBA')
    value = Image.open(SOURCE / (name + '.png')).convert('RGBA')
    if name == 'task-jump':
        # Crop OS titlebar/shadow, preserving the explicitly labeled demo content.
        value = value.crop((46, 94, 1166, 734))
    return value


SCALED = {}


def paste(im, source, xy, width):
    key = (id(source), round(width))
    if key not in SCALED:
        SCALED[key] = (source, source.resize((round(width), round(source.height * width / source.width)), Image.Resampling.LANCZOS))
    s = SCALED[key][1]
    im.alpha_composite(s, (round(xy[0]), round(xy[1])))


def brand(im, xy, size=64):
    paste(im, asset('logo'), xy, size)
    text(im, (xy[0] + size + 22, xy[1] + size * .08), 'Codex Pacer', round(size * .68), bold=True)


def pill(im, box, label, size=28, filled=False):
    d = ImageDraw.Draw(im)
    d.rounded_rectangle(box, radius=(box[3] - box[1]) / 2, fill=MINT if filled else '#152D2C', outline=None if filled else '#345452', width=1)
    text(im, ((box[0]+box[2])/2, (box[1]+box[3])/2-2), label, size, '#071412' if filled else MINT, bold=True, anchor='mm')


def mac_scene():
    try:
        from .mac_scene import MacScene
    except ImportError:
        from mac_scene import MacScene
    return MacScene(asset, font)


MAC = mac_scene()


def portrait():
    try:
        from .business_campaign import render
    except ImportError:
        from business_campaign import render
    return render(asset, font)


def landscape():
    try:
        from .business_campaign import render_landscape
    except ImportError:
        from business_campaign import render_landscape
    return render_landscape(asset, font)


def ease(x):
    x = min(1, max(0, x)); return 1 - (1-x)**3


def scene(index, elapsed, vertical=False):
    w,h = (1080,1920) if vertical else (1920,1080)
    im = background(w,h).copy()
    enter = 30*(1-ease(elapsed/.9))
    bob = 4*math.sin(elapsed*.8)
    bx,by = (86,92) if vertical else (120,92)
    if index not in (0,5): brand(im,(bx,by),70 if vertical else 64)
    if index == 0:
        if vertical:
            brand(im,(86,92),70)
            text(im,(86,310+enter),'抬眼，',112,MINT,True)
            text(im,(86,458+enter),'即见。',112,MINT,True)
            paste(im,MAC.laptop('island-collapsed'),(15,745+bob),1050)
            text(im,(86,1500),'任务、状态、额度',52,bold=True)
            text(im,(86,1600),'贴合 Mac 刘海的原生状态岛',34,MUTED)
        else:
            brand(im,(120,92),76)
            text(im,(120,285+enter),'抬眼，',104,MINT,True)
            text(im,(120,415+enter),'即见。',104,MINT,True)
            paste(im,MAC.laptop('island-collapsed'),(830,230+bob),1050)
            text(im,(120,650),'任务、状态、额度',45,WHITE,True)
            text(im,(120,738),'贴合 Mac 刘海的原生状态岛',32,MUTED)
    elif index == 1:
        phase=min(3,int(elapsed/2.75))
        shot=('island-expanded','island-tool','island-reply','island-completed')[phase]
        if vertical:
            text(im,(86,280+enter),'状态随事件',76,bold=True)
            text(im,(86,385+enter),'实时更新。',76,MINT,True)
            paste(im,MAC.detail(shot),(166,535+bob),748)
            text(im,(86,1500),'本机与 SSH  ·  无需手动刷新',34,MUTED)
            x,y,step,pw=86,1610,226,207
        else:
            text(im,(120,310+enter),'状态随事件',84,bold=True)
            text(im,(120,420+enter),'实时更新。',88,MINT,True)
            text(im,(120,595),'本机与 SSH 任务集中显示',35,MUTED)
            text(im,(120,655),'订阅事件驱动，无需手动刷新',35,MUTED)
            paste(im,MAC.detail(shot),(1090,78+bob),740)
            x,y,step,pw=120,802,185,166
        for i,label in enumerate(('模型思考','工具执行','输出回复','本轮结束')):
            pill(im,(x+i*step,y,x+i*step+pw,y+62),label,25 if vertical else 24,filled=i==phase)
        text(im,(bx,h-160),'事件状态演示',27,MUTED)
    elif index == 2:
        destination = elapsed > 2.2
        if vertical:
            text(im,(86,280+enter),'点击任务，',80,bold=True)
            text(im,(86,390+enter),'回到会话。',80,MINT,True)
            if destination:
                paste(im,MAC.detail('task-jump'),(166,535+bob),748)
            else:
                paste(im,MAC.detail('island-reply'),(166,535+bob),748)
                cursor(im, (385,720), elapsed)
            text(im,(86,1500),'继续查看进度或回复',40,WHITE,True)
            text(im,(86,1590),'对应任务的会话，直接抵达',33,MUTED)
        else:
            text(im,(120,310+enter),'点击任务，',88,bold=True)
            text(im,(120,428+enter),'回到会话。',88,MINT,True)
            text(im,(120,610),'继续查看进度或回复',36,MUTED)
            if destination: paste(im,MAC.detail('task-jump'),(1090,78+bob),740)
            else:
                paste(im,MAC.detail('island-reply'),(1090,78+bob),740)
                cursor(im,(1310,245),elapsed)
        pill(im,(bx,h-245,bx+310,h-180),'跳转流程演示',27)
    elif index == 3:
        expiry = elapsed > 5.1
        shot = 'island-expiry-next' if expiry else 'island-expiry'
        title1,title2='重置卡到期，','提前看见。'
        if vertical:
            text(im,(86,280+enter),title1,78,bold=True)
            text(im,(86,388+enter),title2,78,MINT,True)
            paste(im,MAC.detail(shot),(166,535+bob),748)
            text(im,(86,1520),'七天额度  ·  配速  ·  当前周期曲线',32,MUTED)
            pill(im,(86,1630,735,1700),'可用重置卡 · 到期日期清晰可见',30)
        else:
            text(im,(120,310+enter),title1,88,bold=True)
            text(im,(120,428+enter),title2,88,MINT,True)
            text(im,(120,600),'七天额度 · 配速 · 当前周期曲线',34,MUTED)
            text(im,(120,662),'看清剩余额度，也看清重置卡何时到期',34,MUTED)
            paste(im,MAC.detail(shot),(1090,78+bob),740)
            pill(im,(120,800,700,870),'可用重置卡 · 到期日期清晰可见',30)
    elif index == 4:
        if vertical:
            text(im,(86,325+enter),'本轮结束，',88,bold=True)
            text(im,(86,445+enter),'不错过。',88,MINT,True)
            paste(im,MAC.laptop('island-collapsed'),(15,765+bob),1050)
            text(im,(86,1500),'折叠也能看到提醒',48,bold=True)
            text(im,(86,1580),'保留时间可调',36,MUTED)
            text(im,(86,1650),'点击打开对应会话',36,MUTED)
        else:
            text(im,(120,265+enter),'本轮结束，不错过。',88,bold=True)
            paste(im,MAC.laptop('island-collapsed'),(800,300+bob),1090)
            text(im,(120,738),'折叠也能看到提醒',42,MINT,True)
            text(im,(120,815),'保留时间可调 · 点击打开对应会话',34,MUTED)
    else:
        if vertical:
            paste(im,asset('logo'),(442,395+enter),196)
            text(im,(540,695),'Codex Pacer 2.0',66,WHITE,True,'mm')
            text(im,(540,910),'把注意力',70,WHITE,True,'mm')
            text(im,(540,1008),'留给创作。',70,MINT,True,'mm')
            text(im,(540,1190),'原生 macOS · 2.0 正式版',33,MUTED,anchor='mm')
            pill(im,(300,1370,780,1470),'免费下载  →',40,True)
            text(im,(540,1665),'github.com/RyanZhangNTU',29,MUTED,anchor='mm')
            text(im,(540,1720),'/codex-pacer',29,MUTED,anchor='mm')
        else:
            brand(im,((1920-134-font(76,True).getlength('Codex Pacer'))/2,190+enter),112)
            text(im,(960,440+enter),'把注意力留给创作。',82,WHITE,True,'mm')
            text(im,(960,562),'原生 macOS · 2.0 正式版',36,MINT,anchor='mm')
            pill(im,(745,695,1175,784),'免费下载  →',38,True)
            text(im,(960,910),URL,31,MUTED,anchor='mm')
    if index<5: text(im,(w-70,h-65),'演示数据',22,'#738785',anchor='rm')
    return im.convert('RGB')


def cursor(im, xy, elapsed):
    if elapsed < 1: return
    x,y=xy; d=ImageDraw.Draw(im)
    radius=24+12*math.sin(min(1,(elapsed-1)/1.2)*math.pi)
    d.ellipse((x-radius,y-radius,x+radius,y+radius),outline=MINT,width=3)
    d.polygon([(x,y),(x+4,y+42),(x+14,y+31),(x+24,y+50),(x+32,y+46),(x+22,y+27),(x+38,y+26)],fill=WHITE,outline='#182421')


STARTS=[0,4,15,21,31,35]
DURATION=42

def frame(t, vertical=False):
    index = max(i for i,s in enumerate(STARTS) if t >= s)
    local = t-STARTS[index]
    current = scene(index,local,vertical)
    if index>0 and local<.55:
        previous=scene(index-1,t-STARTS[index-1],vertical)
        current=Image.blend(previous,current,ease(local/.55))
    if t < .45: current=Image.blend(Image.new('RGB',current.size,'#060C10'),current,ease(t/.45))
    if t > DURATION-.6: current=Image.blend(current,Image.new('RGB',current.size,'#060C10'),(t-(DURATION-.6))/.6)
    return current


def audio(path):
    # Original restrained sine-pad soundtrack, no stock samples or voice API.
    rate=44100; n=rate*DURATION; t=np.arange(n)/rate
    signal=np.zeros(n)
    for start, frequencies in ((0,(130.81,196,261.63)),(8,(110,164.81,220)),(16,(146.83,220,293.66)),(24,(130.81,196,261.63)),(32,(146.83,220,293.66)),(40,(130.81,196,261.63))):
        tt=t-start; env=np.clip(tt/2,0,1)*np.clip((9-tt)/2,0,1)
        for frequency in frequencies:
            signal+=.032*env*(np.sin(2*np.pi*frequency*t)+.18*np.sin(2*np.pi*2*frequency*t))
    for start in STARTS[1:]:
        dt=t-start; env=np.where(dt>=0,np.exp(-np.maximum(dt,0)*12),0)
        signal+=.033*env*np.sin(2*np.pi*880*t)
    signal*=np.clip(t/2,0,1)*np.clip((DURATION-t)/2,0,1)
    pcm=(np.clip(signal,-.9,.9)*32767).astype('<i2')
    with wave.open(str(path),'wb') as wav:
        wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(rate); wav.writeframes(pcm.tobytes())


def ffmpeg():
    executable=shutil.which('ffmpeg')
    if not executable:
        candidates = list((Path.home() / '.local/lib').glob('python*/site-packages/imageio_ffmpeg/binaries/ffmpeg-macos*'))
        if candidates: executable = str(candidates[0])
    if not executable:
        import imageio_ffmpeg
        executable=imageio_ffmpeg.get_ffmpeg_exe()
    return executable


def encode(out, vertical, fps):
    w,h=(1080,1920) if vertical else (1920,1080)
    video=out/('Codex-Pacer-2.0-zh-CN-vertical.mp4' if vertical else 'Codex-Pacer-2.0-zh-CN.mp4')
    args=[ffmpeg(),'-y','-loglevel','warning','-f','rawvideo','-pix_fmt','rgb24','-s',f'{w}x{h}','-r',str(fps),'-i','-',
          '-i',str(out/'soundtrack.wav'),'-c:v','libx264','-preset','fast','-crf','19','-pix_fmt','yuv420p','-c:a','aac',
          '-b:a','160k','-ar','44100','-movflags','+faststart','-t',str(DURATION),str(video)]
    with (out/(video.stem+'.encode.log')).open('w') as log:
        process=subprocess.Popen(args,stdin=subprocess.PIPE,stderr=log)
        try:
            for i in range(DURATION*fps): process.stdin.write(frame(i/fps,vertical).tobytes())
            process.stdin.close(); rc=process.wait()
        except Exception:
            process.kill(); process.wait(); raise
    if rc: raise RuntimeError(f'Encoding failed; see {video.stem}.encode.log')
    return video


def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--out',type=Path,default=ROOT/'output/marketing/2.0')
    parser.add_argument('--stills-only',action='store_true'); parser.add_argument('--fps',type=int,default=30)
    args=parser.parse_args(); out=args.out.resolve(); out.mkdir(parents=True,exist_ok=True)
    portrait().save(out/'Codex-Pacer-2.0-zh-CN-poster.png',optimize=True)
    banner=landscape(); banner.save(out/'Codex-Pacer-2.0-zh-CN-banner.png',optimize=True)
    banner.resize((1440,810),Image.Resampling.LANCZOS).save(ROOT/'docs/assets/pacer-2.0.png',optimize=True)
    previews=[]
    for i,t in enumerate((2,5,8,11,14,17,19,24,28,33,38)):
        p=out/f'frame-{i+1}.png'; frame(t).save(p,optimize=True); previews.append(p)
    review=Image.new('RGB',(960,540*len(previews)),'#060C10')
    for i,p in enumerate(previews): review.paste(Image.open(p).resize((960,540)),(0,i*540))
    review.save(out/'video-review.png',optimize=True)
    srt='1\n00:00:00,000 --> 00:00:04,000\n抬眼，即见。任务、速度、额度。\n\n2\n00:00:04,000 --> 00:00:15,000\n状态随事件实时更新。模型思考、执行工具、输出回复、本轮结束。\n\n3\n00:00:15,000 --> 00:00:21,000\n点击任务，回到对应会话。\n\n4\n00:00:21,000 --> 00:00:31,000\n看清每张重置卡的到期日期，周期内提前提示。\n\n5\n00:00:31,000 --> 00:00:35,000\n本轮结束，不错过。折叠提醒，保留时间可调。\n\n6\n00:00:35,000 --> 00:00:42,000\nCodex Pacer 2.0 正式版。把注意力留给创作。\n'
    (out/'Codex-Pacer-2.0-zh-CN.srt').write_text(srt)
    if not args.stills_only:
        audio(out/'soundtrack.wav'); encode(out,False,args.fps); encode(out,True,args.fps)
    exports=[p for p in out.iterdir() if p.suffix in ('.png','.mp4','.srt') and not p.name.startswith('frame-')]
    manifest={'product':'Codex Pacer 2.0','language':'zh-CN','durationSeconds':DURATION,'fps':args.fps,
              'composition':'deterministic native screenshots and exact typography',
              'provenance':{'ui':'Real native demo app; synthetic event fixtures run through the production runtime projection; visibly labeled 演示',
                            'jump':'Explicit demo destination, never exposes or pretends to record a private Codex conversation',
                            'logo':'Existing MIT repository brand', 'hardware':'Built-in Imagegen MacBook frames; measured screen geometry; UI/text are deterministic native screenshots',
                            'reference':'https://cdsassets.apple.com/live/6GJYWVAV/start/locale/ar-sa/ma2039_macbook-pro-14inch-2021-qsg.pdf',
                            'audio':'Original synthesized sine-pad soundtrack',
                            'font':'Local macOS PingFang SC; font file not distributed',
                            'poster':{'layout':'marketing/business_campaign.py',
                                      'hardware':'marketing/source/macbook-studio.png',
                                      'prompt':'marketing/source/macbook-studio-prompt.txt',
                                      'desktop':'Native liquid-glass desktop capture on staged macOS wallpaper; geometry in marketing/source/desktop-liquid-glass.json',
                                      'ui':'Device retains 440 pt panel on 1728 pt desktop, 25.46% width; separate uniformly enlarged content detail with a fine connector; clear native glass at 100% transparency'},
                            'sourceHashes':{p.name:digest(p) for p in SOURCE.iterdir() if p.suffix in ('.png','.jpg')}},
              'exports':[{'file':p.name,'bytes':p.stat().st_size,'sha256':digest(p)} for p in sorted(exports)]}
    (out/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
    print(out)


if __name__=='__main__': main()
