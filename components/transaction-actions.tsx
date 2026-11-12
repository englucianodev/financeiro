"use client";
// Transações: dois botões que abrem e fecham o formulário correspondente.
import {useState} from 'react';
import type {SupabaseClient} from '@supabase/supabase-js';
import {Receipt, CreditCard, HandCoins} from 'lucide-react';
import EntryForm from './entry-form';
import {CardEntryForm} from './credit-module';
import type {CreditData} from '@/lib/credit';
import type {ViewAccount} from '@/lib/finance-view';
import type {PropertyRecord} from './properties-panel';

export type TransactionMode = '' | 'expense' | 'card' | 'income';
export default function TransactionActions(props: {db: SupabaseClient; household: string; userId: string; accounts: ViewAccount[]; members: {user_id: string; display_name: string}[]; categories: {name: string; kind: string; active: boolean}[]; properties: PropertyRecord[]; data: CreditData; reload: () => Promise<void>; initialMode?: TransactionMode}) {
  const [mode, setMode] = useState<TransactionMode>(props.initialMode ?? '');
  const toggle = (m: TransactionMode) => setMode(current => current === m ? '' : m);
  return <section className="card transaction-actions">
    <div className="tx-toggles" role="group" aria-label="Novo lançamento">
      <button type="button" className={'tx-toggle' + (mode === 'expense' ? ' on' : '')} aria-expanded={mode === 'expense'} aria-controls="tx-form" onClick={() => toggle('expense')}><Receipt size={18}/>Despesa avulsa</button>
      <button type="button" className={'tx-toggle' + (mode === 'card' ? ' on' : '')} aria-expanded={mode === 'card'} aria-controls="tx-form" onClick={() => toggle('card')}><CreditCard size={18}/>Lançar no cartão</button>
      <button type="button" className={'tx-toggle' + (mode === 'income' ? ' on' : '')} aria-expanded={mode === 'income'} aria-controls="tx-form" onClick={() => toggle('income')}><HandCoins size={18}/>Receita</button>
    </div>
    <div id="tx-form">
      {mode === 'expense' && <EntryForm {...props} creditData={props.data} initialType="expense" cards={props.data.cards}/>}
      {mode === 'card' && <CardEntryForm {...props}/>}
      {mode === 'income' && <EntryForm {...props} creditData={props.data} initialType="income" cards={props.data.cards}/>}
    </div>
  </section>;
}
