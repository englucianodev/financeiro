import {createClient} from '@supabase/supabase-js';
import {timingSafeEqual} from 'node:crypto';
import {dueSlots,emailText,type PendingEmail} from '@/lib/email-notifications';
export const runtime='nodejs';
export async function POST(request:Request){
 const secret=process.env.NOTIFICATIONS_CRON_SECRET??'',provided=request.headers.get('authorization')??'',expected='Bearer '+secret;
 if(!secret||Buffer.byteLength(provided)!==Buffer.byteLength(expected)||!timingSafeEqual(Buffer.from(provided),Buffer.from(expected)))return new Response('Unauthorized',{status:401});
 const {SUPABASE_SERVICE_ROLE_KEY,RESEND_API_KEY,NOTIFICATIONS_FROM,NEXT_PUBLIC_SUPABASE_URL,APP_URL}=process.env;
 if(!SUPABASE_SERVICE_ROLE_KEY||!RESEND_API_KEY||!NOTIFICATIONS_FROM||!NEXT_PUBLIC_SUPABASE_URL||!APP_URL)return new Response('Configure notification environment variables',{status:503});
 const db=createClient(NEXT_PUBLIC_SUPABASE_URL,SUPABASE_SERVICE_ROLE_KEY,{auth:{persistSession:false}});let sent=0;
 const settings=await db.from('notification_settings').select('*').eq('enabled',true);if(settings.error)return new Response('Settings unavailable',{status:503});
 for(const s of settings.data??[]){const {date,slots}=dueSlots(s);if(!slots.length)continue;
  const snapshot=await db.rpc('notification_snapshot',{p_household:s.household_id,p_date:date});if(snapshot.error)continue;const rows=snapshot.data as PendingEmail[];if(!rows?.length)continue;
  const m=await db.from('household_members').select('user_id,display_name').eq('household_id',s.household_id);if(m.error)continue;
  for(const member of m.data??[]){if(!s.recipients.includes(member.user_id))continue;
   const user=await db.auth.admin.getUserById(member.user_id);if(!user.data.user?.email||!user.data.user.email_confirmed_at||user.data.user.banned_until&&new Date(user.data.user.banned_until)>new Date())continue;
   for(const slot of slots){const payload:{from:string;to:string[];subject:string;text:string}={from:NOTIFICATIONS_FROM,to:[user.data.user.email],subject:'Pendências financeiras · '+date+' · '+(slot==='morning'?'manhã':'noite'),text:emailText(rows,m.data??[],date,APP_URL)};
    const claim:{data:{id:string;payload:typeof payload}|null;error:unknown}=await db.rpc('notification_claim',{p_household:s.household_id,p_user:member.user_id,p_date:date,p_slot:slot,p_payload:payload});if(claim.error||!claim.data)continue;if(claim.data.payload.to?.[0]!==user.data.user.email){await db.from('notification_deliveries').update({status:'skipped',error:'Destinatário alterado após a primeira tentativa'}).eq('id',claim.data.id);continue;}
    try{const response=await fetch('https://api.resend.com/emails',{method:'POST',headers:{Authorization:'Bearer '+RESEND_API_KEY,'Content-Type':'application/json','Idempotency-Key':'finance-'+claim.data.id},body:JSON.stringify(claim.data.payload),signal:AbortSignal.timeout(15000)});const result=await response.json();if(!response.ok)throw new Error('Resend HTTP '+response.status);await db.from('notification_deliveries').update({status:'sent',provider_id:result.id,error:null}).eq('id',claim.data.id);sent++}catch(e){await db.from('notification_deliveries').update({status:'failed',error:String(e).slice(0,300)}).eq('id',claim.data.id)}
   }
  }
 }return Response.json({sent});
}
