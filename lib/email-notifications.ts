export function nationalHoliday(date:string){const y=Number(date.slice(0,4)),md=date.slice(5);if(['01-01','04-21','05-01','09-07','10-12','11-02','11-15','11-20','12-25'].includes(md))return true;
 const a=y%19,b=Math.floor(y/100),c=y%100,d=Math.floor(b/4),e=b%4,f=Math.floor((b+8)/25),g=Math.floor((b-f+1)/3),h=(19*a+b-d-g+15)%30,i=Math.floor(c/4),k=c%4,l=(32+2*e+2*i-h-k)%7,m=Math.floor((a+11*h+22*l)/451),month=Math.floor((h+l-7*m+114)/31),day=(h+l-7*m+114)%31+1;
 return new Date(Date.UTC(y,month-1,day-2)).toISOString().slice(0,10)===date;
}
export function dueSlots(settings:{timezone:string;weekdays:number[];holidays:string[];skip_holidays:boolean;morning:string;evening:string},now=new Date()){
 const local=new Intl.DateTimeFormat('sv-SE',{timeZone:settings.timezone,year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).format(now),date=local.slice(0,10),minute=Number(local.slice(11,13))*60+Number(local.slice(14,16)),weekday=new Date(date+'T12:00:00Z').getUTCDay();
 if(!settings.weekdays.includes(weekday)||(settings.skip_holidays&&(nationalHoliday(date)||settings.holidays.includes(date))))return {date,slots:[]};
 return {date,slots:['morning','evening'].filter(slot=>{const [h,m]=(settings[slot as 'morning'|'evening']).split(':').map(Number);const delta=minute-(h*60+m);return delta>=0&&delta<10})};
}
export type PendingEmail={title:string;owner_id:string;amount:number;due_date:string};
export function emailText(rows:PendingEmail[],members:{user_id:string;display_name:string}[],date:string,url:string){const money=(v:number)=>v.toLocaleString('pt-BR',{style:'currency',currency:'BRL'});const sum=(r:PendingEmail[])=>r.reduce((s,e)=>s+Math.round(Number(e.amount)*100),0)/100;
 return 'Pendências financeiras · '+date+'\n\n'+rows.map(r=>`${r.title} · ${members.find(m=>m.user_id===r.owner_id)?.display_name??'Responsável'} · ${money(Number(r.amount))} · Vencimento ${r.due_date} · ${r.due_date<date?'Em atraso':'Vence hoje'}`).join('\n')+'\n\nTotal pendente: '+money(sum(rows))+'\n'+members.map(m=>m.display_name+': '+money(sum(rows.filter(r=>r.owner_id===m.user_id)))).join('\n')+'\nAtrasadas: '+money(sum(rows.filter(r=>r.due_date<date)))+'\n\nAcessar: '+url;
}
