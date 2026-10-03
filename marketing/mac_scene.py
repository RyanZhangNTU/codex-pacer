"""MacBook hardware context around untouched native demo screenshots."""
from functools import lru_cache
import math
import numpy as np
from PIL import Image, ImageDraw, ImageFont


class MacScene:
    def __init__(self, assets, font):
        self.assets, self.font = assets, font

    @lru_cache(maxsize=1)
    def wallpaper(self):
        w,h=3456,2234
        yy,xx=np.mgrid[0:h,0:w]
        blue=np.exp(-(((xx-w*.65)/(w*.7))**2+((yy-h*.45)/(h*.85))**2)*3)
        purple=np.exp(-(((xx-w*.18)/(w*.8))**2+((yy-h*.7)/(h*.65))**2)*4)
        a=np.zeros((h,w,3),dtype=np.uint8)
        for c,(base,b,p) in enumerate(((15,20,58),(23,59,21),(52,96,83))):
            a[:,:,c]=(base+b*blue+p*purple).astype(np.uint8)
        im=Image.fromarray(a).convert('RGBA')
        layer=Image.new('RGBA',im.size);d=ImageDraw.Draw(layer)
        for i in range(7):
            pts=[(x,round(h*.72+120*i+215*math.sin(x/w*3.6+i*.09))) for x in range(-100,w+100,20)]
            d.line(pts,fill=(140,190,238,20+i*3),width=30)
        im.alpha_composite(layer)
        return im

    @lru_cache(maxsize=16)
    def desktop(self, shot):
        im=self.wallpaper().copy();d=ImageDraw.Draw(im)
        d.rectangle((0,0,3456,72),fill=(16,23,43,150))
        try:
            apple=ImageFont.truetype('/System/Library/Fonts/SFNS.ttf',34)
            d.text((40,13),'\uf8ff',font=apple,fill='#F6F8FC')
        except OSError: pass
        d.text((106,16),'访达   文件   编辑   显示   前往   窗口   帮助',font=self.font(29),fill='#F1F4FC')
        d.text((3060,16),'周六  12:00',font=self.font(29),fill='#F1F4FC')
        d.rounded_rectangle((2960,23,3008,49),radius=5,outline='#EAF0FA',width=3)
        d.rectangle((2967,29,2999,43),fill='#EAF0FA');d.rectangle((3010,31,3015,41),fill='#EAF0FA')
        for r in (16,27,38):d.arc((2870-r,36-r,2870+r,36+r),210,330,fill='#EAF0FA',width=3)
        # A quiet macOS-style Dock, with our real app icon and generic tools.
        dock=(1370,2080,2086,2204)
        d.rounded_rectangle(dock,radius=28,fill=(223,232,248,40),outline=(230,238,255,75),width=2)
        d.rounded_rectangle((1400,2100,1480,2180),radius=16,fill='#73A8F7')
        d.rectangle((1400,2100,1440,2180),fill='#B9DBFF')
        d.arc((1417,2115,1463,2166),20,160,fill='#24375E',width=4)
        d.line((1440,2114,1433,2154,1449,2154),fill='#24375E',width=3)
        for x,c,symbol in ((1515,'#304168','>_'),(1630,'#627091','{ }'),(1860,'#727DE5','✦'),(1975,'#EBEFF8','▥')):
            d.rounded_rectangle((x,2100,x+80,2180),radius=16,fill=c)
            d.text((x+15,2115),symbol,font=self.font(32,True),fill='#ECF2F7')
        logo=self.assets('logo').resize((80,80),Image.Resampling.LANCZOS);im.alpha_composite(logo,(1745,2100))
        if shot=='task-jump':
            content=self.assets(shot)
            content=content.resize((1120,640),Image.Resampling.LANCZOS)
            im.alpha_composite(content,(1168,330))
            d.rounded_rectangle((1168,280,2288,331),radius=14,fill='#24262D')
            d.rectangle((1168,307,2288,332),fill='#24262D')
            for x,c in ((1194,'#FF5F57'),(1229,'#FEBB2E'),(1264,'#28C840')):d.ellipse((x,296,x+19,315),fill=c)
            d.text((1515,288),'会话跳转 · 演示',font=self.font(25),fill='#AFB5C1')
        else:
            source=self.assets(shot)
            # CoreGraphics window capture includes fixed shadow margins.
            content=source.crop((46,38,source.width-46,source.height-54))
            im.alpha_composite(content,((3456-content.width)//2,0))
        # The hardware notch is top-attached, below the bezel, and stays fixed.
        d=ImageDraw.Draw(im)
        d.rounded_rectangle((1532,-28,1924,72),radius=16,fill='#050608')
        d.rectangle((1532,-28,1924,30),fill='#050608')
        d.ellipse((1719,22,1737,40),fill='#0D1725',outline='#293440',width=1)
        d.ellipse((1725,27,1730,32),fill='#4A607E')
        return im

    @lru_cache(maxsize=16)
    def laptop(self,shot):
        hardware=self.assets('macbook-frame')
        im=hardware.copy()
        # Screen boundary measured from the generated front-facing hardware.
        screen=self.desktop(shot).resize((1057,627),Image.Resampling.LANCZOS)
        mask=Image.new('L',screen.size);d=ImageDraw.Draw(mask)
        d.rounded_rectangle((0,0,1056,626),radius=17,fill=255)
        d.rounded_rectangle((469,-20,589,21),radius=7,fill=0)
        d.rectangle((469,0,589,9),fill=0)
        screen.putalpha(mask);im.alpha_composite(screen,(240,133))
        return im

    @lru_cache(maxsize=20)
    def detail(self,shot):
        desktop=self.desktop(shot)
        # An enlarged upper-centre screen crop keeps text crisp and context clear.
        crop=desktop.crop((1173,-56,2283,1344))
        frame=Image.new('RGBA',crop.size,'#14161C')
        frame.alpha_composite(crop,(0,0))
        d=ImageDraw.Draw(frame)
        d.rectangle((0,0,1110,55),fill='#14161C')
        d.line((0,54,1110,54),fill='#484B52',width=2)
        d.rounded_rectangle((359,48,751,128),radius=16,fill='#050608')
        d.rectangle((359,48,751,89),fill='#050608')
        d.ellipse((546,79,564,97),fill='#0D1725',outline='#293440',width=1)
        d.ellipse((552,84,557,89),fill='#4A607E')
        return frame
