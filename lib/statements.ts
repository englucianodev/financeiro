import type {CreditData} from './credit';
export type StatementRow={original:string;description:string;date:string;amount:number;category:string;installment:number;count:number;total_amount:number|null;bank_id:string;kind:'purchase'|'refund'|'fee'|'credit'|'payment';decision:''|'new'|'link'|'skip';match_id:string;comparison:string};
export function money(text:string){let s=text.replace(/R\$|\s/g,'').replace(/[()]/g,'');if(s.includes(','))s=s.replace(/\./g,'').replace(',','.');const n=Number(s);return Number.isFinite(n)?Math.round(n*100)/100:NaN}
export function statementDate(s:string){s=s.trim();if(/^\d{8,}/.test(s))s=s.slice(0,4)+'-'+s.slice(4,6)+'-'+s.slice(6,8);else if(/^\d{2}\/\d{2}\/\d{4}$/.test(s))s=s.split('/').reverse().join('-');if(!/^\d{4}-\d{2}-\d{2}$/.test(s))return '';const d=new Date(s+'T12:00:00Z');return Number.isFinite(d.getTime())&&d.toISOString().slice(0,10)===s?s:''}
const normal=(s:string)=>s.normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase().replace(/[^a-z0-9]/g,'');
export function makeRow(description:string,date:string,amount:number,bank_id='',type=''):StatementRow{
 const part=description.match(/(?:parc\s*)?\b(\d{1,3})\s*\/\s*(\d{1,3})\b/i),count=part?Number(part[2]):1,installment=part?Number(part[1]):1;
 const d=normal(description+' '+type);const kind=/pagamento|payment|pgtorecebido/.test(d)?'payment':/estorno|refund/.test(d)?'refund':/juros|multa|tarifa|anuidade|fee/.test(d)?'fee':amount<0?'credit':'purchase';
 return {original:description,description,date:statementDate(date),amount,bank_id,kind,category:kind==='fee'?'Encargos':'Outros',count,installment,total_amount:count===1?Math.abs(amount):null,decision:'',match_id:'',comparison:'Necessita revisão'};
}
function csvRows(text:string){const sep=text.split(/\r?\n/)[0].includes(';')?';':',';const rows:string[][]=[];let row:string[]=[],cell='',quoted=false;for(let i=0;i<text.length;i++){const c=text[i];if(c==='"'){if(quoted&&text[i+1]==='"'){cell+='"';i++}else quoted=!quoted}else if(c===sep&&!quoted){row.push(cell);cell=''}else if(c==='\n'&&!quoted){row.push(cell.replace(/\r$/,''));rows.push(row);row=[];cell=''}else cell+=c}if(cell||row.length){row.push(cell);rows.push(row)}return rows}
export function parseStatement(text:string,format:string){const rows:StatementRow[]=[];const warnings:string[]=[];
 if(format==='ofx'){
  const tag=(s:string,t:string)=>s.match(new RegExp('<'+t+'>([^<\\r\\n]+)','i'))?.[1]?.trim()??'';
  for(const block of text.split(/<STMTTRN>/i).slice(1)){rows.push(makeRow(tag(block,'NAME')+' '+tag(block,'MEMO'),tag(block,'DTPOSTED'),-money(tag(block,'TRNAMT')),tag(block,'FITID'),tag(block,'TRNTYPE')))}
 }else if(format==='csv'){
  const table=csvRows(text.replace(/^\uFEFF/,'')),head=(table.shift()??[]).map(normal);
  const index=(terms:string[])=>head.findIndex(h=>terms.includes(h));const di=index(['data','date','datacompra']),de=index(['descricao','description','historico','estabelecimento']),am=index(['valor','amount']),id=index(['id','fitid','identificador']);
  if(di<0||de<0||am<0)warnings.push('CSV precisa de colunas Data, Descrição e Valor.');
  else for(const r of table)if(r.some(Boolean))rows.push(makeRow(r[de]??'',r[di]??'',money(r[am]??''),id>=0?r[id]??'':''));
 }else{
  for(const line of text.split(/\r?\n/)){const m=line.match(/^\s*(\d{2}\/\d{2}(?:\/\d{4})?|\d{4}-\d{2}-\d{2})\s+(.+?)\s+(-?(?:R\$\s*)?[\d.]+,\d{2}|-?\d+\.\d{2})\s*$/);if(m)rows.push(makeRow(m[2],m[1],money(m[3])))}
  warnings.push('PDF/OCR: confira todas as linhas e os totais. Datas sem ano precisam ser completadas; linhas não reconhecidas não são importadas.');
 }
 const metadata={cycle:text.match(/compet[eê]ncia\s*[:\s]+(\d{2}\/\d{4})/i)?.[1]??'',institution:text.match(/\b(Nubank|Ita[uú]|Inter|Santander|Bradesco|Banco do Brasil|C6|Caixa)\b/i)?.[0]??'',due:text.match(/vencimento\s*[:\s]+(\d{2}\/\d{2}\/\d{4})/i)?.[1]??'',closing:text.match(/fechamento\s*[:\s]+(\d{2}\/\d{2}\/\d{4})/i)?.[1]??'',total:text.match(/total\s+(?:da\s+)?fatura\s*[:\sR$]+([\d.]+,\d{2})/i)?.[1]??'',holder:text.match(/titular\s*:\s*([^\n]+)/i)?.[1]??''};
 if(!rows.length)warnings.push('Nenhum lançamento reconhecido com segurança. Revise o arquivo ou use CSV com cabeçalho.');
 return {rows,warnings,metadata};
}
export function compareRow(row:StatementRow,data:CreditData,card:string):StatementRow{
 const candidates=data.lines.filter(l=>l.card_id===card);const bank=row.bank_id?candidates.find(l=>(l as typeof l&{bank_transaction_id?:string}).bank_transaction_id===row.bank_id):undefined;
 const merchant=(s:string)=>normal(s.replace(/\b\d{1,3}\/\d{1,3}\b/g,''));
 const related=candidates.find(l=>merchant(l.title)===merchant(row.description)&&(!row.count||row.count===1||l.installment===row.installment));const match=bank??related;
 const invalid=!row.date||!Number.isFinite(row.amount)||row.amount===0||!row.description||row.count<row.installment||row.count>120;
 const comparison=invalid?'Necessita revisão':bank?(Number(bank.amount)===row.amount&&bank.charge_date===row.date?'Já cadastrado':'Divergente'):match?(Number(match.amount)===row.amount?'Possível duplicidade':'Divergente'):'Novo lançamento';
 return {...row,comparison,match_id:match?.id??'',decision:''};
}
