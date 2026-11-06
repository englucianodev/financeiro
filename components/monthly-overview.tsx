"use client";
import {useMemo} from 'react';
import {ChartPie,ArrowDownLeft,ArrowUpRight,TrendingUp,TriangleAlert} from 'lucide-react';
import {monthlySummary,monthLabel,type ViewEvent} from '@/lib/finance-view';
import {useViewState,validMonth} from '@/lib/use-view-state';
import {today,brl} from '@/lib/money';
import MonthNav from './month-nav';
type Slice={name:string;value:number;color:string;percent:number};
export default function MonthlyOverview({events,categories,persistenceKey}:{events:ViewEvent[];categories:{name:string;kind:string;color:string}[];persistenceKey:string}){
 const [month,setMonth]=useViewState(persistenceKey+':chart-month',today().slice(0,7),validMonth);
 const [mode,setMode]=useViewState<'categories'|'balance'>(persistenceKey+':chart-mode','categories',(v):v is 'categories'|'balance'=>v==='categories'||v==='balance');
 const summary=useMemo(()=>monthlySummary(events,month,categories),[events,month,categories]);
 const balanceTotal=summary.income+summary.expense;
 const slices:Slice[]=mode==='categories'?summary.categories:[{name:'Entradas',value:summary.income,color:'#167d8d',percent:balanceTotal?summary.income/balanceTotal*100:0},{name:'Saídas',value:summary.expense,color:'#e67a59',percent:balanceTotal?summary.expense/balanceTotal*100:0}].filter(s=>s.value>0);
 const total=slices.reduce((sum,s)=>sum+Math.round(s.value*100),0)/100,circumference=2*Math.PI*88;let offset=0;
 return <section id="monthly-overview" className="card monthly-overview" aria-label="Análise mensal">
  <div className="section-heading"><div><span className="eyebrow"><ChartPie size={15}/> CADA ESCOLHA CONTA</span><h2>Seu mês em números</h2></div><span className="overview-badge">Visão completa</span></div>
  <MonthNav month={month} onChange={setMonth} context="do gráfico"/>
  <div className="segmented-control" role="group" aria-label="Tipo de análise"><button aria-pressed={mode==='categories'} onClick={()=>setMode('categories')}>Categorias</button><button aria-pressed={mode==='balance'} onClick={()=>setMode('balance')}>Entradas e saídas</button></div>
  <div className="overview-content"><div className="donut-panel"><div className="donut-chart">
   <svg viewBox="0 0 240 240" role="img" aria-label={(mode==='categories'?'Despesas por categoria':'Entradas e saídas')+' de '+monthLabel(month)}><circle cx="120" cy="120" r="88" fill="none" stroke="var(--line)" strokeWidth="26"/>{slices.map(slice=>{const size=slice.value/total*circumference,start=offset;offset+=size;return <circle key={slice.name} cx="120" cy="120" r="88" fill="none" stroke={slice.color} strokeWidth="26" strokeDasharray={`${Math.max(0,size-(slices.length>1?3:0))} ${circumference}`} strokeDashoffset={-start} transform="rotate(-90 120 120)"><title>{slice.name+': '+brl(slice.value)+' · '+slice.percent.toLocaleString('pt-BR',{maximumFractionDigits:1})+'%'}</title></circle>})}</svg>
   <div className="donut-center"><span>{mode==='categories'?'Despesas do mês':summary.balance<0?'Déficit do mês':'Saldo do mês'}</span><strong className={mode==='balance'&&summary.balance<0?'negative':''}>{brl(mode==='categories'?summary.expense:summary.balance)}</strong><small>{mode==='categories'?summary.categories.length+' categorias':'Entradas − saídas'}</small></div>
  </div>{mode==='balance'&&<p className={'balance-result '+(summary.balance<0?'has-deficit':'has-surplus')} role="status">{summary.balance<0?<TriangleAlert size={18}/>:<TrendingUp size={18}/>}<span>{summary.balance<0?'Déficit previsto de '+brl(-summary.balance):summary.balance>0?'Sem déficit · sobra de '+brl(summary.balance):'Sem déficit · mês equilibrado'}</span></p>}<p className="chart-note">Por vencimento, incluindo lançamentos pagos e previstos. Transferências internas ficam fora do balanço. Despesas anotadas no cartão são consideradas na fatura.</p></div>
  <div className="category-breakdown"><h3>{mode==='categories'?'Para onde vai o dinheiro':'O equilíbrio do mês'}</h3>{slices.length?<ul aria-label={mode==='categories'?'Categorias de despesas do mês':'Totais de entradas e saídas'}>{slices.map(slice=><li key={slice.name} style={{'--category-color':slice.color} as React.CSSProperties}><div className="category-topline"><span className="category-name"><i aria-hidden="true"/>{mode==='balance'&&(slice.name==='Entradas'?<ArrowDownLeft size={16}/>:<ArrowUpRight size={16}/>)}{slice.name}</span><strong>{brl(slice.value)}</strong></div><div className="category-bottomline"><div className="category-meter"><span style={{width:slice.percent+'%'}}/></div><span>{slice.percent.toLocaleString('pt-BR',{maximumFractionDigits:1})}%</span></div></li>)}</ul>:<div className="chart-empty"><ChartPie size={28}/><p>{mode==='categories'?'Nenhuma despesa neste mês.':'Nenhuma entrada ou saída neste mês.'}</p><span>Use as setas para explorar outros meses.</span></div>}</div></div>
 </section>
}
