import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const source=readFileSync(new URL('../app/src/main/java/br/net/luciano/duo/MainActivity.java',import.meta.url),'utf8');
const block=source.slice(source.indexOf('String script ='),source.indexOf('web.evaluateJavascript(script'));
const script=[...block.matchAll(/"(?:[^"\\]|\\.)*"/g)].map(m=>JSON.parse(m[0])).join('');
const messages=[],listeners={},alerts=[];let originalClicks=0;
class Anchor {
 constructor(href,download='',attached=false){this.href=href;this.download=download;this.attached=attached}
 hasAttribute(name){return name==='download'&&Boolean(this.download)}
 click(){originalClicks++;if(this.attached)listeners.click?.({target:this,preventDefault(){}})}
 closest(){return this}
}
const win={addEventListener(type,callback){listeners[type]=callback}};
const context={window:win,navigator:{},location:{origin:'https://www.luciano.net.br'},HTMLAnchorElement:Anchor,
 document:{addEventListener(type,callback){listeners[type]=callback}},
 fetch:async()=>({blob:async()=>({size:15,type:'text/plain',text:async()=>'Checklist local'})}),alert:m=>alerts.push(m)};
vm.runInNewContext(script,context);
const port={postMessage(raw){messages.push(JSON.parse(raw))}};
listeners.message({data:'duo-native-port',ports:[port],source:{},origin:'https://evil.example'});
assert.equal(win.__duoNativePort,undefined,'Untrusted iframe must not obtain the native channel');
listeners.message({data:'duo-native-port',ports:[port],source:null,origin:'null'});
new Anchor('blob:https://www.luciano.net.br/test','despesas.txt',false).click();
await new Promise(resolve=>setTimeout(resolve,0));
assert.ok(messages.some(m=>m.type==='save'&&m.name==='despesas.txt'&&m.text==='Checklist local'),'Detached blob anchor must open native save, as used by the real checklist');
const before=originalClicks;new Anchor('https://www.luciano.net.br/','',false).click();assert.equal(originalClicks,before+1,'Normal anchor must retain its original click');
console.log('Android native bridge: detached checklist export, native text and iframe-origin guard OK');
