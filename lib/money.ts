export const brl=(n:number)=>new Intl.NumberFormat("pt-BR",{style:"currency",currency:"BRL"}).format(n);
export const today=()=>new Intl.DateTimeFormat("en-CA",{timeZone:"America/Fortaleza",year:"numeric",month:"2-digit",day:"2-digit"}).format(new Date());
export function project(accounts:{id:string;name:string;balance:number}[],events:{id:string;account_id:string;amount:number;due_date:string;status:string;credit_state?:string}[],days=90,current=today()){
 if(!Number.isInteger(days)||days<0||days>365)throw new Error("Horizonte inválido");
 const balances=Object.fromEntries(accounts.map(a=>[a.id,Math.round(Number(a.balance)*100)]));
 const result=[] as {date:string;total:number;byAccount:Record<string,number>}[];
 for(let i=0;i<=days;i++){
 const d=new Date(current+"T12:00:00Z");d.setUTCDate(d.getUTCDate()+i);const date=d.toISOString().slice(0,10);
 for(const e of events)if((!e.credit_state||e.credit_state==='none')&&e.status==="pending"&&(e.due_date===date||(i===0&&e.due_date<date))&&e.account_id in balances)balances[e.account_id]+=Math.round(Number(e.amount)*100);
 result.push({date,total:Object.values(balances).reduce((a,b)=>a+b,0)/100,byAccount:Object.fromEntries(Object.entries(balances).map(([id,value])=>[id,value/100]))});
 }return result;
}
export function transferSuggestions(accounts:{id:string;name:string;balance:number}[],projection:{byAccount:Record<string,number>}[]){
 const minimum=(id:string)=>Math.min(...projection.map(p=>p.byAccount[id]??0));
 const donors=accounts.map(a=>({...a,available:Math.max(0,Math.round(Math.min(a.balance,minimum(a.id))*100))}));
 const suggestions:{from:string;to:string;amount:number}[]=[];
 for(const target of accounts){let needed=Math.max(0,-Math.round(minimum(target.id)*100));for(const donor of donors){if(donor.id===target.id||needed===0)continue;const amount=Math.min(needed,donor.available);if(amount>0){suggestions.push({from:donor.id,to:target.id,amount:amount/100});donor.available-=amount;needed-=amount;}}}
 return suggestions;
}

export type ScheduledTransfer={id:string;from_account:string;to_account:string;amount:number;due_date:string;status:string};
export function transferFlows(transfers:ScheduledTransfer[]){return transfers.flatMap(t=>[{id:t.id,account_id:t.from_account,amount:-Number(t.amount),due_date:t.due_date,status:t.status},{id:t.id+'-to',account_id:t.to_account,amount:Number(t.amount),due_date:t.due_date,status:t.status}])}
