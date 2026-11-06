#!/usr/bin/env node
'use strict';
// Real canvas input only. No injected gameplay commands, native clients or bots.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const {createRequire} = require('node:module');
const scratch = process.env.GALCON_QA_DEPS || '/Users/me/.hermes/cache/scratch/lvd-browser-qa';
const deps = createRequire(path.join(scratch, 'package.json'));
const {chromium} = deps('playwright');
const url = process.env.GALCON_QA_URL || 'http://10.10.11.114:4173/gameshowcase/games/galcon/play/?server=ws%3A%2F%2F127.0.0.1%3A19931%2Fws';
const out = process.env.GALCON_QA_OUT || path.join(scratch, 'run-' + new Date().toISOString().replace(/[:.]/g, '-'));
fs.mkdirSync(out, {recursive:true});
const report = {url, out, steps:[], peers:[], passed:false};
assert.ok(['19931','9911'].includes(new URL(new URL(url).searchParams.get('server')).port),'Use QA candidate or explicitly selected live relay');
const kinds = 'Hello Welcome ListRooms RoomList CreateRoom JoinRoom RoomState ConfigureRoom ClaimSeat ReleaseSeat Ready StartMatch BeginMatch SubmitCommand CommandAck TickPacket AppliedTick Catchup CaughtUp ReportHash MatchStatus LeaveRoom KickParticipant ReturnLobby FinishMatch Received Keepalive Failure AbortMatch PauseMatch ResizeRoom'.split(' ');
function decode(data) {
  const b = Buffer.isBuffer(data) ? data : Buffer.from(data);
  if (b.length < 64 || b.toString('ascii',0,4) !== 'PWRM') return {unknown:true};
  let i=64;
  const u=()=>{const n=b.readUInt32LE(i);i+=4;return n};
  const wide=()=>{const n=b.readBigUInt64LE(i).toString();i+=8;return n};
  const bytes=()=>{const n=u();const s=b.subarray(i,i+n);i+=n;return s};
  const str=()=>bytes().toString('utf8');
  const m={kind:kinds[b.readUInt32LE(8)],match:b.readUInt32LE(20)};
  if(m.kind==='Welcome') m.participant=u();
  if(m.kind==='Hello'){m.game=str();m.gameplay=u();m.protocol=u();m.name=str();}
  if(['CreateRoom','ConfigureRoom','ResizeRoom'].includes(m.kind)){m.name=str();m.public=!!u();m.rate=u();m.count=u();m.config=str();}
  if(m.kind==='JoinRoom') m.room=str();
  if(m.kind==='ClaimSeat'){m.seat=u();m.name=str();}
  if(m.kind==='RoomState'){
    m.room=str();m.name=str();m.owner=u();m.revision=u();m.phase=u();m.rate=u();m.public=!!u();m.config=str();
    m.participants=Array.from({length:u()},()=>({id:u(),name:str(),connected:!!u(),ready:!!u()}));
    m.seats=Array.from({length:u()},()=>({owner:u(),name:str()}));
  }
  if(m.kind==='SubmitCommand'){m.seat=u();m.sequence=wide();const p=bytes();m.action=Array.from({length:p.length/4},(_,j)=>p.readInt32LE(j*4));}
  if(m.kind==='ReportHash'||m.kind==='FinishMatch'){m.tick=u();m.hash=wide();}
  if(m.kind==='CommandAck'){m.sequence=wide();m.tick=u();}
  if(m.kind==='TickPacket'){m.tick=u();m.commands=Array.from({length:u()},()=>({participant:u(),seat:u(),sequence:wide(),payload:bytes().toString('hex')}));}else if(['AppliedTick','Catchup','CaughtUp'].includes(m.kind))m.tick=u();
  if(m.kind==='Failure')m.detail=str();
  return m;
}
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function wait(label, fn, timeout=12000){const end=Date.now()+timeout;while(Date.now()<end){if(await fn())return;await sleep(100);}throw new Error('Timeout: '+label);}
function step(s){report.steps.push(s);console.log(s);}
async function click(p,x,y,button='left'){await p.bringToFront();await p.mouse.move(x,y);await p.waitForTimeout(100);await p.mouse.down({button});await p.waitForTimeout(140);await p.mouse.up({button});await p.waitForTimeout(300);}
async function text(p,x,y,s){await click(p,x,y);await p.keyboard.press('Meta+A');await p.keyboard.press('Backspace');await p.keyboard.type(s,{delay:70});}
async function shot(peer,name){await peer.page.bringToFront();await peer.page.waitForTimeout(150);await peer.page.screenshot({path:path.join(out,peer.role+'-'+name+'.png'),timeout:10000});}
function last(peer,kind,direction='in'){return peer.messages.findLast(m=>m.direction===direction&&m.kind===kind);}
const peers=[];
async function main(){
 const browser=await chromium.launch({headless:false,args:['--disable-background-timer-throttling','--disable-backgrounding-occluded-windows','--disable-renderer-backgrounding','--enable-unsafe-swiftshader']});
 try{
 for (const role of ['host','guest']){
  const context=await browser.newContext({viewport:{width:1514,height:970},deviceScaleFactor:1});
  const page=await context.newPage(), peer={role,context,page,messages:[],console:[]};peers.push(peer);report.peers.push({role,messages:peer.messages,console:peer.console});
  const cdp=await context.newCDPSession(page);await cdp.send('Network.enable');await cdp.send('Network.setCacheDisabled',{cacheDisabled:true});
  page.on('console',m=>peer.console.push({type:m.type(),text:m.text()}));page.on('pageerror',e=>peer.console.push({type:'error',text:String(e)}));
  page.on('websocket',ws=>{for(const [event,direction] of [['framesent','out'],['framereceived','in']])ws.on(event,({payload})=>{try{peer.messages.push({at:Date.now(),direction,...decode(payload)});}catch(e){peer.console.push({type:'decode',text:String(e)});}});});
  await page.goto(url,{waitUntil:'load',timeout:60000});await page.waitForFunction(()=>window.Module && document.querySelector('#status')?.hidden,null,{timeout:60000});
  await page.evaluate(()=>{window.__snapshots=[];Module.polyworldGalconProbe=s=>{window.__snapshots.push(s);if(window.__snapshots.length>2000)window.__snapshots.shift();};window.__frames=[];const f=Module.polyworldFrame;Module.polyworldFrame=(tick,m)=>{window.__frames.push({tick,m,at:performance.now()});return f(tick,m);};});
  await shot(peer,'initial');
  await text(page,650,435,'QA '+role);await click(page,1133,647);
  await shot(peer,'named');await click(page,756,474);await wait(role+' welcome',()=>last(peer,'Welcome'));await shot(peer,'browser');
 }
 const [host,guest]=peers;
 await click(host.page,1340,432);await click(host.page,1200,500);await wait('create',()=>last(host,'RoomState')?.room);
 const room=last(host,'RoomState').room;report.room=room;assert.equal(last(host,'CreateRoom','out').public,false);
 await text(guest.page,1150,700,room);await click(guest.page,1200,764);await wait('join',()=>last(guest,'RoomState')?.room===room);
 for(const [i,p] of peers.entries()) {const seat=i?3:1;await click(p.page,620,i?364:290);await click(p.page,750,340);await wait('seat '+seat,()=>last(p,'RoomState').seats[seat].owner===last(p,'Welcome').participant);}
 for(const p of peers){await click(p.page,560,922);await wait('ready '+p.role,()=>last(p,'RoomState').participants.some(x=>x.id===last(p,'Welcome').participant&&x.ready));}
 await shot(host,'ready');await click(host.page,1350,922);for(const p of peers)await wait('begin '+p.role,()=>last(p,'BeginMatch'));
 await sleep(5000);for(const p of peers)await shot(p,'started');
 for(const p of peers)assert.ok(await p.page.evaluate(()=>Module.replayTick>20),p.role+': displayed authoritative ticks must advance beyond 20');
 for(const [i,p] of peers.entries()){
  const [sx,sy,tx,ty]=i?[539,177,1293,603]:[1416,533,486,247];
  await p.page.bringToFront();await p.page.mouse.move(sx,sy);await sleep(500);await p.page.mouse.down();await sleep(200);await p.page.mouse.move(tx,ty,{steps:20});await sleep(200);await p.page.mouse.up();
  await wait(p.role+' real drag submitted',()=>last(p,'SubmitCommand','out'));
  const command=last(p,'SubmitCommand','out');assert.equal(command.seat,i?3:1);assert.equal(command.action[0],2,'ordinary percent send');
  await wait(p.role+' command authoritative',()=>p.messages.some(m=>m.kind==='TickPacket'&&m.commands.some(c=>c.participant===last(p,'Welcome').participant&&c.sequence===command.sequence)));await shot(p,'fleet-a');await sleep(1000);await shot(p,'fleet-b');
  const snapshots=await p.page.evaluate(()=>window.__snapshots);
  if(process.env.GALCON_QA_REQUIRE_PROBE==='1')assert.ok(snapshots.length,'Build with -d:galconBrowserProbe and use ?qa=1');
  if(snapshots.length){const own=snapshots.filter(s=>s.ships.some(b=>b[1]===s.human));assert.ok(own.length>2,p.role+' own ships exist');const first=own[0];assert.ok(own.some(s=>s.tick>first.tick&&s.ships.some(b=>{const old=first.ships.find(o=>o[0]===b[0]&&o[1]===b[1]&&b[1]===s.human);return old&&Math.hypot(b[2]-old[2],b[3]-old[3])>5;})),p.role+' authoritative own ships move');report.peers.find(x=>x.role===p.role).snapshots=own;}
 }
 await wait('post-command matching hashes',()=>{const a=host.messages.filter(m=>m.kind==='ReportHash'),b=guest.messages.filter(m=>m.kind==='ReportHash');const tick=Math.max(...peers.flatMap(p=>p.messages.filter(m=>m.kind==='TickPacket'&&m.commands.length).map(m=>m.tick)));return a.some(x=>x.tick>tick&&b.some(y=>x.match===y.match&&x.tick===y.tick&&x.hash===y.hash));},20000);
 for(const receiver of peers)for(const sender of peers)assert.ok(receiver.messages.some(m=>m.kind==='TickPacket'&&m.commands.some(c=>c.participant===last(sender,'Welcome').participant&&c.sequence==='1')),'every peer receives every human order');
 assert.notEqual(last(host,'Welcome').participant,last(guest,'Welcome').participant);report.passed=true;
 }catch(e){report.error=e.stack;console.error(e.stack);process.exitCode=1;}
 finally {for(const p of peers){await shot(p,'final');report.peers.find(x=>x.role===p.role).frames=await p.page.evaluate(()=>window.__frames);};fs.writeFileSync(path.join(out,'report.json'),JSON.stringify(report,null,2));await browser.close();console.log(out);}
}main();
