"use client";
// "Seu mês em números": só o gráfico de pizza (rosca), maior, com o rótulo em cada fatia.
// Passar o mouse (ou tocar) numa fatia amplia a fatia e mostra o valor e o percentual no centro.
import {useMemo} from 'react';
import {ChartPie, TrendingUp, TriangleAlert} from 'lucide-react';
import {monthlySummary, monthLabel, type ViewEvent} from '@/lib/finance-view';
import {useViewState, validMonth} from '@/lib/use-view-state';
import {today, brl} from '@/lib/money';
import MonthNav from './month-nav';
import Donut, {type DonutSlice} from './donut';

type Slice = DonutSlice;

export default function MonthlyOverview({events, categories, persistenceKey}: {events: ViewEvent[]; categories: {name: string; kind: string; color: string}[]; persistenceKey: string}) {
  const [month, setMonth] = useViewState(persistenceKey + ':chart-month', today().slice(0, 7), validMonth);
  const [mode, setMode] = useViewState<'categories' | 'balance'>(persistenceKey + ':chart-mode', 'categories', (v): v is 'categories' | 'balance' => v === 'categories' || v === 'balance');
  const summary = useMemo(() => monthlySummary(events, month, categories), [events, month, categories]);
  const both = summary.income + summary.expense;
  const slices: Slice[] = mode === 'categories' ? summary.categories : [
    {name: 'Entradas', value: summary.income, color: '#2f9e6e', percent: both ? summary.income / both * 100 : 0},
    {name: 'Saídas', value: summary.expense, color: '#e0664f', percent: both ? summary.expense / both * 100 : 0},
  ].filter(s => s.value > 0);

  return <section id="monthly-overview" className="card monthly-overview" aria-label="Análise mensal">
    <div className="section-heading"><h2>Seu mês em números</h2></div>
    <MonthNav month={month} onChange={m => {setMonth(m)}} context="do gráfico"/>
    <div className="segmented-control" role="group" aria-label="Tipo de análise">
      <button aria-pressed={mode === 'categories'} onClick={() => {setMode('categories')}}>Categorias</button>
      <button aria-pressed={mode === 'balance'} onClick={() => {setMode('balance')}}>Entradas e saídas</button>
    </div>
    {slices.length ? <div className="pie-block">
      <Donut key={month + mode} slices={slices} label={(mode === 'categories' ? 'Despesas por categoria' : 'Entradas e saídas') + ' de ' + monthLabel(month)} suffix={mode === 'categories' ? ' das despesas' : ''}
        center={{label: mode === 'categories' ? 'Despesas do mês' : summary.balance < 0 ? 'Déficit do mês' : 'Saldo do mês', value: brl(mode === 'categories' ? summary.expense : summary.balance), sub: mode === 'categories' ? summary.categories.length + (summary.categories.length > 1 ? ' categorias' : ' categoria') : 'Entradas − saídas', negative: mode === 'balance' && summary.balance < 0}}/>
      {mode === 'balance' && <p className={'balance-result ' + (summary.balance < 0 ? 'has-deficit' : 'has-surplus')} role="status">{summary.balance < 0 ? <TriangleAlert size={18}/> : <TrendingUp size={18}/>}<span>{summary.balance < 0 ? 'Déficit previsto de ' + brl(-summary.balance) : summary.balance > 0 ? 'Sem déficit · sobra de ' + brl(summary.balance) : 'Sem déficit · mês equilibrado'}</span></p>}
    </div> : <div className="chart-empty"><ChartPie size={28}/><p>{mode === 'categories' ? 'Nenhuma despesa neste mês.' : 'Nenhuma entrada ou saída neste mês.'}</p><span>Use as setas para ver outros meses.</span></div>}
  </section>;
}
