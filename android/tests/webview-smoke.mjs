import {chromium} from '@playwright/test';
import {execFileSync} from 'node:child_process';
import assert from 'node:assert/strict';
const adb=process.env.DUO_ADB??'C:/Users/DEV/AppData/Local/Android/Sdk/platform-tools/adb.exe';
const device='emulator-5580'; // Never install or drive a connected physical phone implicitly.
const run=(...args)=>execFileSync(adb,['-s',device,...args],{encoding:'utf8',timeout:20000}).trim();
let browser,page;
async function connectApp(){
 if(browser)await browser.close().catch(()=>{});
 run('shell','am','start','-W','-f','0x24000000','-n','br.net.luciano.duo/.MainActivity');
 const pid=run('shell','pidof','br.net.luciano.duo').split(/\s+/)[0];assert.match(pid,/^\d+$/);
 run('forward','tcp:9223','localabstract:webview_devtools_remote_'+pid);
 browser=await chromium.connectOverCDP('http://127.0.0.1:9223');
 page=browser.contexts()[0].pages()[0];assert.ok(page,'WebView must be open in the app');
 await page.waitForURL(/https:\/\/(www\.)?luciano\.net\.br\//);
 await page.waitForFunction(()=>Boolean(window.__duoNativePort),{timeout:20000});
}
await connectApp();
try {
 await page.waitForFunction(()=>Boolean(window.__duoNativePort),{timeout:20000});
 assert.equal(await page.title(),'Duo');
 await page.getByPlaceholder('E-mail',{exact:true}).waitFor();
 console.log('Android WebView: live Duo login and trusted native channel OK');
 await page.evaluate(()=>navigator.clipboard.writeText('Teste local Duo, sem dados financeiros'));
 async function waitWindow(pattern){
  for(let i=0;i<12;i++){
   const focus=run('shell','dumpsys','window');
   const current=focus.split('\n').filter(l=>/mCurrentFocus|mFocusedApp/.test(l)).join('\n');
   if(pattern.test(current))return current;
   await new Promise(resolve=>setTimeout(resolve,500));
  }
  throw Error('Native window not found: '+pattern);
 }
 await page.evaluate(()=>navigator.share({title:'Teste Duo',text:'Teste local sem envio de mensagem'}));
 await waitWindow(/intentresolver|ChooserActivity|ResolverActivity/);
 run('shell','input','keyevent','4');await connectApp();await waitWindow(/br.net.luciano.duo/);
 console.log('Android: copy and native sharing chooser opened/cancelled without sending OK');
 await page.evaluate(()=>{const a=document.createElement('a');a.download='duo-checklist-test.txt';a.href=URL.createObjectURL(new Blob(['Checklist de teste, sem dados reais'],{type:'text/plain'}));a.click()});
 await waitWindow(/documentsui/);
 run('shell','input','keyevent','4');await connectApp();await waitWindow(/br.net.luciano.duo/);
 console.log('Android: TXT download opened system save dialog (filename covered by bridge test) OK');
 await page.evaluate(()=>{const i=document.createElement('input');i.type='file';i.accept='.pdf,.csv,.ofx';document.body.append(i);i.click()});
 await waitWindow(/documentsui/);run('shell','input','keyevent','4');await connectApp();await waitWindow(/br.net.luciano.duo/);
 console.log('Android: PDF/CSV/OFX file picker opened/cancelled without upload OK');
 await page.evaluate(()=>{const d=document.createElement('dialog');d.id='duo-test-dialog';d.textContent='Teste de voltar, sem gravação';document.body.append(d);d.showModal()});
 run('shell','input','keyevent','4');
 await page.waitForFunction(()=>!document.querySelector('#duo-test-dialog')?.open);
 await waitWindow(/br.net.luciano.duo/);
 console.log('Android: Back closes HTML dialog instead of exiting the application OK');
} finally {await browser.close()}
