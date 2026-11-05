"use client";
import {useEffect,useMemo,useRef,useState} from 'react';import {supabase} from '@/lib/supabase';import {PasswordUpdate,RecoveryRequest} from '@/components/password-management';
function ResetPassword(){
 const initialUrl=useRef(typeof window==='undefined'?null:window.location.href);
 const db=useMemo(()=>supabase(),[]),operation=useRef<Promise<boolean>|null>(null);const [stage,setStage]=useState<'loading'|'ready'|'invalid'>('loading');
 useEffect(()=>{
  let mounted=true;
  async function verify(){
   const url=new URL(initialUrl.current??location.href),token=url.searchParams.get('token_hash'),hasCode=url.searchParams.has('code'),fragment=new URLSearchParams(url.hash.slice(1));
   try{
    if(url.searchParams.has('error')||fragment.has('error'))return false;
    if(token){if(url.searchParams.get('type')!=='recovery')return false;const {data,error}=await db.auth.verifyOtp({token_hash:token,type:'recovery'});if(error||!data.session)return false;try{sessionStorage.setItem('financas:password-recovery',data.session.user.id)}catch{}return true;}
    const {error:initError}=await db.auth.initialize();if(initError)return false;
    const {data,error}=await db.auth.getSession();if(error||!data.session)return false;
    const callbackVerified=(hasCode&&!new URL(location.href).searchParams.has('code'))||(fragment.get('type')==='recovery'&&!location.hash);
    if(callbackVerified){try{sessionStorage.setItem('financas:password-recovery',data.session.user.id)}catch{}return true;}
    return !hasCode&&!fragment.size&&sessionStorage.getItem('financas:password-recovery')===data.session.user.id;
   }catch{return false}finally{initialUrl.current=null;history.replaceState(history.state,'',location.pathname)}
  }
  if(!operation.current)operation.current=verify();operation.current.then(valid=>{if(mounted)setStage(valid?'ready':'invalid')});
  return()=>{mounted=false};
 },[db]);
 return <main className="card max-w-md mx-auto p-6 mt-12 space-y-4"><h1>Redefinir senha</h1>{stage==='loading'?<p aria-live="polite">Validando seu link…</p>:stage==='ready'?<PasswordUpdate db={db} onSaved={()=>{try{sessionStorage.removeItem('financas:password-recovery')}catch{}}}/>:<><p role="alert">Link inválido ou expirado. Solicite um novo link por e-mail.</p><RecoveryRequest db={db}/><a href="/">Voltar ao login</a></>}</main>
}
export default function RecoveryPage(){if(!process.env.NEXT_PUBLIC_SUPABASE_URL||!process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY)return <main className="card"><p>Configure a conexão com o Supabase.</p></main>;return <ResetPassword/>}
