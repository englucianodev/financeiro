import type {CreditData} from './credit';
export type StatementRow={original:string;description:string;date:string;amount:number;category:string;installment:number;count:number;total_amount:number|null;bank_id:string;kind:'purchase'|'refund'|'fee'|'credit'|'payment';decision:''|'new'|'link'|'skip';match_id:string;comparison:string};
export function money(text:string){let s=text.replace(/R\$|\s/g,'').replace(/[()]/g,'');if(s.includes(','))s=s.replace(/\./g,'').replace(',','.');const n=Number(s);return Number.isFinite(n)?Math.round(n*100)/100:NaN}
export function statementDate(s:string){s=s.trim();if(/^\d{8,}/.test(s))s=s.slice(0,4)+'-'+s.slice(4,6)+'-'+s.slice(6,8);else if(/^\d{2}\/\d{2}\/\d{4}$/.test(s))s=s.split('/').reverse().join('-');if(!/^\d{4}-\d{2}-\d{2}$/.test(s))return '';const d=new Date(s+'T12:00:00Z');return Number.isFinite(d.getTime())&&d.toISOString().slice(0,10)===s?s:''}
const normal=(s:string)=>s.normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase().replace(/[^a-z0-9]/g,'');
export function makeRow(description:string,date:string,amount:number,bank_id='',type=''):StatementRow{
 const part=description.match(/(?:parc\s*)?\b(\d{1,3})\s*\/\s*(\d{1,3})\b/i),count=part?Number(part[2]):1,installment=part?Number(part[1]):1;
 const d=normal(description+' '+type);const kind=/pagamento|payment|pgtorecebido/.test(d)?'payment':/estorno|refund/.test(d)?'refund':/juros|multa|tarifa|anuidade|fee/.test(d)||/\biof\b/i.test(description)?'fee':amount<0?'credit':'purchase';
 return {original:description,description,amount:kind==='refund'?-Math.abs(amount):amount,date:statementDate(date),bank_id,kind,category:kind==='fee'?'Encargos':'Outros',count,installment,total_amount:count===1?Math.abs(amount):null,decision:'',match_id:'',comparison:'Necessita revisão'};
}
function csvRows(text:string){const sep=text.split(/\r?\n/)[0].includes(';')?';':',';const rows:string[][]=[];let row:string[]=[],cell='',quoted=false;for(let i=0;i<text.length;i++){const c=text[i];if(c==='"'){if(quoted&&text[i+1]==='"'){cell+='"';i++}else quoted=!quoted}else if(c===sep&&!quoted){row.push(cell);cell=''}else if(c==='\n'&&!quoted){row.push(cell.replace(/\r$/,''));rows.push(row);row=[];cell=''}else cell+=c}if(cell||row.length){row.push(cell);rows.push(row)}return rows}
export function parseStatement(text:string,format:string,referenceDate=''){const rows:StatementRow[]=[];const warnings:string[]=[];
 if(format==='ofx'){
  const tag=(s:string,t:string)=>s.match(new RegExp('<'+t+'>([^<\\r\\n]+)','i'))?.[1]?.trim()??'';
  for(const block of text.split(/<STMTTRN>/i).slice(1)){rows.push(makeRow(tag(block,'NAME')+' '+tag(block,'MEMO'),tag(block,'DTPOSTED'),-money(tag(block,'TRNAMT')),tag(block,'FITID'),tag(block,'TRNTYPE')))}
 }else if(format==='csv'){
  const table=csvRows(text.replace(/^\uFEFF/,'')),head=(table.shift()??[]).map(normal);
  const index=(terms:string[])=>head.findIndex(h=>terms.includes(h));const di=index(['data','date','datacompra']),de=index(['descricao','description','historico','estabelecimento']),am=index(['valor','amount']),id=index(['id','fitid','identificador']);
  if(di<0||de<0||am<0)warnings.push('CSV precisa de colunas Data, Descrição e Valor.');
  else for(const r of table)if(r.some(Boolean))rows.push(makeRow(r[de]??'',r[di]??'',money(r[am]??''),id>=0?r[id]??'':''));
 }else{
  const sourceDate=text.match(/emiss[aã]o\s*:\s*(\d{2}\/\d{2}\/\d{4})/i)?.[1]??text.match(/feitas at[eé]\s*(\d{2}\/\d{2}\/\d{2,4})/i)?.[1]??text.match(/^\s*fechamento(?: da fatura)?\s*:?\s*(\d{2}\/\d{2}\/\d{2,4})/im)?.[1]??text.match(/vencimento\s*:\s*(\d{2}\/\d{2}\/\d{4})/i)?.[1];
  const expand=(d:string)=>d.replace(/(\d{2}\/\d{2}\/)(\d{2})$/,(_,prefix,year)=>prefix+'20'+year);const reference=sourceDate?statementDate(expand(sourceDate)):referenceDate;
  const months=['jan','fev','mar','abr','mai','jun','jul','ago','set','out','nov','dez'];let future=false,inferred=false;
  for(const line of text.split(/\r?\n/)){
   if(line.includes('\f')){future=false;continue}if(/compras parceladas.*pr[oó]ximas faturas/i.test(line)){future=true;continue}if(future)continue;
   const m=line.match(/^\s*(\d{2}\/\d{2}(?:\/\d{2,4})?|\d{4}-\d{2}-\d{2}|\d{2}\s+(?:jan|fev|mar|abr|mai|jun|jul|ago|set|out|nov|dez))\s+(.+?)\s+(-?[ \u00a0]*(?:R\$\s*)?[\d.]+,\d{2}|-?\d+\.\d{2})\s*$/i);
   if(!m||!m[2].replace(/R\$|[\d.,+\-\s]/g,''))continue;let date=m[1];if(/^[0-9]{2}\s+[a-z]{3}$/i.test(date))date=date.slice(0,2)+'/'+String(months.indexOf(date.slice(3).trim().toLowerCase())+1).padStart(2,'0');
   const row=makeRow(m[2].replace(/\s+/g,' ').trim(),expand(date),money(m[3]));
   if(!row.date&&reference&&/^\d{2}\/\d{2}$/.test(date)){
    const ref=new Date(reference+'T12:00:00Z'),refYear=ref.getUTCFullYear(),month=Number(date.slice(3)),day=Number(date.slice(0,2));let best='',score=Infinity;
    for(let year=refYear;year>=refYear-10;year--){const candidate=String(year)+'-'+String(month).padStart(2,'0')+'-'+String(day).padStart(2,'0');if(!statementDate(candidate)||candidate>reference)continue;const elapsed=(refYear-year)*12+ref.getUTCMonth()+1-month;const distance=Math.abs(elapsed-Math.max(0,row.installment-1));if(distance<score){score=distance;best=candidate}}
    row.date=best;inferred=true;
   }rows.push(row);
  }
  warnings.push('Confira as linhas, parcelas e totais antes de importar. Resumos de parcelas futuras não são novas compras.');if(inferred)warnings.push('Ano das compras reconstruído pela referência da fatura e pela parcela atual. Confira especialmente compras antigas.');if(rows.some(r=>!r.date))warnings.push('Há datas incompletas: informe a referência da fatura ou corrija as linhas.');if(/cart[oõ]es adicionais/i.test(text))warnings.push('A fatura contém cartões adicionais. Confira o cartão e o responsável antes de importar.');

 }
 const metadata={cycle:text.match(/compet[eê]ncia\s*[:\s]+(\d{2}\/\d{4})/i)?.[1]??'',institution:text.match(/\b(Nubank|Ita[uú]|Inter|Santander|Bradesco|Banco do Brasil|C6|Caixa)\b/i)?.[0]??'',due:text.match(/vencimento\s*[:\s]+(\d{2}\/\d{2}\/\d{4})/i)?.[1]??'',closing:text.match(/fechamento\s*[:\s]+(\d{2}\/\d{2}\/\d{4})/i)?.[1]??'',total:text.match(/(?:total\s+(?:(?:da|desta)\s+)?fatura|valor\s+da\s+fatura)\s*[:\sR$]+([\d.]+,\d{2})/i)?.[1]??'',holder:text.match(/titular\s*:\s*([^\n]+)/i)?.[1]??''};
 if(!rows.length)warnings.push('Nenhum lançamento reconhecido com segurança. Revise o arquivo ou use CSV com cabeçalho.');
 return {rows,warnings,metadata};
}
export function compareRow(row:StatementRow,data:CreditData,card:string):StatementRow{
 const candidates=data.lines.filter(l=>l.card_id===card);const bank=row.bank_id?candidates.find(l=>(l as typeof l&{bank_transaction_id?:string}).bank_transaction_id===row.bank_id):undefined;
 const merchant=(s:string)=>normal(s.replace(/\b\d{1,3}\/\d{1,3}\b/g,''));
 const related=candidates.find(l=>merchant(l.title)===merchant(row.description)&&(!row.count||row.count===1||l.installment===row.installment));const refund=row.kind==='refund'||row.kind==='credit'?candidates.find(l=>l.line_type==='refund'&&Number(l.amount)===row.amount&&l.charge_date===row.date):undefined;const match=bank??related??refund;
 const invalid=!row.date||!Number.isFinite(row.amount)||row.amount===0||!row.description||row.count<row.installment||row.count>120;
 const comparison=invalid?'Necessita revisão':bank?(Number(bank.amount)===row.amount&&bank.charge_date===row.date?'Já cadastrado':'Divergente'):match?(Number(match.amount)===row.amount?'Possível duplicidade':'Divergente'):'Novo lançamento';
 return {...row,comparison,match_id:match?.id??'',decision:''};
}
