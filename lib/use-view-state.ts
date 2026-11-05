"use client";
import {useEffect,useState} from 'react';
/** Stores navigation only; sessions remain managed by Supabase cookies. */
export function useViewState<T>(key:string|null,initial:T,valid:(value:unknown)=>value is T){
 const [state,setState]=useState(initial),[loaded,setLoaded]=useState<string|null>(null);
 useEffect(()=>{if(!key)return;try{const value=JSON.parse(sessionStorage.getItem(key)??'null');setState(valid(value)?value:initial)}catch{setState(initial)}setLoaded(key)},[key]);
 useEffect(()=>{if(!key||loaded!==key)return;try{sessionStorage.setItem(key,JSON.stringify(state))}catch{/* Navigation still works when storage is unavailable. */}},[key,loaded,state]);
 return [state,setState] as const;
}
export const validPeriod=(v:unknown):v is number=>Number.isInteger(v)&&Number(v)>=0&&Number(v)<=5;

export const validDate=(v:unknown):v is string=>typeof v==='string'&&/^\d{4}-\d{2}-\d{2}$/.test(v)&&Number.isFinite(Date.parse(v+'T12:00:00Z'));
export const validMonth=(v:unknown):v is string=>typeof v==='string'&&/^\d{4}-(0[1-9]|1[0-2])$/.test(v);
export function usePagePosition(key:string|null){
 useEffect(()=>{
  if(!key)return;let restored=false,frame=0;
  const save=()=>{if(restored)try{sessionStorage.setItem(key,String(window.scrollY))}catch{}};
  frame=requestAnimationFrame(()=>{frame=requestAnimationFrame(()=>{try{const saved=sessionStorage.getItem(key);if(saved!==null&&Number.isFinite(Number(saved)))window.scrollTo({top:Number(saved),behavior:'instant'})}catch{}restored=true;})});
  window.addEventListener('pagehide',save);window.addEventListener('scroll',save,{passive:true});
  return()=>{cancelAnimationFrame(frame);window.removeEventListener('pagehide',save);window.removeEventListener('scroll',save)};
 },[key]);
}
