"use client";
import {useEffect,useState} from 'react';
import Link from 'next/link';
import {usePathname} from 'next/navigation';
import {Smartphone,X} from 'lucide-react';
import {APP_PAGE_PATH,BANNER_DISMISS_KEY,isAndroidBrowser,isBannerDismissed} from '@/lib/app-download';

function readDismissedAt():string|null{try{return localStorage.getItem(BANNER_DISMISS_KEY)}catch{return null}}
function saveDismissedAt(at:number){try{localStorage.setItem(BANNER_DISMISS_KEY,String(at))}catch{/* sem armazenamento: o aviso só some nesta visita */}}

/** Aviso no topo, só para quem abre o site no navegador de um Android (fora do app). */
export default function AppDownloadBanner(){
  const pathname=usePathname();
  const [visible,setVisible]=useState(false);
  useEffect(()=>{
    // Decidido no navegador, depois da hidratação: o servidor não sabe qual é o aparelho.
    setVisible(isAndroidBrowser(navigator.userAgent)&&!isBannerDismissed(readDismissedAt(),Date.now()));
  },[]);
  if(!visible||pathname===APP_PAGE_PATH)return null;
  const dismiss=()=>{saveDismissedAt(Date.now());setVisible(false)};
  return <aside className="app-banner" aria-label="Aplicativo Duo para Android">
    <Smartphone size={22} aria-hidden="true"/>
    <p><strong>Duo agora tem app para Android.</strong> <span>Mesma conta, abre direto no celular.</span></p>
    <Link className="app-banner-cta" href={APP_PAGE_PATH}>Baixar o app</Link>
    <button type="button" className="app-banner-close" onClick={dismiss} aria-label="Fechar aviso do aplicativo"><X size={18}/></button>
  </aside>;
}
