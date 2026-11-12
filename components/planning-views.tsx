"use client";
// Mais → Planejamento: fluxo de caixa mensal, relatórios e simulador.
import {useMemo, useState} from 'react';
import {ResponsiveContainer, ComposedChart, Bar, Line, XAxis, YAxis, Tooltip, CartesianGrid, Legend, ReferenceLine, AreaChart, Area, ReferenceDot, BarChart} from 'recharts';
import {X} from 'lucide-react';
import {brl, project, today} from '@/lib/money';
import {alphabetic, isConsumptionEvent, monthLabel, type ViewEvent} from '@/lib/finance-view';
import {averageFlows, categoryAverages} from '@/lib/forecast';

type Account = {id: string; name: string; owner_id: string; balance: number; account_type?: string; color?: string};
type Member = {user_id: string; display_name: string};
export type Flow = {id: string; account_id: string; amount: number; due_date: string; status: string};
const COLORS = {in: '#2f9e6e', out: '#e0664f', avg: '#f2b29c', line: '#5b60d6', area: '#5b60d6'};
export type AverageSetting = {events: ViewEvent[]; months: number; setMonths: (n: number) => void; account: string};
const isAvg = (f: {id: string}) => f.id.startsWith('avg-');

/** Liga/desliga a previsão pela média de gastos por categoria e mostra as médias usadas. */
function AverageControl({setting}: {setting: AverageSetting}) {
  const list = useMemo(() => setting.months ? categoryAverages(setting.events, setting.months) : [], [setting.events, setting.months]);
  const total = list.reduce((s, a) => s + cents(a.average), 0) / 100;
  return <div className="avg-control">
    <div className="avg-head">
      <div><b>Média de gastos por categoria</b><small>Completa os meses futuros com o que vocês costumam gastar.</small></div>
      <div className="segmented-control mini" role="group" aria-label="Média de gastos">{([[0, 'Não usar'], [3, '3 meses'], [6, '6 meses'], [12, '12 meses']] as const).map(([n, l]) => <button key={n} type="button" aria-pressed={setting.months === n} onClick={() => setting.setMonths(n)}>{l}</button>)}</div>
    </div>
    {setting.months > 0 && (list.length ? <details className="avg-list"><summary>Média de {brl(total)}/mês em {list.length} categoria(s) · base: {list[0].months} mês(es) com gastos</summary>
      <ul className="row-list">{list.map(a => <li key={a.category}><span className="rl-main"><b>{a.category}</b></span><strong>{brl(a.average)}/mês</strong></li>)}</ul>
      <p className="muted">Em cada mês entra só o que falta para chegar à média, descontando o que já está lançado (pago, previsto ou no cartão) naquela categoria. Nada é gravado.</p>
    </details> : <p className="muted">Sem despesas nos últimos {setting.months} meses para calcular a média.</p>)}
  </div>;
}
const cents = (n: number) => Math.round(n * 100);
const short = (v: number) => Number(v).toLocaleString('pt-BR', {notation: 'compact', maximumFractionDigits: 1});
const mLabel = (ym: string) => {const s = monthLabel(ym); return s.slice(0, 3) + '/' + ym.slice(2, 4)};
const dBR = (iso: string) => iso.split('-').reverse().join('/');
const tooltipStyle = {background: 'var(--panel)', border: '1px solid var(--line)', borderRadius: 12, color: 'var(--ink)', fontSize: 13};
function addMonths(ym: string, n: number) {const d = new Date(ym + '-01T12:00:00Z'); d.setUTCMonth(d.getUTCMonth() + n); return d.toISOString().slice(0, 7)}

/** Entradas e saídas previstas por mês e saldo disponível acumulado no fim de cada mês. */
export function monthlyCashFlow(accounts: Account[], flows: Flow[], months = 12, current = today()) {
  const ids = new Set(accounts.map(a => a.id));
  const pending = flows.filter(f => f.status === 'pending' && ids.has(f.account_id));
  // Transferência entre duas contas disponíveis não é entrada nem saída.
  const internal = new Set(pending.filter(f => f.id.endsWith('-to') && pending.some(o => o.id === f.id.slice(0, -3))).flatMap(f => [f.id, f.id.slice(0, -3)]));
  const start = current.slice(0, 7), end = addMonths(start, months);
  const days = Math.round((Date.parse(end + '-01T12:00:00Z') - Date.parse(current + 'T12:00:00Z')) / 86400000) - 1;
  const projection = project(accounts, pending, Math.min(365, Math.max(0, days)), current);
  const balanceAt = (iso: string) => (projection.filter(p => p.date <= iso).at(-1) ?? projection.at(-1))?.total ?? 0;
  return Array.from({length: months}, (_, i) => {
    const ym = addMonths(start, i), last = addMonths(ym, 1) + '-01';
    const inMonth = pending.filter(f => !internal.has(f.id) && (f.due_date < current ? start : f.due_date.slice(0, 7)) === ym);
    const income = inMonth.filter(f => f.amount > 0).reduce((s, f) => s + cents(f.amount), 0) / 100;
    const expense = -inMonth.filter(f => f.amount < 0 && !isAvg(f)).reduce((s, f) => s + cents(f.amount), 0) / 100;
    const average = -inMonth.filter(f => f.amount < 0 && isAvg(f)).reduce((s, f) => s + cents(f.amount), 0) / 100;
    const endDate = new Date(Date.parse(last + 'T12:00:00Z') - 86400000).toISOString().slice(0, 10);
    return {month: ym, label: mLabel(ym), income, expense, average, balance: balanceAt(endDate)};
  });
}

export function CashFlowView({accounts, flows, average}: {accounts: Account[]; flows: Flow[]; average: AverageSetting}) {
  const [months, setMonths] = useState(12);
  const avg = useMemo(() => average.months ? averageFlows(average.events, average.account, months, average.months) : [], [average.events, average.account, average.months, months]);
  const rows = useMemo(() => monthlyCashFlow(accounts, [...flows, ...avg], months), [accounts, flows, avg, months]);
  const now = accounts.reduce((s, a) => s + cents(Number(a.balance)), 0) / 100;
  const low = rows.reduce((m, r) => r.balance < m.balance ? r : m, rows[0]);
  const firstNeg = rows.find(r => r.balance < 0);
  return <div className="card plan-card">
    <div className="section-heading"><h2>Fluxo de caixa</h2>
      <div className="segmented-control mini" role="group" aria-label="Período do gráfico">{[6, 12].map(n => <button key={n} aria-pressed={months === n} onClick={() => setMonths(n)}>{n} meses</button>)}</div></div>
    <div className="stat-row">
      <div className="stat"><span>Disponível hoje</span><strong>{brl(now)}</strong></div>
      <div className="stat"><span>Saldo em {rows.at(-1)?.label}</span><strong className={(rows.at(-1)?.balance ?? 0) < 0 ? 'negative' : ''}>{brl(rows.at(-1)?.balance ?? 0)}</strong></div>
      <div className={'stat ' + (firstNeg ? 'alert' : 'good')}><span>{firstNeg ? 'Fica negativo em' : 'Menor saldo previsto'}</span><strong>{firstNeg ? firstNeg.label : low ? brl(low.balance) : '—'}</strong></div>
    </div>
    <AverageControl setting={average}/>
    <div className="chart-box" role="img" aria-label="Entradas, saídas e saldo acumulado por mês">
      <ResponsiveContainer width="100%" height={320}>
        <ComposedChart data={rows} margin={{top: 8, right: 8, left: 0, bottom: 0}}>
          <CartesianGrid vertical={false} stroke="var(--line)"/>
          <XAxis dataKey="label" tick={{fill: 'var(--muted)', fontSize: 12}} tickLine={false} axisLine={false}/>
          <YAxis width={56} tickFormatter={short} tick={{fill: 'var(--muted)', fontSize: 12}} tickLine={false} axisLine={false}/>
          <Tooltip formatter={(v, n) => [brl(Number(v)), String(n)]} contentStyle={tooltipStyle} cursor={{fill: 'var(--accent-soft)'}}/>
          <Legend wrapperStyle={{fontSize: 13}}/>
          <ReferenceLine y={0} stroke="var(--muted)"/>
          <Bar name="Entradas" dataKey="income" fill={COLORS.in} radius={[4, 4, 0, 0]} maxBarSize={22} isAnimationActive={false}/>
          <Bar name="Saídas" dataKey="expense" stackId="out" fill={COLORS.out} radius={avg.length ? [0, 0, 0, 0] : [4, 4, 0, 0]} maxBarSize={22} isAnimationActive={false}/>
          {avg.length > 0 && <Bar name="Média de gastos" dataKey="average" stackId="out" fill={COLORS.avg} radius={[4, 4, 0, 0]} maxBarSize={22} isAnimationActive={false}/>}
          <Line name="Saldo acumulado" dataKey="balance" stroke={COLORS.line} strokeWidth={3} dot={{r: 3}} isAnimationActive={false}/>
        </ComposedChart>
      </ResponsiveContainer>
    </div>
    <p className="muted">Previsto com o saldo das contas disponíveis (sem investimentos), os lançamentos pendentes e as transferências agendadas{avg.length ? ', mais a média de gastos por categoria' : ''}. Atrasados contam no mês atual.</p>
  </div>;
}

type ReportProps = {events: ViewEvent[]; accounts: Account[]; members: Member[]; properties: {id: string; name: string}[]; cards: {id: string; name: string}[]};
export function ReportsView({events, accounts, members, properties, cards}: ReportProps) {
  const t = today(), year = t.slice(0, 4);
  const [from, setFrom] = useState(t.slice(0, 7) + '-01'), [to, setTo] = useState(year + '-12-31');
  const [person, setPerson] = useState(''), [account, setAccount] = useState(''), [category, setCategory] = useState(''), [property, setProperty] = useState(''), [card, setCard] = useState(''), [nature, setNature] = useState('all');
  const presets: [string, string, string][] = [['Este mês', t.slice(0, 7) + '-01', new Date(Date.UTC(+year, +t.slice(5, 7), 0)).toISOString().slice(0, 10)], ['Próximos 3 meses', t.slice(0, 7) + '-01', new Date(Date.UTC(+year, +t.slice(5, 7) + 2, 0)).toISOString().slice(0, 10)], ['Este ano', year + '-01-01', year + '-12-31']];
  const filtered = events.filter(e => isConsumptionEvent(e) && e.status !== 'cancelled' && e.due_date >= from && e.due_date <= to
    && (nature === 'all' || (nature === 'realized' ? (e.source === 'cc_charge' || (!e.source && e.status === 'settled')) : e.status === 'pending'))
    && (!card || e.card_id === card) && (!person || e.owner_id === person || e.card_owner_id === person) && (!account || e.account_id === account)
    && (!category || e.category === category) && (!property || e.property_id === property));
  const sum = (list: ViewEvent[]) => list.reduce((s, e) => s + cents(Number(e.amount)), 0) / 100;
  const income = sum(filtered.filter(e => e.kind === 'income')), expense = sum(filtered.filter(e => e.kind === 'expense'));
  const groups = Object.entries(filtered.filter(e => e.kind === 'expense').reduce<Record<string, number>>((o, e) => {const k = e.category ?? 'Outros'; o[k] = (o[k] ?? 0) + cents(Number(e.amount)); return o}, {})).map(([name, c]) => ({name, value: c / 100})).sort((a, b) => b.value - a.value);
  const max = Math.max(1, ...groups.map(g => g.value));
  const monthsMap = filtered.reduce<Record<string, {income: number; expense: number}>>((o, e) => {const m = e.due_date.slice(0, 7); o[m] ??= {income: 0, expense: 0}; o[m][e.kind] += Number(e.amount); return o}, {});
  const monthly = Object.entries(monthsMap).sort(([a], [b]) => a.localeCompare(b)).map(([m, v]) => ({label: mLabel(m), income: Math.round(v.income * 100) / 100, expense: Math.round(v.expense * 100) / 100}));
  const active = [person, account, category, property, card].filter(Boolean).length + (nature !== 'all' ? 1 : 0);
  return <div className="report space-y-4">
    <div className="card plan-card">
      <div className="section-heading"><h2>Relatório por período</h2></div>
      <div className="report-period">
        <label>De<input type="date" value={from} onChange={e => setFrom(e.target.value)}/></label>
        <label>Até<input type="date" value={to} onChange={e => setTo(e.target.value)}/></label>
        <div className="chip-row">{presets.map(([l, f, e]) => <button key={l} type="button" className={'chip-btn' + (from === f && to === e ? ' on' : '')} onClick={() => {setFrom(f); setTo(e)}}>{l}</button>)}</div>
      </div>
      <details className="report-filters"><summary>Mais filtros{active ? ` · ${active} ativo(s)` : ''}</summary>
        <div className="form-grid three">
          <label>Pessoa<select aria-label="Pessoa" value={person} onChange={e => setPerson(e.target.value)}><option value="">Todas</option>{members.map(m => <option key={m.user_id} value={m.user_id}>{m.display_name}</option>)}</select></label>
          <label>Conta<select value={account} onChange={e => setAccount(e.target.value)}><option value="">Todas</option>{accounts.map(a => <option key={a.id} value={a.id}>{a.name}</option>)}</select></label>
          <label>Categoria<select value={category} onChange={e => setCategory(e.target.value)}><option value="">Todas</option>{Array.from(new Set(events.map(e => e.category ?? 'Outros'))).sort(alphabetic).map(c => <option key={c}>{c}</option>)}</select></label>
          <label>Natureza do relatório<select value={nature} onChange={e => setNature(e.target.value)}><option value="all">Realizadas e previstas</option><option value="realized">Só realizadas</option><option value="forecast">Só previstas</option></select></label>
          <label>Cartão do relatório<select aria-label="Cartão do relatório" value={card} onChange={e => setCard(e.target.value)}><option value="">Todos</option>{cards.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}</select></label>
          <label>Imóvel<select value={property} onChange={e => setProperty(e.target.value)}><option value="">Todos</option>{properties.map(p => <option key={p.id} value={p.id}>{p.name}</option>)}</select></label>
        </div>
      </details>
      <div className="stat-row">
        <div className="stat report-tile income"><span>Receitas</span><strong className="positive">{brl(income)}</strong></div>
        <div className="stat report-tile expense"><span>Despesas</span><strong className="negative">{brl(expense)}</strong></div>
        <div className="stat report-tile"><span>Resultado</span><strong className={income - expense < 0 ? 'negative' : 'positive'}>{brl(income - expense)}</strong></div>
      </div>
    </div>
    <div className="report-grid">
      <div className="card plan-card"><h3>Despesas por categoria</h3>
        {groups.length ? <ul className="bar-list">{groups.map(g => <li key={g.name}><div className="bar-top"><span>{g.name}</span><b>{brl(g.value)}</b></div><div className="bar-track"><i style={{width: g.value / max * 100 + '%'}}/></div><small>{(expense ? g.value / expense * 100 : 0).toLocaleString('pt-BR', {maximumFractionDigits: 1})}% das despesas</small></li>)}</ul> : <p className="muted">Nenhuma despesa no período.</p>}
      </div>
      <div className="card plan-card"><h3>Mês a mês</h3>
        {monthly.length ? <div className="chart-box"><ResponsiveContainer width="100%" height={260}><BarChart data={monthly} margin={{top: 8, right: 4, left: 0, bottom: 0}}><CartesianGrid vertical={false} stroke="var(--line)"/><XAxis dataKey="label" tick={{fill: 'var(--muted)', fontSize: 12}} tickLine={false} axisLine={false}/><YAxis width={52} tickFormatter={short} tick={{fill: 'var(--muted)', fontSize: 12}} tickLine={false} axisLine={false}/><Tooltip formatter={(v, n) => [brl(Number(v)), String(n)]} contentStyle={tooltipStyle} cursor={{fill: 'var(--accent-soft)'}}/><Legend wrapperStyle={{fontSize: 13}}/><Bar name="Receitas" dataKey="income" fill={COLORS.in} radius={[4, 4, 0, 0]} maxBarSize={24} isAnimationActive={false}/><Bar name="Despesas" dataKey="expense" fill={COLORS.out} radius={[4, 4, 0, 0]} maxBarSize={24} isAnimationActive={false}/></BarChart></ResponsiveContainer></div> : <p className="muted">Sem lançamentos no período.</p>}
      </div>
    </div>
    <div className="card plan-card"><div className="section-heading"><h3>Lançamentos</h3><span className="muted">{filtered.length} itens</span></div>
      {filtered.length ? <ul className="row-list">{filtered.slice().sort((a, b) => a.due_date.localeCompare(b.due_date)).map(e => <li key={e.id}><span className="rl-date">{dBR(e.due_date).slice(0, 5)}</span><span className="rl-main"><b>{e.title}</b><small>{e.category}{e.source === 'cc_charge' ? ' · cartão' : e.source === 'cc_obligation' ? ' · a lançar no cartão' : e.status === 'settled' ? ' · pago' : ' · previsto'}</small></span><strong className={e.kind === 'income' ? 'positive' : ''}>{e.kind === 'income' ? '+ ' : ''}{brl(Number(e.amount))}</strong></li>)}</ul> : <p className="muted">Nada no período escolhido.</p>}
    </div>
  </div>;
}

type Scenario = Flow & {title: string};
export function SimulatorView({accounts, flows, average, until, setUntil, maxDate}: {accounts: Account[]; flows: Flow[]; average: AverageSetting; until: string; setUntil: (d: string) => void; maxDate: string}) {
  const [scenarios, setScenarios] = useState<Scenario[]>([]);
  const [kind, setKind] = useState<'expense' | 'income' | 'transfer'>('expense'), [error, setError] = useState('');
  const t = today();
  const days = Math.max(0, Math.min(365, Math.round((Date.parse(until + 'T12:00:00Z') - Date.parse(t + 'T12:00:00Z')) / 86400000)));
  const avgMonthsAhead = Math.max(1, (+until.slice(0, 4) - +t.slice(0, 4)) * 12 + (+until.slice(5, 7) - +t.slice(5, 7)) + 1);
  const avg = useMemo(() => average.months ? averageFlows(average.events, average.account, avgMonthsAhead, average.months).filter(f => f.due_date <= until) : [], [average.events, average.account, average.months, avgMonthsAhead, until]);
  const all = [...flows, ...avg, ...scenarios];
  const sim = useMemo(() => project(accounts, all, days), [accounts, flows, avg, scenarios, days]);
  const avgTotal = -avg.reduce((s, f) => s + cents(f.amount), 0) / 100;
  const inRange = all.filter(f => f.status === 'pending' && f.due_date <= until && accounts.some(a => a.id === f.account_id));
  const internal = new Set(inRange.filter(f => f.id.endsWith('-to') && inRange.some(o => o.id === f.id.slice(0, -3))).flatMap(f => [f.id, f.id.slice(0, -3)]));
  const income = inRange.filter(f => f.amount > 0 && !internal.has(f.id)).reduce((s, f) => s + cents(f.amount), 0) / 100;
  const expense = -inRange.filter(f => f.amount < 0 && !internal.has(f.id)).reduce((s, f) => s + cents(f.amount), 0) / 100;
  const start = accounts.reduce((s, a) => s + cents(Number(a.balance)), 0) / 100;
  const end = sim.at(-1)?.total ?? start;
  const min = sim.reduce((m, p) => p.total < m.total ? p : m, sim[0] ?? {date: t, total: start, byAccount: {}});
  const deficit = sim.find(p => Object.values(p.byAccount).some(v => v < 0));
  const chart = sim.map(p => ({date: p.date, label: dBR(p.date).slice(0, 5), total: p.total}));
  function add(fd: FormData) {
    setError('');
    const amount = Number(fd.get('amount')), date = String(fd.get('date')), from = String(fd.get('account')), to = String(fd.get('to') ?? ''), id = crypto.randomUUID();
    const title = String(fd.get('title') || (kind === 'income' ? 'Receita simulada' : kind === 'expense' ? 'Despesa simulada' : 'Transferência simulada'));
    if (!(amount > 0) || !date || !from) return setError('Informe conta, valor e data.');
    if (kind === 'transfer' && (!to || to === from)) return setError('Escolha contas diferentes para a transferência.');
    const rows: Scenario[] = [{id, title, account_id: from, amount: kind === 'income' ? amount : -amount, due_date: date, status: 'pending'}];
    if (kind === 'transfer') rows.push({id: id + '-to', title, account_id: to, amount, due_date: date, status: 'pending'});
    setScenarios(s => [...s, ...rows]);
  }
  const accName = (id: string) => accounts.find(a => a.id === id)?.name ?? 'Conta';
  return <div className="sim space-y-4">
    <div className="card plan-card">
      <div className="section-heading"><h2>Simulador por data</h2>
        <label className="inline-date">Simular até a data<input type="date" value={until} min={t} max={maxDate} required onChange={e => {if (e.target.value >= t && e.target.value <= maxDate) setUntil(e.target.value)}}/></label></div>
      <div className="stat-row four">
        <div className="stat"><span>Saldo hoje</span><strong>{brl(start)}</strong></div>
        <div className="stat"><span>Entradas</span><strong className="positive">+ {brl(income)}</strong></div>
        <div className="stat"><span>Saídas{avg.length ? ' (com média)' : ''}</span><strong className="negative">− {brl(expense)}</strong></div>
        <div className="stat"><span>Saldo em {dBR(until).slice(0, 5)}</span><strong className={end < 0 ? 'negative' : ''}>{brl(end)}</strong></div>
      </div>
      <AverageControl setting={average}/>
      {avg.length > 0 && <p className="muted">Inclui {brl(avgTotal)} estimados pela média de gastos até {dBR(until)}.</p>}
      <div className={'sim-alert ' + (deficit ? 'bad' : 'ok')}>{deficit ? <>Alguma conta fica negativa em <b>{dBR(deficit.date)}</b>. Menor saldo total: <b>{brl(min.total)}</b> em {dBR(min.date)}.</> : <>Nenhuma conta fica negativa até {dBR(until)}. Menor saldo total: <b>{brl(min.total)}</b> em {dBR(min.date)}.</>}</div>
      <div className="chart-box" role="img" aria-label="Saldo total simulado dia a dia">
        <ResponsiveContainer width="100%" height={280}>
          <AreaChart data={chart} margin={{top: 8, right: 8, left: 0, bottom: 0}}>
            <defs><linearGradient id="simFill" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stopColor={COLORS.area} stopOpacity={0.35}/><stop offset="100%" stopColor={COLORS.area} stopOpacity={0.02}/></linearGradient></defs>
            <CartesianGrid vertical={false} stroke="var(--line)"/>
            <XAxis dataKey="label" minTickGap={36} tick={{fill: 'var(--muted)', fontSize: 12}} tickLine={false} axisLine={false}/>
            <YAxis width={56} tickFormatter={short} tick={{fill: 'var(--muted)', fontSize: 12}} tickLine={false} axisLine={false}/>
            <Tooltip formatter={v => [brl(Number(v)), 'Saldo total']} labelFormatter={l => String(l)} contentStyle={tooltipStyle}/>
            <ReferenceLine y={0} stroke={COLORS.out} strokeDasharray="4 4"/>
            <Area dataKey="total" stroke={COLORS.area} strokeWidth={2.5} fill="url(#simFill)" isAnimationActive={false}/>
            <ReferenceDot x={dBR(min.date).slice(0, 5)} y={min.total} r={5} fill={COLORS.out} stroke="var(--panel)"/>
          </AreaChart>
        </ResponsiveContainer>
      </div>
    </div>
    <div className="report-grid">
      <div className="card plan-card"><h3>Adicionar cenário</h3><p className="muted">Testes ficam só nesta tela e não são gravados.</p>
        <div className="segmented-control mini left" role="group" aria-label="Tipo de cenário">{([['expense', 'Despesa'], ['income', 'Receita'], ['transfer', 'Transferência']] as const).map(([k, l]) => <button key={k} type="button" aria-pressed={kind === k} onClick={() => setKind(k)}>{l}</button>)}</div>
        <form className="form-grid" onSubmit={e => {e.preventDefault(); add(new FormData(e.currentTarget))}}>
          <label className="form-title">Descrição (opcional)<input name="title" maxLength={80} placeholder="Ex.: viagem de férias"/></label>
          <label>{kind === 'transfer' ? 'Conta de origem' : 'Conta'}<select name="account" required>{accounts.map(a => <option key={a.id} value={a.id}>{a.name}</option>)}</select></label>
          {kind === 'transfer' && <label>Conta de destino<select name="to" required>{accounts.map(a => <option key={a.id} value={a.id}>{a.name}</option>)}</select></label>}
          <label>Valor<input required name="amount" type="number" step=".01" min=".01"/></label>
          <label>Data<input required name="date" type="date" min={t} max={until} defaultValue={t}/></label>
          <button className="form-title" disabled={!accounts.length}>Simular</button>
          {error && <p role="alert" className="payment-error form-title">{error}</p>}
        </form>
      </div>
      <div className="card plan-card"><div className="section-heading"><h3>Cenários</h3>{scenarios.length > 0 && <button type="button" className="btn-small" onClick={() => setScenarios([])}>Limpar cenário</button>}</div>
        {scenarios.filter(s => !s.id.endsWith('-to')).length ? <ul className="row-list">{scenarios.filter(s => !s.id.endsWith('-to')).map(s => <li key={s.id}><span className="rl-date">{dBR(s.due_date).slice(0, 5)}</span><span className="rl-main"><b>{s.title}</b><small>{accName(s.account_id)}{scenarios.some(o => o.id === s.id + '-to') ? ' → ' + accName(scenarios.find(o => o.id === s.id + '-to')!.account_id) : ''}</small></span><strong className={s.amount > 0 ? 'positive' : 'negative'}>{brl(s.amount)}</strong><button type="button" className="icon-btn" aria-label={'Remover ' + s.title} onClick={() => setScenarios(list => list.filter(o => o.id !== s.id && o.id !== s.id + '-to'))}><X size={16}/></button></li>)}</ul> : <p className="muted">Nenhum cenário. Adicione uma despesa, receita ou transferência para ver o efeito.</p>}
        <h3 className="mt">Por conta</h3>
        <ul className="row-list">{accounts.map(a => {const finalV = sim.at(-1)?.byAccount[a.id] ?? a.balance, minV = Math.min(...sim.map(p => p.byAccount[a.id] ?? a.balance)); return <li key={a.id}><span className="rl-main"><b>{a.name}</b><small>menor saldo {brl(minV)}</small></span><strong className={finalV < 0 ? 'negative' : ''}>{brl(finalV)}</strong></li>})}</ul>
      </div>
    </div>
  </div>;
}
