"use client";
// "Seu mês em números": só o gráfico de pizza (rosca), maior, com o rótulo em cada fatia.
// Passar o mouse (ou tocar) numa fatia amplia a fatia e mostra o valor e o percentual no centro.
import {useMemo, useState} from 'react';
import {ChartPie, TrendingUp, TriangleAlert} from 'lucide-react';
import {monthlySummary, monthLabel, type ViewEvent} from '@/lib/finance-view';
import {useViewState, validMonth} from '@/lib/use-view-state';
import {today, brl} from '@/lib/money';
import MonthNav from './month-nav';

type Slice = {name: string; value: number; color: string; percent: number};
const C = 220, RI = 96, RO = 152, GROW = 12, LABEL = 168;
const pt = (r: number, a: number) => [C + r * Math.sin(a), C - r * Math.cos(a)] as const;
function arc(a0: number, a1: number, ri: number, ro: number) {
  const large = a1 - a0 > Math.PI ? 1 : 0;
  if (a1 - a0 >= Math.PI * 2 - 1e-6) a1 = a0 + Math.PI * 2 - 1e-4;
  const [x0, y0] = pt(ro, a0), [x1, y1] = pt(ro, a1), [x2, y2] = pt(ri, a1), [x3, y3] = pt(ri, a0);
  return `M${x0} ${y0}A${ro} ${ro} 0 ${large} 1 ${x1} ${y1}L${x2} ${y2}A${ri} ${ri} 0 ${large} 0 ${x3} ${y3}Z`;
}
const pct = (p: number) => p.toLocaleString('pt-BR', {maximumFractionDigits: p < 10 ? 1 : 0}) + '%';

export default function MonthlyOverview({events, categories, persistenceKey}: {events: ViewEvent[]; categories: {name: string; kind: string; color: string}[]; persistenceKey: string}) {
  const [month, setMonth] = useViewState(persistenceKey + ':chart-month', today().slice(0, 7), validMonth);
  const [mode, setMode] = useViewState<'categories' | 'balance'>(persistenceKey + ':chart-mode', 'categories', (v): v is 'categories' | 'balance' => v === 'categories' || v === 'balance');
  const [active, setActive] = useState<number | null>(null);
  const summary = useMemo(() => monthlySummary(events, month, categories), [events, month, categories]);
  const both = summary.income + summary.expense;
  const slices: Slice[] = mode === 'categories' ? summary.categories : [
    {name: 'Entradas', value: summary.income, color: '#2f9e6e', percent: both ? summary.income / both * 100 : 0},
    {name: 'Saídas', value: summary.expense, color: '#e0664f', percent: both ? summary.expense / both * 100 : 0},
  ].filter(s => s.value > 0);
  const total = slices.reduce((s, x) => s + x.value, 0);
  let angle = 0;
  const geo = slices.map(s => {const a0 = angle; angle += (s.value / (total || 1)) * Math.PI * 2; return {...s, a0, a1: angle, mid: (a0 + angle) / 2}});
  const current = active !== null ? geo[active] : null;
  const label = (name: string) => name.length > 14 ? name.slice(0, 13) + '…' : name;

  return <section id="monthly-overview" className="card monthly-overview" aria-label="Análise mensal">
    <div className="section-heading"><h2>Seu mês em números</h2></div>
    <MonthNav month={month} onChange={m => {setMonth(m); setActive(null)}} context="do gráfico"/>
    <div className="segmented-control" role="group" aria-label="Tipo de análise">
      <button aria-pressed={mode === 'categories'} onClick={() => {setMode('categories'); setActive(null)}}>Categorias</button>
      <button aria-pressed={mode === 'balance'} onClick={() => {setMode('balance'); setActive(null)}}>Entradas e saídas</button>
    </div>
    {slices.length ? <div className="pie-wrap">
      <svg className="pie" viewBox="-60 30 560 380" role="img" aria-label={(mode === 'categories' ? 'Despesas por categoria' : 'Entradas e saídas') + ' de ' + monthLabel(month)} onMouseLeave={() => setActive(null)}>
        {geo.map((s, i) => {
          const on = active === i, ro = on ? RO + GROW : RO;
          return <path key={s.name} d={arc(s.a0, s.a1, RI, ro)} fill={s.color} stroke="var(--panel)" strokeWidth={2}
            className={'pie-slice' + (active !== null && !on ? ' dim' : '')} tabIndex={0} role="button"
            aria-label={`${s.name}: ${brl(s.value)}, ${pct(s.percent)}`}
            onMouseEnter={() => setActive(i)} onFocus={() => setActive(i)} onBlur={() => setActive(null)} onClick={() => setActive(on ? null : i)}>
            <title>{`${s.name}: ${brl(s.value)} · ${pct(s.percent)}`}</title>
          </path>;
        })}
        {geo.map((s, i) => {
          if (s.a1 - s.a0 < 0.22 && active !== i) return null; // fatias muito finas: rótulo só ao destacar
          const [x, y] = pt(LABEL + (active === i ? GROW : 0), s.mid), right = Math.sin(s.mid) >= 0;
          const [ix, iy] = pt((RI + RO) / 2, s.mid);
          return <g key={'l' + s.name} className={'pie-label' + (active !== null && active !== i ? ' dim' : '')} aria-hidden="true">
            {s.a1 - s.a0 >= 0.3 && <text x={ix} y={iy} className="pie-pct" textAnchor="middle" dominantBaseline="central">{pct(s.percent)}</text>}
            <text x={x} y={y} className="pie-name" textAnchor={right ? 'start' : 'end'} dominantBaseline="central">{label(s.name)}</text>
          </g>;
        })}
        <g className="pie-center donut-center" aria-hidden="true">
          <text x={C} y={C - 28} textAnchor="middle" className="pie-c-label">{current ? label(current.name) : mode === 'categories' ? 'Despesas do mês' : summary.balance < 0 ? 'Déficit do mês' : 'Saldo do mês'}</text>
          <text x={C} y={C + 8} textAnchor="middle" className={'pie-c-value' + (!current && mode === 'balance' && summary.balance < 0 ? ' neg' : '')}>{brl(current ? current.value : mode === 'categories' ? summary.expense : summary.balance)}</text>
          <text x={C} y={C + 38} textAnchor="middle" className="pie-c-sub">{current ? pct(current.percent) + (mode === 'categories' ? ' das despesas' : '') : mode === 'categories' ? summary.categories.length + ' categorias' : 'Entradas − saídas'}</text>
        </g>
      </svg>
      {mode === 'balance' && <p className={'balance-result ' + (summary.balance < 0 ? 'has-deficit' : 'has-surplus')} role="status">{summary.balance < 0 ? <TriangleAlert size={18}/> : <TrendingUp size={18}/>}<span>{summary.balance < 0 ? 'Déficit previsto de ' + brl(-summary.balance) : summary.balance > 0 ? 'Sem déficit · sobra de ' + brl(summary.balance) : 'Sem déficit · mês equilibrado'}</span></p>}
      <p className="chart-note">Passe o mouse ou toque numa fatia para ver o valor.</p>
    </div> : <div className="chart-empty"><ChartPie size={28}/><p>{mode === 'categories' ? 'Nenhuma despesa neste mês.' : 'Nenhuma entrada ou saída neste mês.'}</p><span>Use as setas para ver outros meses.</span></div>}
  </section>;
}
