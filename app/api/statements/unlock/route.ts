import {statementPageText} from '../../../../lib/pdf-layout';
import {createClient} from '@supabase/supabase-js';
import {openPassword,sealPassword} from '../../../../lib/pdf-password';
export const runtime='nodejs';
const reply=(data:object,status=200)=>Response.json(data,{status,headers:{'Cache-Control':'no-store'}});
export async function POST(request:Request){
 const url=process.env.NEXT_PUBLIC_SUPABASE_URL,key=process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,serviceKey=process.env.SUPABASE_SERVICE_ROLE_KEY;
 if(!url||!key||!serviceKey)return reply({error:'Configure o serviço de leitura protegida no servidor.'},503);
 const authorization=request.headers.get('authorization')??'';
 const db=createClient(url,key,{global:{headers:{Authorization:authorization}},auth:{persistSession:false}}),auth=await db.auth.getUser();if(auth.error||!auth.data.user)return reply({error:'Não autorizado'},401);
 if(Number(request.headers.get('content-length')??0)>16*1024*1024)return reply({error:'Arquivo muito grande'},413);
 try{
 const form=await request.formData(),file=form.get('file'),card=String(form.get('card')??''),password=String(form.get('password')??''),save=form.get('save')==='true';
 if(!(file instanceof File)||file.size>15*1024*1024||password.length>256)return reply({error:'Arquivo ou senha inválidos'},400);
 const allowed=await db.from('credit_cards').select('id').eq('id',card).maybeSingle();if(!allowed.data)return reply({error:'Cartão indisponível'},403);
 const service=createClient(url,serviceKey,{auth:{persistSession:false}}),user=auth.data.user.id;
 let candidate=password,hadSaved=false;
 if(!candidate){const stored=await service.from('card_pdf_passwords').select('encrypted_password').eq('user_id',user).eq('card_id',card).maybeSingle();if(stored.data)try{hadSaved=true;candidate=openPassword(stored.data.encrypted_password,user,card)}catch{return reply({needsPassword:true,hasSaved:hadSaved})}}
 const canvas=await import('@napi-rs/canvas');Object.assign(globalThis,{DOMMatrix:canvas.DOMMatrix,ImageData:canvas.ImageData,Path2D:canvas.Path2D});
 const pdf=await import('pdfjs-dist/legacy/build/pdf.mjs'),task=pdf.getDocument({data:new Uint8Array(await file.arrayBuffer()),password:candidate,verbosity:0});
 let doc;try{doc=await task.promise}catch{await task.destroy();return reply({needsPassword:true,hasSaved:hadSaved})}
 const pages:{text:string;image?:string}[]=[];
 try{if(doc.numPages>30)return reply({error:'PDF limitado a 30 páginas'},400);
 for(let n=1;n<=doc.numPages;n++){const page=await doc.getPage(n),content=await page.getTextContent();const text=statementPageText(content.items.filter((i):i is Extract<typeof i,{str:string}>=>'str' in i));
 if(text.trim().length<10){const viewport=page.getViewport({scale:Math.min(2,1600/page.getViewport({scale:1}).width,2200/page.getViewport({scale:1}).height)}),surface=canvas.createCanvas(Math.ceil(viewport.width),Math.ceil(viewport.height));await page.render({canvas:surface as never,canvasContext:surface.getContext('2d') as never,viewport}).promise;pages.push({text,image:surface.toDataURL('image/png')})}else pages.push({text});
 }
 if(pages.reduce((n,p)=>n+p.text.length+(p.image?.length??0),0)>3*1024*1024)return reply({error:'PDF digitalizado muito grande para abertura protegida. Divida o documento ou use CSV.'},413);
 if(save&&password){const result=await service.from('card_pdf_passwords').upsert({user_id:user,card_id:card,encrypted_password:sealPassword(password,user,card),updated_at:new Date().toISOString()});if(result.error)return reply({error:'PDF aberto, mas não foi possível salvar a senha. Revise a configuração do servidor.'},503)}
 return reply({pages});
 }finally{await task.destroy()}
 }catch{return reply({error:'Não foi possível abrir o PDF protegido. Verifique a configuração ou tente outro arquivo.'},400)}
}
