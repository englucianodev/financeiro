// Reconstruct reading order before parsing bank statements with parallel columns.
export type PdfTextItem={str:string;transform:number[]};
export function statementPageText(items:PdfTextItem[]){
 const visible=items.filter(i=>i.str.trim());
 const headers=visible.filter(i=>i.str.trim()==='VALOR EM R$');
 const hasTable=visible.some(i=>i.str.trim()==='ESTABELECIMENTO');
 const boundary=hasTable&&headers.length?Math.min(...headers.map(i=>i.transform[4]))+52:null;
 const columns=boundary===null?[visible]:[visible.filter(i=>i.transform[4]<boundary),visible.filter(i=>i.transform[4]>=boundary)];
 return columns.map(column=>{
  const lines:{y:number;items:PdfTextItem[]}[]=[];
  for(const item of [...column].sort((a,b)=>b.transform[5]-a.transform[5]||a.transform[4]-b.transform[4])){
   let line=lines.find(l=>Math.abs(l.y-item.transform[5])<2);
   if(!line){line={y:item.transform[5],items:[]};lines.push(line)}
   line.items.push(item);
  }
  return lines.map(line=>{
   const ordered=line.items.sort((a,b)=>a.transform[4]-b.transform[4]);
   return ordered.map((item,index)=>{
    const next=ordered[index+1];
    // Keep merchant suffixes separate from amounts, while preserving split minus signs.
    const sign=item.str.trim()==='-'&&next&&next.transform[4]-item.transform[4]<20&&/^(?:R\$|[\d.]+[,.]\d{2})$/.test(next.str.trim());
    return item.str+(sign?'':'\t');
   }).join('').trim();
  }).join('\n');
 }).join('\n\f\n')+'\n\f\n';
}
