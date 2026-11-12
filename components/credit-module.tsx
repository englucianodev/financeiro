"use client";
import {useEffect,useRef,useState,type FormEvent} from 'react';
import type {SupabaseClient} from '@supabase/supabase-js';
import StatementTools from './statement-tools';
import ImportHistory from './import-history';
import Donut from './donut';
import {CreditCard as CardIcon,Plus,ArrowLeft,ChevronRight} from 'lucide-react';
import MonthNav from './month-nav';
import {CardDetail,LineEditor} from './card-view';
import {brl,today} from '@/lib/money';
import {type ViewAccount,type ViewEvent,monthLabel,moveMonth} from '@/lib/finance-view';
import {type Card,type CreditData,type Invoice,type Line,cardLimit,invoiceTotals,cardCategorySummary,rootCard,creditStatus,invoiceMonth,cycleToDueMonth,dueMonthToCycle} from '@/lib/credit';
import {errorMessage} from '@/lib/errors';
type Member={user_id:string;display_name:string};
type Category={name:string;kind:string;active:boolean};
type Common={legacy?:ViewEvent[];db:SupabaseClient;household:string;data:CreditData;accounts:ViewAccount[];members:Member[];reload:()=>Promise<void>};
type Operation={action:string;purchase_id?:string;invoice_id?:string;obligation_id?:string;recurrence_id?:string;payment_id?:string;line_id?:string};
function useCreditAction(db:SupabaseClient,household:string,reload:()=>Promise<void>){
 const keys=useRef(new Map<string,string>()),lock=useRef(false);const [busy,setBusy]=useState(false),[error,setError]=useState('');
 async function execute(action:string,data:Record<string,unknown>){
  if(lock.current)return false;lock.current=true;setBusy(true);setError('');
  const signature=JSON.stringify([action,data]);let id=keys.current.get(signature);if(!id){id=crypto.randomUUID();keys.current.set(signature,id)}
  try{const r=await db.rpc('cc_action',{p_id:id,p_household:household,p_action:action,p_data:data});if(r.error)throw r.error;await reload();keys.current.delete(signature);return true}catch(e){setError(errorMessage(e));return false}finally{lock.current=false;setBusy(false)}
 }
 return {execute,busy,error};
}
const dateText=(date:string)=>date.split('-').reverse().join('/');

export function CardEntryForm({db,household,data,members,categories,reload}:{db:SupabaseClient;household:string;data:CreditData;members:Member[];categories:Category[];reload:()=>Promise<void>}){
 const {execute,busy,error}=useCreditAction(db,household,reload),[card,setCard]=useState(data.cards.find(c=>c.card_status==='active')?.id??''),[mode,setMode]=useState('purchase'),[repeating,setRepeating]=useState(false),[next,setNext]=useState(1),[count,setCount]=useState(1),[message,setMessage]=useState('');
 const selected=data.cards.find(c=>c.id===card),active=data.cards.filter(c=>c.card_status==='active'&&(!c.parent_card_id||data.cards.some(p=>p.id===c.parent_card_id&&p.card_status==='active')));
 async function submit(e:FormEvent<HTMLFormElement>){e.preventDefault();setMessage('');const fd=new FormData(e.currentTarget),action=repeating?'recurrence':mode==='purchase'?'purchase':'obligation';
  const payload={card_id:card,responsible_id:String(fd.get('responsible')),title:String(fd.get('title')),category:String(fd.get('category')),amount:Number(fd.get('amount')),date:String(fd.get('date')),installments:count,next_installment:next,first_cycle:fd.get('cycle')&&selected?dueMonthToCycle(rootCard(data.cards,selected),String(fd.get('cycle')))+'-01':null,mode:mode==='automatic'?'automatic':'manual',variable:fd.get('variable')==='on',unit:String(fd.get('unit')??'months'),every:Number(fd.get('every')??1),end_date:fd.get('end')||null};
  if(await execute(action,payload))setMessage(repeating?'Recorrência cadastrada.':mode==='manual'?'Obrigação pendente: confirme quando lançar no cartão.':mode==='automatic'?'Cobrança automática cadastrada.':'Compra cadastrada sem débito bancário.');
 }
 return <section className="card-entry"><h3>Lançar no cartão</h3><p className="muted">Compras entram no consumo; o banco só é debitado ao confirmar a fatura.</p><form className="form-grid" onSubmit={submit}>
  <label>Cartão<select aria-label="Cartão da despesa" required value={card} onChange={e=>setCard(e.target.value)}><option value="">Selecione</option>{active.map(c=><option key={c.id} value={c.id}>{c.name} · {members.find(m=>m.user_id===c.owner_id)?.display_name}</option>)}</select></label>
  <label>Responsável pela compra<select aria-label="Responsável pela compra" name="responsible" required defaultValue={members[0]?.user_id}>{members.map(m=><option key={m.user_id} value={m.user_id}>{m.display_name}</option>)}</select></label>
  {selected&&<p className="muted form-title">Titular: {members.find(m=>m.user_id===selected.owner_id)?.display_name}. Pagamento da fatura pela conta do titular de {rootCard(data.cards,selected).name}.</p>}
  <label>Tipo de lançamento no cartão<select aria-label="Tipo de lançamento no cartão" value={mode} onChange={e=>{setMode(e.target.value);setRepeating(false);setCount(1);setNext(1)}}><option value="purchase">Compra já realizada</option><option value="automatic">Cobrança automática no cartão</option><option value="manual">Lançamento manual no cartão</option></select></label>
  <label>Descrição da compra<input name="title" required maxLength={200}/></label><label>{mode==='purchase'?'Valor total da compra':'Valor da cobrança'}<input name="amount" type="number" required min=".01" step=".01"/></label>
  <label>Categoria da compra<select name="category" aria-label="Categoria da compra" required>{categories.filter(c=>c.kind==='expense'&&c.active).map(c=><option key={c.name}>{c.name}</option>)}</select></label>
  <label>{mode==='purchase'?'Data real da compra':mode==='manual'?'Vencimento da obrigação':'Data da cobrança'}<input name="date" required type="date" defaultValue={today()} max={mode==='purchase'?today():undefined}/></label>
  {mode==='purchase'?<><label>Quantidade de parcelas<input aria-label="Quantidade de parcelas" type="number" required min="1" max="120" value={count} onChange={e=>{setCount(Number(e.target.value));setNext(1)}}/></label><label>Próxima parcela<input aria-label="Próxima parcela" type="number" min="1" max={count} required value={next} onChange={e=>setNext(Number(e.target.value))}/></label><label>Primeira fatura {next>1?'(obrigatória)':'(opcional)'}<input aria-label="Primeira fatura" name="cycle" type="month" required={next>1}/><small>Mês do vencimento da fatura. Parcelamento antigo gera somente as parcelas restantes.</small></label></>:<><label className="check"><input type="checkbox" checked={repeating} onChange={e=>setRepeating(e.target.checked)}/>Repetir cobrança</label>{repeating&&<><label>Periodicidade<select name="unit"><option value="months">Meses</option><option value="days">Dias</option></select></label><label>Intervalo<input name="every" type="number" required min="1" max="365" defaultValue="1"/></label><label>Término (opcional)<input name="end" type="date"/></label><label className="check"><input name="variable" type="checkbox"/>Valor variável · atualizar as próximas após confirmar</label></>}</>}
  <p className="muted form-title">{mode==='manual'?'A obrigação permanece pendente e não usa limite até você confirmar a data real do lançamento.':mode==='automatic'?'A rotina registra a cobrança na data prevista. A fatura continua exigindo pagamento manual.':'Compras no dia do fechamento entram na próxima fatura. Datas 29 a 31 respeitam o fim do mês.'}</p>
  <button disabled={busy||!active.length}>Lançar no cartão</button>{!active.length&&<p className="muted">Cadastre um cartão ativo em Contas → Cartões de crédito.</p>}{error&&<p role="alert">{error}</p>}{message&&<p role="status">{message}</p>}
 </form></section>;
}

function CardEditor({card,onClose,...props}:Common&{card:Card|null;onClose:()=>void}){
 const {db,household,accounts,members,reload}=props,{execute,busy,error}=useCreditAction(db,household,reload),dialog=useRef<HTMLDialogElement>(null),[owner,setOwner]=useState(card?.owner_id??members[0]?.user_id??''),[account,setAccount]=useState(card&&accounts.some(a=>a.id===card.account_id&&a.owner_id===card.owner_id)?card.account_id:'');
 useEffect(()=>{dialog.current?.showModal()},[]);
 async function submit(e:FormEvent<HTMLFormElement>){e.preventDefault();const fd=new FormData(e.currentTarget);if(await execute('save_card',{card_id:card?.id??null,revision:card?.revision??0,owner_id:owner,account_id:account,name:String(fd.get('name')),issuer:card?.issuer??'',brand:card?.brand??'',last_four:card?.last_four??'',credit_limit:Number(fd.get('limit')),closing_day:Number(fd.get('close')),due_day:Number(fd.get('due')),automatic_debit:fd.get('automatic')==='on',color:String(fd.get('color')),card_status:String(fd.get('status')),parent_card_id:card?.parent_card_id??null}))onClose()}
 return <dialog ref={dialog} className="account-dialog" aria-label={card?'Editar cartão':'Novo cartão'} onCancel={e=>{if(busy)e.preventDefault();else onClose()}}><form className="form-grid" onSubmit={submit}><h2 className="form-title">{card?'Editar cartão':'Novo cartão'}</h2>
  <label>Nome do cartão<input aria-label="Nome do cartão" name="name" required maxLength={120} defaultValue={card?.name}/></label>
  <label>Titular do cartão<select aria-label="Titular do cartão" required value={owner} onChange={e=>{setOwner(e.target.value);setAccount('')}}>{members.map(m=><option key={m.user_id} value={m.user_id}>{m.display_name}</option>)}</select></label>
  <label>Conta principal de pagamento<select aria-label="Conta principal de pagamento" required value={account} onChange={e=>setAccount(e.target.value)}><option value="">Selecione uma conta do titular</option>{accounts.filter(a=>a.owner_id===owner&&a.account_type!=='investment').map(a=><option key={a.id} value={a.id}>{a.name}</option>)}</select></label>
  <label>Limite total<input name="limit" type="number" min="0" step=".01" required defaultValue={card?.credit_limit??0}/></label><label>Dia de fechamento<input name="close" type="number" min="1" max="31" required defaultValue={card?.closing_day??5}/></label><label>Dia de vencimento<input name="due" type="number" min="1" max="31" required defaultValue={card?.due_day??15}/></label>
  <label>Cor<input name="color" type="color" defaultValue={card?.color??'#765484'}/></label><label>Status do cartão<select name="status" defaultValue={card?.card_status??'active'}><option value="active">Ativo</option><option value="blocked">Bloqueado</option><option value="archived">Arquivado</option></select></label><label className="check"><input name="automatic" type="checkbox" defaultChecked={card?.automatic_debit}/>Débito automático informado</label>
  <p className="muted form-title">O débito automático não confirma pagamentos. Arquivar preserva todo o histórico. Datas novas não alteram faturas existentes.</p><button disabled={busy}>Salvar cartão</button><button type="button" disabled={busy} onClick={onClose}>Cancelar</button>{error&&<p role="alert" className="form-title">{error}</p>}
 </form></dialog>;
}

function InvoiceOperationDialog({operation,onClose,...props}:Common&{operation:Operation;onClose:()=>void}){
 const {db,household,data,accounts,members,reload}=props,{execute,busy,error}=useCreditAction(db,household,reload),dialog=useRef<HTMLDialogElement>(null);
 const invoice=data.invoices.find(i=>i.id===operation.invoice_id),ob=data.obligations.find(o=>o.id===operation.obligation_id),rec=data.recurrences.find(r=>r.id===operation.recurrence_id),card=data.cards.find(c=>c.id===(invoice?.card_id??ob?.card_id??rec?.card_id));
 const totals=invoice?invoiceTotals(invoice,data.lines):null;
 const [amount,setAmount]=useState(String(ob?.amount??rec?.amount??(totals?Math.abs(totals.balance):0))),[line,setLine]=useState('');
 useEffect(()=>{dialog.current?.showModal()},[]);
 const action=operation.action;
 const titles:Record<string,string>={pay_invoice:'Confirmar pagamento de fatura',confirm_obligation:'Confirmar lançamento no cartão',edit_obligation:'Editar obrigação no cartão',cancel_obligation:'Cancelar obrigação no cartão',undo_payment:'Desfazer pagamento de fatura',fee:'Informar juros ou multa',refund:'Registrar estorno',anticipate:'Antecipar parcela',transfer_credit:'Transferir crédito entre faturas',edit_recurrence:'Editar recorrência no cartão'};
 const lines=data.lines.filter(l=>l.line_type==='principal'&&(action==='refund'?rootCard(data.cards,data.cards.find(c=>c.id===l.card_id)!).id===card?.id:action==='anticipate'?l.paid===0&&data.invoices.some(i=>i.id===l.invoice_id&&i.card_id===card?.id&&i.due_date>(invoice?.due_date??'')):false));
 async function submit(e:FormEvent<HTMLFormElement>){e.preventDefault();const fd=new FormData(e.currentTarget),payload={...operation,revision:invoice?.revision??ob?.revision??rec?.revision,amount:Number(amount),date:fd.get('date')||today(),account_id:fd.get('account')||null,line_id:line||null,title:fd.get('title')||'',discount:Number(fd.get('discount')??0),target_invoice_id:fd.get('target')||null,state:fd.get('state')||null,end_date:fd.get('end')||null,unit:fd.get('unit')||null,every:fd.get('every')?Number(fd.get('every')):null,start_date:fd.get('start')||null,cancel_pending:fd.get('cancel_pending')==='on'};if(await execute(action,payload))onClose()}
 return <dialog ref={dialog} className="account-dialog" aria-label={titles[action]} onCancel={e=>{if(busy)e.preventDefault();else onClose()}}><form className="form-grid" onSubmit={submit}><h2 className="form-title">{titles[action]}</h2><p className="muted form-title">{card?.name} {invoice?'· '+monthLabel(invoice.cycle.slice(0,7)):''} {ob?'· '+ob.title:''}</p>
  {['cancel_obligation','undo_payment'].includes(action)?<p className="form-title">{action==='undo_payment'?'O valor será devolvido à conta original e a fatura voltará a ficar pendente. O histórico será preservado.':'Cancelar mantém o registro e remove a previsão. Uma cobrança já lançada deve receber estorno.'}</p>:<>
   {action==='pay_invoice'&&<><p className="form-title">Saldo da fatura: {brl(totals?.balance??0)}. Pode pagar integralmente ou em vários pagamentos parciais. {card?.automatic_debit?'Débito automático informado: confirme somente após conferir no banco.':''}</p><label>Conta do pagamento<select aria-label="Conta do pagamento" required name="account" defaultValue={accounts.some(a=>a.id===card?.account_id&&a.owner_id===card?.owner_id)?card?.account_id:''}><option value="">Selecione uma conta válida do titular</option>{accounts.filter(a=>a.owner_id===card?.owner_id&&a.account_type!=='investment').map(a=><option key={a.id} value={a.id}>{a.name}</option>)}</select></label></>}
   {['refund','anticipate'].includes(action)&&<label>Compra ou parcela<select required aria-label="Compra ou parcela" value={line} onChange={e=>{setLine(e.target.value);setAmount(String(data.lines.find(l=>l.id===e.target.value)?.amount??0))}}><option value="">Selecione</option>{lines.map(l=><option key={l.id} value={l.id}>{l.title} · {l.installment} · {brl(Number(l.amount))}</option>)}</select></label>}
   <label>{action==='confirm_obligation'?'Valor realmente lançado':'Valor'}<input aria-label="Valor da operação de cartão" type="number" required min=".01" step=".01" max={action==='pay_invoice'?totals?.balance:action==='transfer_credit'?Math.abs(totals?.balance??0):undefined} value={amount} onChange={e=>setAmount(e.target.value)}/></label>
   {action==='fee'&&<label>Descrição do encargo<input name="title" maxLength={200} required defaultValue="Juros / multa"/></label>}
   {action==='anticipate'&&<label>Desconto informado<input name="discount" type="number" min="0" max={amount} step=".01" defaultValue="0" required/></label>}
   {action==='transfer_credit'&&<label>Fatura de destino<select name="target" required><option value="">Selecione</option>{data.invoices.filter(i=>i.card_id===card?.id&&i.id!==invoice?.id).map(i=><option key={i.id} value={i.id}>{monthLabel(invoiceMonth(i))}</option>)}</select></label>}
   {action==='edit_recurrence'?<><label>Estado<select name="state" defaultValue={rec?.state}><option value="active">Ativa</option><option value="paused">Pausada</option><option value="ended">Encerrada</option></select></label><label>Nova periodicidade<select name="unit" defaultValue={rec?.unit}><option value="months">Meses</option><option value="days">Dias</option></select></label><label>Novo intervalo<input name="every" type="number" min="1" max="365" required defaultValue={rec?.every}/></label><label>Nova data inicial<input name="start" type="date" required defaultValue={rec?.start_date}/></label><label>Data final (opcional)<input name="end" type="date" defaultValue={rec?.end_date??''}/></label><label className="check"><input type="checkbox" name="cancel_pending"/>Cancelar previsões futuras ainda não lançadas</label><p className="muted form-title">Pausar suspende a geração e as previsões futuras. Encerrar cancela obrigações futuras pendentes. Cobranças já lançadas ficam preservadas. Alterar periodicidade ou início encerra a regra anterior e cria uma nova, substituindo apenas obrigações futuras pendentes.</p></>:<label>{action==='edit_obligation'?'Novo vencimento':'Data efetiva'}<input name="date" type="date" required defaultValue={action==='edit_obligation'?ob?.due_date:today()} max={action==='edit_obligation'?undefined:today()}/></label>}
  </>}
  <button disabled={busy}>Confirmar operação</button><button type="button" disabled={busy} onClick={onClose}>Cancelar</button>{error&&<p role="alert" className="form-title">{error}</p>}
 </form></dialog>;
}

export function operationForEvent(event:ViewEvent):Operation|null{return event.source==='cc_charge'&&event.linked_purchase_id?{action:'edit_purchase',purchase_id:event.linked_purchase_id}:event.source==='cc_invoice'?{action:'pay_invoice',invoice_id:event.source_id}:event.source==='cc_obligation'?{action:event.card_mode==='manual'?'confirm_obligation':'edit_obligation',obligation_id:event.source_id}:null}

export default function CreditPanel(props:Common&{categories:Category[];moduleError?:string}){
 const {data,members,moduleError}=props,[editing,setEditing]=useState<Card|null|undefined>(undefined),[selected,setSelected]=useState(''),[operation,setOperation]=useState<Operation|null>(null),[tab,setTab]=useState<'cards'|'history'>('cards'),[showArchived,setShowArchived]=useState(false),[statement,setStatement]=useState<Card|null>(null),[lineEdit,setLineEdit]=useState<Line|null>(null);
 const card=data.cards.find(c=>c.id===selected);
 const visible=data.cards.filter(c=>showArchived||c.card_status!=='archived');
 const pending=data.obligations.filter(o=>o.state==='pending'&&o.mode==='manual');
 return <section id="credit-module" className="space-y-4">
  <div className="section-heading"><h2>Cartões de crédito</h2>{!card&&<button className="btn sm" onClick={()=>setEditing(null)} disabled={Boolean(moduleError)}><Plus size={15}/>Novo cartão</button>}</div>
  {moduleError?<p role="alert">{moduleError}</p>:<>
  {!card&&<nav className="ccv-tabs" aria-label="Área de cartões"><button aria-pressed={tab==='cards'} onClick={()=>setTab('cards')}>Cartões e faturas</button><button aria-pressed={tab==='history'} onClick={()=>setTab('history')}>Recorrências e histórico</button></nav>}
  {tab==='cards'&&card&&<CardDetail card={card} data={data} members={members} accounts={props.accounts} legacy={props.legacy} onBack={()=>setSelected('')} onEditCard={()=>setEditing(card)} onImport={()=>setStatement(card)} onOperation={setOperation} onEditLine={setLineEdit}/>}
  {tab==='cards'&&!card&&<>
   <div className="ccv-grid">{visible.map(c=>{const limit=cardLimit(data,c,props.legacy??[]),inv=currentInvoice(data,rootCard(data.cards,c)),t=inv?invoiceTotals(inv,data.lines):null;return <article key={c.id} className="ccv-tile" style={{borderTopColor:c.color??undefined}}>
    <header><h3><CardIcon size={17}/>{c.name}</h3><span className="ccv-owner">{members.find(m=>m.user_id===c.owner_id)?.display_name}{c.card_status!=='active'&&' · '+(c.card_status==='archived'?'arquivado':'bloqueado')}</span></header>
    <div className="ccv-tile-total"><span>{inv?'Fatura de '+monthLabel(inv.due_date.slice(0,7)).split(' de ')[0]:'Sem fatura'}</span><strong>{brl(t?.total??0)}</strong>{inv&&<small>vence {inv.due_date.slice(8,10)}/{inv.due_date.slice(5,7)} · {t?.status}</small>}</div>
    <div className="ccv-limit-text small"><span>Disponível</span><strong>{brl(limit.available)}</strong></div>
    <div className="ccv-bar"><i style={{width:Math.min(100,Math.max(0,limit.percent))+'%'}}/></div>
    <div className="ccv-tile-actions"><button className="btn sm" onClick={()=>setSelected(c.id)}>Ver fatura</button><button className="btn ghost sm" onClick={()=>setStatement(c)}>Importar</button></div>
   </article>})}</div>
   {!data.cards.length&&<p className="muted">Nenhum cartão cadastrado.</p>}
   {data.cards.some(c=>c.card_status==='archived')&&<label className="check"><input type="checkbox" checked={showArchived} onChange={e=>setShowArchived(e.target.checked)}/>Mostrar cartões arquivados</label>}
   {pending.length>0&&<section className="ccv-section"><header><h4>Lançamentos a confirmar no cartão <span className="ccv-count">{pending.length}</span></h4></header><ul>{pending.map(o=><li key={o.id} className="ccv-payment"><span>{dateText(o.due_date)} · {o.title}</span><strong>{brl(Number(o.amount))}</strong><button className="btn ghost sm" onClick={()=>setOperation({action:'confirm_obligation',obligation_id:o.id})}>Confirmar</button></li>)}</ul></section>}
  </>}
  {tab==='history'&&!card&&<>
   <ImportHistory db={props.db} household={props.household} data={data} reload={props.reload}/>
   <section className="ccv-section"><header><h4>Recorrências no cartão <span className="ccv-count">{data.recurrences.length}</span></h4></header>{data.recurrences.length?<ul>{data.recurrences.map(r=><li key={r.id} className="ccv-payment"><span>{r.title} · {r.mode==='automatic'?'automática':'manual'} · {r.state==='active'?'ativa':r.state==='paused'?'pausada':'encerrada'}</span><strong>{brl(Number(r.amount))}</strong><button className="btn ghost sm" onClick={()=>setOperation({action:'edit_recurrence',recurrence_id:r.id})}>Editar</button></li>)}</ul>:<p className="ccv-empty">Nenhuma recorrência.</p>}</section>
   <section className="ccv-section"><header><h4>Obrigações <span className="ccv-count">{data.obligations.length}</span></h4></header>{data.obligations.length?<ul>{data.obligations.map(o=><li key={o.id} className="ccv-payment"><span>{dateText(o.due_date)} · {o.title} · {o.state==='pending'?'pendente':o.state==='posted'?'lançada':'cancelada'}{o.generation_error&&' · '+o.generation_error}</span><strong>{brl(Number(o.amount))}</strong>{o.state==='pending'&&<button className="btn ghost sm" onClick={()=>setOperation({action:'edit_obligation',obligation_id:o.id})}>Editar</button>}</li>)}</ul>:<p className="ccv-empty">Nenhuma obrigação.</p>}</section>
  </>}
  </>}
  {statement&&<StatementTools {...props} card={statement} onClose={()=>setStatement(null)}/>}
  {editing!==undefined&&<CardEditor {...props} card={editing} onClose={()=>setEditing(undefined)}/>}
  {operation&&<CreditOperationDialog key={JSON.stringify(operation)} {...props} operation={operation} onClose={()=>setOperation(null)}/>}
  {lineEdit&&<LineEditor db={props.db} household={props.household} data={data} line={lineEdit} categories={props.categories} reload={props.reload} onClose={()=>setLineEdit(null)} onEditPurchase={id=>setOperation({action:'edit_purchase',purchase_id:id})}/>}
 </section>;
}

/** Fatura em destaque: a próxima a vencer com saldo; senão, a mais recente com lançamentos. */
function currentInvoice(data:CreditData,root:Card){
 const own=data.invoices.filter(i=>i.card_id===root.id).sort((a,b)=>a.cycle.localeCompare(b.cycle)),current=today();
 return own.find(i=>i.due_date>=current&&invoiceTotals(i,data.lines).balance>0)??own.filter(i=>data.lines.some(l=>l.invoice_id===i.id)).at(-1)??own.find(i=>i.closing_date>=current);
}

export function CreditOverview({data,members,legacy=[]}:{data:CreditData;members:Member[];legacy?:ViewEvent[]}){
 const [month,setMonth]=useState(today().slice(0,7)),[focus,setFocus]=useState<string|null>(null),top=useRef<HTMLElement>(null);
 if(!data.cards.length)return null;
 const visible=data.cards.filter(c=>c.card_status!=='archived'||data.lines.some(l=>l.card_id===c.id));
 const selected=focus?visible.find(c=>c.id===focus)??null:null;
 const shown=selected?[selected]:visible;
 const mine=(cardId:string)=>!selected||cardId===selected.id||rootCard(data.cards,selected).id===cardId;
 const alertDate=(days:number)=>new Date(Date.parse(today()+'T12:00:00Z')+days*86400000).toISOString().slice(0,10);
 const cardName=(id:string)=>data.cards.find(c=>c.id===id)?.name;
 const alerts=[
  ...data.obligations.filter(o=>o.state==='pending'&&mine(o.card_id)&&o.due_date<=alertDate(3)).map(o=>({id:o.id,text:(o.mode==='manual'?'Lançamento manual pendente':'Cobrança automática pendente')+' · '+o.title+' · '+dateText(o.due_date)+(o.generation_error?' · '+o.generation_error:'')})),
  ...data.invoices.filter(i=>mine(i.card_id)&&i.closing_date>=today()&&i.closing_date<=alertDate(3)).map(i=>({id:'close'+i.id,text:'Próximo fechamento · '+cardName(i.card_id)+' · '+dateText(i.closing_date)})),
  ...data.invoices.filter(i=>mine(i.card_id)&&invoiceTotals(i,data.lines).balance>0&&i.due_date<=alertDate(7)).map(i=>({id:'due'+i.id,text:'Fatura '+(i.due_date<today()?'atrasada':'a vencer')+' · '+cardName(i.card_id)+' · '+dateText(i.due_date)}))];
 const pick=(id:string|null)=>{setFocus(id);setTimeout(()=>top.current?.scrollIntoView({block:'start',behavior:'smooth'}),0)};
 return <section ref={top} className="card credit-overview" aria-label="Cartões de crédito no mês">
  <div className="section-heading"><h2>{selected?selected.name:'Cartões de crédito no mês'}</h2>{selected&&<button type="button" className="btn sm ghost" onClick={()=>pick(null)}><ArrowLeft size={16}/>Todos os cartões</button>}</div>
  <MonthNav month={month} onChange={setMonth} context="dos cartões"/>
  {alerts.length>0&&<aside className="credit-alerts" aria-label="Alertas de cartões">{alerts.map(a=><p key={a.id}>{a.text}</p>)}</aside>}
  <div className={selected?'credit-card-single':'credit-card-grid'}>{shown.map(card=>{
   const l=cardLimit(data,card,legacy),summary=cardCategorySummary(data,card,month,legacy),invoice=data.invoices.find(i=>i.card_id===l.root.id&&invoiceMonth(i)===month),t=invoice?invoiceTotals(invoice,data.lines):null;
   const owner=members.find(m=>m.user_id===card.owner_id)?.display_name;
   const lines=selected&&invoice?data.lines.filter(x=>x.invoice_id===invoice.id&&x.card_id===card.id).sort((a,b)=>a.charge_date.localeCompare(b.charge_date)||a.title.localeCompare(b.title)):[];
   return <article className="credit-card-summary" key={card.id} style={{borderColor:card.color??'#765484'}}>
    <h3>{selected?<>{card.name} · {owner}</>:<button type="button" className="card-link" aria-label={'Ver detalhes do cartão '+card.name} onClick={()=>pick(card.id)}><span>{card.name} · {owner}</span><ChevronRight size={18} aria-hidden="true"/></button>}</h3>
    <p>{card.parent_card_id?'Adicional · limite e fatura compartilhados':'Limite próprio'} · {card.card_status==='archived'?'Arquivado':card.card_status==='blocked'?'Bloqueado':'Ativo'}</p>
    <div className="credit-metrics"><span>Fatura<strong>{brl(t?.balance??0)}</strong></span><span>Limite total<strong>{brl(l.total)}</strong></span><span>Utilizado<strong>{brl(l.used)}</strong></span><span>Disponível<strong>{brl(l.available)}</strong></span></div>
    <p>{l.percent.toLocaleString('pt-BR',{maximumFractionDigits:1})}% utilizado · {t?.status??'Sem fatura'}</p>
    {summary.categories.length?<Donut key={month} slices={summary.categories} label={'Despesas por categoria · '+card.name} suffix=" das despesas" note={false} center={{label:'Despesas do mês',value:brl(summary.expense),sub:summary.categories.length+(summary.categories.length>1?' categorias':' categoria')}}/>:<p className="muted credit-empty">Sem despesas neste mês.</p>}
    <small>Fechamento {invoice?dateText(invoice.closing_date):'dia '+l.root.closing_day} · Vencimento {invoice?dateText(invoice.due_date):'dia '+l.root.due_day}</small>
    {selected&&<div className="card-detail-lines"><h4>Lançamentos da fatura de {monthLabel(month)} <span className="ccv-count">{lines.length}</span></h4>
     {lines.length?<ul className="row-list">{lines.map(x=>{const pur=x.purchase_id?data.purchases.find(p=>p.id===x.purchase_id):null;return <li key={x.id}><span className="rl-date">{dateText(x.charge_date).slice(0,5)}</span><span className="rl-main"><b>{x.title}</b><small>{x.category}{x.installment&&pur&&pur.installments>1?` · ${x.installment}/${pur.installments}`:''}{x.line_type==='fee'?' · encargo':Number(x.amount)<0?' · crédito':''}</small></span><strong className={Number(x.amount)<0?'positive':''}>{brl(Number(x.amount))}</strong></li>})}</ul>:<p className="muted">Nenhum lançamento nesta fatura.</p>}
    </div>}
   </article>})}</div>
 </section>;
}

export function CreditOperationDialog(props:Common&{operation:Operation;onClose:()=>void}){
 return props.operation.action==='edit_purchase'?<PurchaseEditor {...props}/>:<InvoiceOperationDialog {...props}/>;
}
function PurchaseEditor({db,household,data,reload,operation,onClose}:Common&{operation:Operation;onClose:()=>void}){
 const purchase=data.purchases.find(p=>p.id===operation.purchase_id);
 const principal=data.lines.filter(l=>l.purchase_id===purchase?.id&&l.line_type==='principal'&&l.installment!==null).sort((a,b)=>(a.installment??0)-(b.installment??0));
 const first=data.invoices.find(i=>i.id===principal[0]?.invoice_id);
 const originCycles=Array.from(new Set(principal.map(l=>data.invoices.find(i=>i.id===l.invoice_id)?.due_date.slice(0,7)).filter((m):m is string=>Boolean(m)))).sort();
 const [card,setCard]=useState(purchase?.card_id??''),[count,setCount]=useState(purchase?.installments??1),[next,setNext]=useState(purchase?.next_installment??1),[cycle,setCycle]=useState(first?.cycle.slice(0,7)??''),[confirmed,setConfirmed]=useState(false);
 const {execute,busy,error}=useCreditAction(db,household,reload),dialog=useRef<HTMLDialogElement>(null);
 useEffect(()=>{dialog.current?.showModal()},[]);
 const editCard=data.cards.find(c=>c.id===card),editRoot=editCard?rootCard(data.cards,editCard):null,dueMonth=cycle&&editRoot?cycleToDueMonth(editRoot,cycle):cycle;
 if(!purchase)return null;
 return <dialog ref={dialog} className="account-dialog" aria-label="Editar compra no cartão" onCancel={e=>{if(busy)e.preventDefault();else onClose()}}><form className="form-grid" onChange={()=>setConfirmed(false)} onSubmit={async e=>{e.preventDefault();const fd=new FormData(e.currentTarget);const suspect=data.purchases.some(p=>p.id!==purchase.id&&p.card_id===card&&p.title.trim().toLocaleLowerCase('pt-BR')===String(fd.get('title')).trim().toLocaleLowerCase('pt-BR')&&p.charge_date===fd.get('date')&&Number(p.amount)===Number(fd.get('amount')));if(suspect&&!window.confirm('Possível duplicidade: existe outra compra com cartão, descrição, data e total iguais. Conferiu e deseja salvar?'))return;if(await execute('edit_purchase',{purchase_id:purchase.id,confirm_duplicates:suspect,revision:purchase.revision??0,invoice_revisions:Object.fromEntries(data.invoices.map(i=>[i.id,i.revision])),card_id:card,title:fd.get('title'),category:fd.get('category'),amount:Number(fd.get('amount')),date:fd.get('date'),installments:count,next_installment:next,first_cycle:cycle+'-01',confirm_reconciled:confirmed}))onClose()}}>
 <h2 className="form-title">Editar compra no cartão</h2><p className="muted form-title">Corrige a compra inteira e suas parcelas restantes, preservando vínculos e auditoria. Valor é o total original da compra, não o de uma parcela. Nenhum saldo bancário é alterado.</p>
 <label>Descrição<input name="title" required maxLength={200} defaultValue={purchase.title}/></label>
 <label>Valor total da compra<input name="amount" type="number" min=".01" step=".01" required defaultValue={purchase.amount}/></label>
 <label>Data da compra<input name="date" type="date" required max={today()} defaultValue={purchase.charge_date}/></label>
 <label>Categoria<input name="category" required maxLength={100} defaultValue={purchase.category}/></label>
 <label>Cartão vinculado<select required value={card} onChange={e=>setCard(e.target.value)}>{data.cards.map(c=><option key={c.id} value={c.id}>{c.name}</option>)}</select></label>
 <label>Tipo da compra<select value={count===1?'single':'installments'} onChange={e=>{setCount(e.target.value==='single'?1:2);setNext(1)}}><option value="single">À vista</option><option value="installments">Parcelada</option></select></label>
 <label>Quantidade total de parcelas<input type="number" min="1" max="120" required value={count} onChange={e=>{setCount(Number(e.target.value))}}/></label>
 <label>Número da primeira parcela restante<input type="number" min="1" max={count} required value={next} onChange={e=>setNext(Number(e.target.value))}/></label>
 <label>Fatura de referência<input type="month" required value={dueMonth} onChange={e=>setCycle(editRoot?dueMonthToCycle(editRoot,e.target.value):e.target.value)}/><small>Mês do vencimento da fatura da primeira parcela restante. Não cria parcelas anteriores.</small></label>
 <p className="form-title">Período de origem: {first?monthLabel(invoiceMonth(first)):'Não identificado'}. Destino: {dueMonth?monthLabel(dueMonth):'Selecione mês e ano'} até {dueMonth&&count>=next?monthLabel(moveMonth(dueMonth,count-next)):'Selecione parcelas válidas'}. Todas as parcelas restantes serão reorganizadas e os totais das faturas de origem e destino serão atualizados.</p>
 <details className="form-title"><summary>Faturas de origem afetadas</summary><p>{originCycles.map(monthLabel).join(', ')}</p></details>
 <p className="muted form-title">Faturas com histórico de pagamento bloqueiam mudanças financeiras. Estornos permanecem vinculados; compras com estorno/desconto preservam o cartão. Faturas fechadas, importadas ou ajustadas exigem confirmação explícita.</p>
 <label className="check form-title"><input type="checkbox" checked={confirmed} onChange={e=>{e.stopPropagation();setConfirmed(e.target.checked)}}/>Confirmo a movimentação das parcelas entre os períodos de origem e destino indicados, inclusive fechados ou conciliados, e a atualização dos totais afetados.</label>
 <button disabled={busy}>Salvar compra</button><button type="button" disabled={busy} onClick={onClose}>Cancelar</button>{error&&<p role="alert" className="form-title">{error}</p>}
 </form></dialog>;
}
