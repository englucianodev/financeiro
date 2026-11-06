import {statementPageText} from './pdf-layout';
export async function readStatementFile(file:File,progress:(s:string)=>void,protectedReader?:(file:File)=>Promise<string>){
 if(file.size>15*1024*1024)throw new Error('Arquivo limitado a 15 MB.');
 const buffer=await file.arrayBuffer(),hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',buffer))).map(b=>b.toString(16).padStart(2,'0')).join('');
 const format=file.name.toLowerCase().split('.').at(-1)??'';
 if(['csv','ofx'].includes(format))return {text:(new TextDecoder('utf-8').decode(buffer).includes('�')?new TextDecoder('windows-1252').decode(buffer):new TextDecoder('utf-8').decode(buffer)),hash,format};
 if(format!=='pdf')throw new Error('Selecione PDF, CSV ou OFX.');
 const pdfjs=await import('pdfjs-dist');pdfjs.GlobalWorkerOptions.workerSrc='/vendor/pdf.worker.min.mjs';
 const task=pdfjs.getDocument({data:buffer});let protectedPdf=false;task.onPassword=()=>{protectedPdf=true;void task.destroy()};let doc;try{doc=await task.promise}catch(e){await task.destroy();if(protectedPdf&&protectedReader)return {text:await protectedReader(file),hash,format};throw new Error(protectedPdf?'Este PDF exige senha.': 'Não foi possível ler o PDF.')}
 if(doc.numPages>30){await task.destroy();throw new Error('PDF limitado a 30 páginas; divida o documento antes de importar.')}
 let text='',worker:Awaited<ReturnType<typeof import('tesseract.js')['createWorker']>>|undefined;
 try{for(let i=1;i<=doc.numPages;i++){
  progress('Lendo página '+i+'/'+doc.numPages);const page=await doc.getPage(i),content=await page.getTextContent();text+=statementPageText(content.items.filter((i):i is Extract<typeof i,{str:string}>=>'str' in i));
  if(content.items.filter(item=>'str' in item).map(item=>'str' in item?item.str:'').join('').trim().length<10){
   if(!worker){const {createWorker}=await import('tesseract.js');let fail!:(e:Error)=>void;const failed=new Promise<never>((_,reject)=>{fail=reject});const timer=window.setTimeout(()=>fail(new Error('OCR não iniciou em 60 segundos. Verifique os recursos locais ou use CSV.')),60000);try{worker=await Promise.race([createWorker('por',1,{workerPath:'/vendor/ocr/worker.min.js',corePath:location.origin+'/vendor/ocr/tesseract-core-lstm.wasm.js',langPath:location.origin+'/vendor/ocr',logger:()=>{},gzip:false,errorHandler:e=>fail(new Error(String(e))),cacheMethod:'none',workerBlobURL:false}),failed])}finally{window.clearTimeout(timer)}}
   progress('OCR local da página '+i);const viewport=page.getViewport({scale:Math.min(2,1800/page.getViewport({scale:1}).width)}),canvas=document.createElement('canvas');canvas.width=viewport.width;canvas.height=viewport.height;
   await page.render({canvas,viewport}).promise;text+=(await worker.recognize(canvas)).data.text+'\n';canvas.width=0;canvas.height=0;
  }
 }}finally{await worker?.terminate();await task.destroy()}
 return {text,hash,format};
}

export async function recognizeProtectedPages(pages:{text:string;image?:string}[]){
 let text='';const {createWorker}=await import('tesseract.js');let worker:Awaited<ReturnType<typeof createWorker>>|undefined;
 try{for(const page of pages){text+=page.text+'\n';if(page.image){worker??=await createWorker('por',1,{workerPath:'/vendor/ocr/worker.min.js',corePath:location.origin+'/vendor/ocr/tesseract-core-lstm.wasm.js',langPath:location.origin+'/vendor/ocr',gzip:false,cacheMethod:'none'});text+=(await worker.recognize(page.image)).data.text+'\n'}}return text}finally{await worker?.terminate()}
}
