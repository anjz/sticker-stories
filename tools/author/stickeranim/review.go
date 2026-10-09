package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"stickerstories/tools/internal/manifest"
	"stickerstories/tools/internal/stickerimg"
)

// reviewItem is one animation on the review page.
type reviewItem struct {
	Key, Description, Kind string
	Sheet, Sticker         string // paths relative to the page
	Columns, Count         int
	FrameW, FrameH         int
	Hold                   []float64
	Rest, StickerBox       manifest.UnitBox
	Loop                   *manifest.FrameRange
	QA                     []stickerimg.FrameQA
	Flagged                int
}

// runReview writes out/anims/review.html: every assembled animation (or the
// -only ones) playing at its real timing over its sticker, with each
// frame's checks — the page to judge an animation by before install.
func runReview(args []string) error {
	fs := flag.NewFlagSet("review", flag.ExitOnError)
	packDir := fs.String("pack", "", "pack directory")
	artDir := fs.String("art", "", "art directory (default author/art/<packID>)")
	only := fs.String("only", "", "comma-separated animation ids, sticker ids or sticker.animation keys")
	fs.Parse(args)
	c, err := load(*packDir, *artDir)
	if err != nil {
		return err
	}
	r := &renderer{c: c}
	want := map[string]bool{}
	for _, id := range strings.Split(*only, ",") {
		if id = strings.TrimSpace(id); id != "" {
			want[id] = true
		}
	}
	var items []reviewItem
	for _, a := range c.cfg.Animations {
		if len(want) > 0 && !want[a.ID] && !want[a.Sticker] && !want[a.key()] {
			continue
		}
		var side manifest.StickerAnimation
		data, err := os.ReadFile(r.out(a.key() + ".json"))
		if err != nil || json.Unmarshal(data, &side) != nil {
			continue // not assembled yet
		}
		it := reviewItem{Key: a.key(), Description: a.storyDescription(), Kind: string(a.kind()),
			Sheet: a.key() + ".png", Sticker: "../stickers/" + a.Sticker + ".png",
			Columns: side.Columns, Count: side.Count, FrameW: side.Frame.Width, FrameH: side.Frame.Height,
			Hold: side.Hold, Rest: side.Rest, StickerBox: side.StickerBox, Loop: side.Loop}
		if q, err := os.ReadFile(r.out(a.key() + ".qa.json")); err == nil {
			json.Unmarshal(q, &it.QA)
			for _, f := range it.QA {
				if len(f.Problems) > 0 {
					it.Flagged++
				}
			}
		}
		items = append(items, it)
	}
	if len(items) == 0 {
		return fmt.Errorf("no assembled animations to review in %s", r.out())
	}
	data, _ := json.Marshal(items)
	page := strings.Replace(reviewPage, "/*ITEMS*/", string(data), 1)
	path := r.out("review.html")
	if err := os.WriteFile(path, []byte(page), 0o644); err != nil {
		return err
	}
	abs, _ := filepath.Abs(path)
	fmt.Printf("✓ %d animation(s) on %s\n  open %s\n", len(items), path, abs)
	return nil
}

// reviewPage plays each animation over its sticker the way the app does:
// the frames scaled and placed so their rest box lands on the sticker's.
const reviewPage = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Animation review</title>
<style>
:root{--bg:#1d1f24;--card:#2a2d34;--ink:#eceef2;--dim:#9aa0ab;--bad:#ff8a65;--ok:#7fd18b}
body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.45 -apple-system,system-ui,sans-serif;padding:16px}
h1{font-size:18px;margin:0 0 4px} p.lead{color:var(--dim);margin:0 0 16px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(420px,1fr));gap:16px}
.card{background:var(--card);border-radius:12px;padding:12px}
.card h2{font-size:15px;margin:0} .card .d{color:var(--dim);font-size:12px;margin:2px 0 8px}
.stage{display:flex;gap:10px;align-items:flex-end}
canvas{background:#565b66;border-radius:8px;width:200px;height:200px}
.ctl{display:flex;gap:6px;margin:8px 0;flex-wrap:wrap} button{background:#3a3e47;color:var(--ink);border:0;border-radius:6px;padding:4px 10px;cursor:pointer}
.bars{display:flex;align-items:flex-end;gap:2px;height:46px;margin-top:6px}
.bars i{display:block;width:8px;background:var(--ok);border-radius:2px 2px 0 0}
.bars i.bad{background:var(--bad)} .bars i.on{outline:2px solid #fff}
ul{margin:6px 0 0;padding-left:18px;color:var(--bad);font-size:12px}
.flag{float:right;font-size:12px;color:var(--dim)} .flag.bad{color:var(--bad)}
</style></head><body>
<h1>Animation review</h1>
<p class="lead">Each animation plays at its real timing on the sticker's box, beside the still sticker. Bars: each frame's solid area against the sticker's (the line is 100 %); orange frames failed a check. Click a bar to stop on that frame.</p>
<div class="grid" id="g"></div>
<script>
const items=/*ITEMS*/;
const g=document.getElementById('g');
items.forEach(it=>{
  const card=document.createElement('div');card.className='card';
  const flag='<span class="flag'+(it.Flagged?' bad':'')+'">'+(it.QA&&it.QA.length?(it.Flagged?it.Flagged+' frame(s) flagged':'all frames pass'):'no checks (not scaffolded)')+'</span>';
  card.innerHTML=flag+'<h2></h2><div class="d"></div><div class="stage"><canvas width="400" height="400"></canvas><canvas width="400" height="400"></canvas></div><div class="ctl"><button data-a="play">Pause</button><button data-a="prev">◀</button><button data-a="next">▶</button><button data-a="slow">½×</button><span class="f"></span></div><div class="bars"></div><ul></ul>';
  card.querySelector('h2').textContent=it.Key+' ('+it.Kind+', '+it.Count+' frames)';
  card.querySelector('.d').textContent=it.Description;
  g.appendChild(card);
  const [cv,still]=card.querySelectorAll('canvas'), ctx=cv.getContext('2d'), sctx=still.getContext('2d');
  const sheet=new Image(), sticker=new Image(); sheet.src=it.Sheet; sticker.src=it.Sticker;
  let i=0, playing=true, speed=1, last=0, acc=0;
  // The app's mapping: the frame is scaled so its rest box lands on the sticker box in a 400 px square.
  function draw(){
    ctx.clearRect(0,0,400,400);
    const s=(it.StickerBox.width*400)/(it.Rest.width*it.FrameW);
    const ox=it.StickerBox.x*400-it.Rest.x*it.FrameW*s, oy=it.StickerBox.y*400-it.Rest.y*it.FrameH*s;
    const c=i%it.Columns, r=Math.floor(i/it.Columns);
    ctx.drawImage(sheet,c*it.FrameW,r*it.FrameH,it.FrameW,it.FrameH,ox,oy,it.FrameW*s,it.FrameH*s);
    card.querySelector('.f').textContent='frame '+(i+1)+' · '+(it.Hold[i]||0).toFixed(2)+' s';
    card.querySelectorAll('.bars i').forEach((b,k)=>b.classList.toggle('on',k===i));
  }
  sticker.onload=()=>{sctx.clearRect(0,0,400,400);sctx.drawImage(sticker,0,0,400,400)};
  sheet.onload=draw;
  const bars=card.querySelector('.bars'), ul=card.querySelector('ul');
  for(let k=0;k<it.Count;k++){
    const q=(it.QA||[])[k]; const b=document.createElement('i');
    const h=q?Math.max(4,Math.min(46,q.area*30)):20; b.style.height=h+'px';
    if(q&&q.problems&&q.problems.length){b.className='bad';const li=document.createElement('li');li.textContent='frame '+q.frame+': '+q.problems.join('; ');ul.appendChild(li)}
    b.onclick=()=>{playing=false;i=k;draw();card.querySelector('[data-a=play]').textContent='Play'};
    bars.appendChild(b);
  }
  card.querySelector('.ctl').onclick=e=>{const a=e.target.dataset.a;if(!a)return;
    if(a==='play'){playing=!playing;e.target.textContent=playing?'Pause':'Play'}
    if(a==='prev'){playing=false;i=(i+it.Count-1)%it.Count;draw()}
    if(a==='next'){playing=false;i=(i+1)%it.Count;draw()}
    if(a==='slow'){speed=speed===1?0.5:1;e.target.textContent=speed===1?'½×':'1×'}};
  function tick(t){ if(!last)last=t; const dt=(t-last)/1000; last=t;
    if(playing&&sheet.complete){acc+=dt*speed; while(acc>=(it.Hold[i]||1/12)){acc-=(it.Hold[i]||1/12); i++;
      if(it.Loop&&i>it.Loop.to){i=it.Loop.from} else if(i>=it.Count){i=0;acc-=0.6}} draw()}
    requestAnimationFrame(tick)}
  requestAnimationFrame(tick);
});
</script></body></html>
`
