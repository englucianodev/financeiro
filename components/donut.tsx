"use client";
// Gráfico de rosca do Duo: rótulo em cada fatia; passar o mouse, focar ou tocar amplia a fatia
// e mostra nome, valor e percentual no centro. Usado no mês, nos cartões, investimentos e imóveis.
import {useState} from 'react';
import {brl} from '@/lib/money';

export type DonutSlice = {name: string; value: number; color: string; percent: number};
const C = 220, RI = 96, RO = 152, GROW = 12, LABEL = 168;
const pt = (r: number, a: number) => [C + r * Math.sin(a), C - r * Math.cos(a)] as const;
function arc(a0: number, a1: number, ri: number, ro: number) {
  const large = a1 - a0 > Math.PI ? 1 : 0;
  if (a1 - a0 >= Math.PI * 2 - 1e-6) a1 = a0 + Math.PI * 2 - 1e-4;
  const [x0, y0] = pt(ro, a0), [x1, y1] = pt(ro, a1), [x2, y2] = pt(ri, a1), [x3, y3] = pt(ri, a0);
  return `M${x0} ${y0}A${ro} ${ro} 0 ${large} 1 ${x1} ${y1}L${x2} ${y2}A${ri} ${ri} 0 ${large} 0 ${x3} ${y3}Z`;
}
const sizeClass = (text: string) => text.length > 15 ? ' xlong' : text.length > 12 ? ' long' : '';
export const pct = (p: number) => p.toLocaleString('pt-BR', {maximumFractionDigits: p < 10 ? 1 : 0}) + '%';
const PALETTE = ['#5b60d6', '#ef8a5a', '#2f9e6e', '#d4a72c', '#c0508a', '#3a9fc0', '#8a6fd1', '#7a8b3a', '#e0664f', '#4f7cac'];
/** Monta fatias a partir de valores positivos, com cor da lista ou da paleta do Duo. */
const PALETTE_DARK = ['#a3a7ff', '#ef8a5a', '#5fd0a0', '#f2c94c', '#e98bc0', '#7fd3ef', '#c3b1ff', '#c6d47a'];
export function toSlices(items: {name: string; value: number; color?: string}[], tone?: 'dark'): DonutSlice[] {
  const list = items.filter(i => i.value > 0).sort((a, b) => b.value - a.value);
  const total = list.reduce((s, i) => s + i.value, 0);
  return list.map((i, n) => ({name: i.name, value: i.value, color: tone !== 'dark' && i.color && /^#[0-9a-f]{6}$/i.test(i.color) ? i.color : (tone === 'dark' ? PALETTE_DARK : PALETTE)[n % (tone === 'dark' ? PALETTE_DARK : PALETTE).length], percent: total ? i.value / total * 100 : 0}));
}

export default function Donut({slices, label, center, suffix = '', tone, note = true}: {slices: DonutSlice[]; label: string; center: {label: string; value: string; sub?: string; negative?: boolean}; suffix?: string; tone?: 'dark'; note?: boolean}) {
  const [active, setActive] = useState<number | null>(null);
  const total = slices.reduce((s, x) => s + x.value, 0);
  let angle = 0;
  const geo = slices.map(s => {const a0 = angle; angle += (s.value / (total || 1)) * Math.PI * 2; return {...s, a0, a1: angle, mid: (a0 + angle) / 2}});
  const current = active !== null ? geo[active] : null;
  // Rótulos externos não se sobrepõem: em cada lado, afasta verticalmente os que ficariam colados.
  const labelY = geo.map((s, i) => pt(LABEL + (active === i ? GROW : 0), s.mid)[1]);
  for (const right of [true, false]) {
    const idx = geo.map((s, i) => i).filter(i => (Math.sin(geo[i].mid) >= 0) === right && (geo[i].a1 - geo[i].a0 >= 0.22 || active === i)).sort((a, b) => labelY[a] - labelY[b]);
    for (let k = 1; k < idx.length; k++) if (labelY[idx[k]] - labelY[idx[k - 1]] < 34) labelY[idx[k]] = labelY[idx[k - 1]] + 34;
  }
  const short = (name: string) => name.length > 14 ? name.slice(0, 13) + '…' : name;
  return <div className={'pie-wrap' + (tone === 'dark' ? ' on-dark' : '')}>
    <svg className="pie" viewBox="-60 30 560 380" role="img" aria-label={label} onMouseLeave={() => setActive(null)}>
      {geo.map((s, i) => {
        const on = active === i, ro = on ? RO + GROW : RO;
        return <path key={s.name} d={arc(s.a0, s.a1, RI, ro)} fill={s.color} stroke={tone === 'dark' ? 'var(--brand-deep)' : 'var(--panel)'} strokeWidth={2}
          className={'pie-slice' + (active !== null && !on ? ' dim' : '')} tabIndex={0} role="button"
          aria-label={`${s.name}: ${brl(s.value)}, ${pct(s.percent)}`}
          onMouseEnter={() => setActive(i)} onFocus={() => setActive(i)} onBlur={() => setActive(null)} onClick={() => setActive(on ? null : i)}>
          <title>{`${s.name}: ${brl(s.value)} · ${pct(s.percent)}`}</title>
        </path>;
      })}
      {geo.map((s, i) => {
        if (s.a1 - s.a0 < 0.22 && active !== i) return null; // fatias muito finas: rótulo só ao destacar
        const [x] = pt(LABEL + (active === i ? GROW : 0), s.mid), y = labelY[i], right = Math.sin(s.mid) >= 0;
        const [ix, iy] = pt((RI + RO) / 2, s.mid);
        return <g key={'l' + s.name} className={'pie-label' + (active !== null && active !== i ? ' dim' : '')} aria-hidden="true">
          {s.a1 - s.a0 >= 0.3 && <text x={ix} y={iy} className="pie-pct" textAnchor="middle" dominantBaseline="central">{pct(s.percent)}</text>}
          <text x={x} y={y} className="pie-name" textAnchor={right ? 'start' : 'end'} dominantBaseline="central">{short(s.name)}</text>
        </g>;
      })}
      <g className="pie-center donut-center" aria-hidden="true">
        <text x={C} y={C - 28} textAnchor="middle" className="pie-c-label">{current ? short(current.name) : center.label}</text>
        <text x={C} y={C + 8} textAnchor="middle" className={'pie-c-value' + (!current && center.negative ? ' neg' : '') + sizeClass(current ? brl(current.value) : center.value)}>{current ? brl(current.value) : center.value}</text>
        <text x={C} y={C + 38} textAnchor="middle" className="pie-c-sub">{current ? pct(current.percent) + suffix : center.sub ?? ''}</text>
      </g>
    </svg>
    {note && <p className="chart-note">Passe o mouse ou toque numa fatia para ver o valor.</p>}
  </div>;
}
