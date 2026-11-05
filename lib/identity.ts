export function firstName(value:string){
 const clean=value.trim();
 if(!clean||clean.includes('@'))return 'Participante';
 return clean.split(/\s+/)[0];
}
export function familyTitle(members:{display_name:string}[]){
 const names=members.map(m=>firstName(m.display_name));
 return names.length?'Finanças de '+new Intl.ListFormat('pt-BR',{style:'long',type:'conjunction'}).format(names):'Suas finanças';
}
export const palette=['#6366f1','#8b5cf6','#f97316','#0284c7','#0d9488','#ca8a04','#e11d48'];
export const defaults={income:['Salário','Aluguel recebido','Serviços','Rendimentos','Reembolso','Venda','Outros'],expense:['Alimentação','Supermercado','Transporte','Combustível','Moradia','Energia','Água','Internet','Condomínio','Saúde','Educação','Lazer','Cartão de crédito','Financiamento','Impostos','Manutenção','Outros']};
