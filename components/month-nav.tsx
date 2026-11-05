"use client";
import {ChevronLeft,ChevronRight} from 'lucide-react';
import {monthLabel,moveMonth} from '@/lib/finance-view';
export default function MonthNav({month,onChange,context}:{month:string;onChange:(month:string)=>void;context:'das pendências'|'do gráfico'}){
 return <nav className="month-nav" aria-label={'Navegação mensal '+context}>
  <button type="button" aria-label={'Mês anterior '+context} title={monthLabel(moveMonth(month,-1))} onClick={()=>onChange(moveMonth(month,-1))}><ChevronLeft size={20}/></button>
  <div aria-live="polite"><span className="month-caption">Visão mensal</span><strong>{monthLabel(month)}</strong></div>
  <button type="button" aria-label={'Próximo mês '+context} title={monthLabel(moveMonth(month,1))} onClick={()=>onChange(moveMonth(month,1))}><ChevronRight size={20}/></button>
 </nav>
}
