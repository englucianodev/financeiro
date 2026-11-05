import {test,expect} from '@playwright/test';
const ana='11111111-1111-4111-8111-111111111111',bruno='22222222-2222-4222-8222-222222222222',house='33333333-3333-4333-8333-333333333333';
const user={id:ana,aud:'authenticated',role:'authenticated',email:'ana@example.test',app_metadata:{provider:'email'},user_metadata:{},created_at:'2026-01-01T00:00:00Z'};
const accounts=[{id:'a',name:'Conta Ana',owner_id:ana,balance:1000,is_primary:true},{id:'b',name:'Conta Bruno',owner_id:bruno,balance:2000,is_primary:true},{id:'c',name:'Outra Bruno',owner_id:bruno,balance:0,is_primary:false}];
async function seed(page,{hasFamily=true,membershipError=null,creationError=null,eventRows=null}={}){
 let linked=hasFamily;
 const expires=Math.floor(Date.now()/1000)+3600;
 const token='eyJhbGciOiJIUzI1NiJ9.'+Buffer.from(JSON.stringify({sub:user.id,exp:expires,role:'authenticated'})).toString('base64url')+'.fake';
 const session={access_token:token,refresh_token:'fake',expires_at:expires,expires_in:3600,token_type:'bearer',user};
 await page.context().addCookies([{name:'sb-finance-test-auth-token',value:'base64-'+Buffer.from(JSON.stringify(session)).toString('base64url'),url:'http://127.0.0.1:3100',sameSite:'Lax'}]);
 await page.route('https://finance-test.supabase.co/**',async route=>{const url=new URL(route.request().url());let data=[];
 if(url.pathname.endsWith('/rpc/create_household')){if(creationError)return route.fulfill({status:400,contentType:'application/json',body:JSON.stringify(creationError)});linked=true;return route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(house)});}
 if(url.pathname.endsWith('/household_members')&&membershipError)return route.fulfill({status:403,contentType:'application/json',body:JSON.stringify(membershipError)});
 if(url.pathname.endsWith('/user'))data=user;else if(url.pathname.endsWith('/household_members'))data=url.searchParams.get('select')==='household_id'?(linked?{household_id:house}:null):[{user_id:ana,display_name:'Ana'},{user_id:bruno,display_name:'Bruno'}];else if(url.pathname.endsWith('/categories'))data=[{id:'expense-default',name:'Outros',kind:'expense',color:'#e11d48',icon:'wallet',active:true},{id:'salary-default',name:'Salário',kind:'income',color:'#0284c7',icon:'wallet',active:true}];else if(url.pathname.endsWith('/financial_accounts'))data=accounts;else if(url.pathname.endsWith('/financial_events'))data=eventRows??[{id:'expense',title:'Energia',amount:200,paid_amount:0,due_date:'2026-11-06',account_id:'b',owner_id:bruno,status:'pending',kind:'expense',category:'Casa'}];await route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(data)});});
 await page.goto('/');if(hasFamily)await expect(page.getByRole('heading',{name:membershipError?'Finanças a Dois':'Finanças de Ana e Bruno',exact:true})).toBeVisible();if(membershipError)await expect(page.getByRole('button',{name:'Tentar novamente'})).toBeVisible();else if(hasFamily)await expect(page.getByText('Saldo real disponível',{exact:true})).toBeVisible();else {await expect(page.getByRole('button',{name:'Criar família',exact:true})).toBeVisible();await page.getByPlaceholder('Nome de exibição').fill('Ana');}
}
test('responsável só vê suas contas e mantém escolha manual',async({page})=>{
 await seed(page);await page.getByRole('tab',{name:'Mais',exact:true}).click();const form=page.locator('#new-entry');
 await form.getByLabel('Responsável',{exact:true}).selectOption(bruno);await expect(form.getByLabel('Conta de origem ou destino')).toHaveValue('b');await expect(form.getByLabel('Conta de origem ou destino').locator('option[value="a"]')).toHaveCount(0);
 await form.getByLabel('Conta de origem ou destino').selectOption('c');
 await page.getByRole('tab',{name:'Pendências',exact:true}).click();await page.getByRole('button',{name:'Marcar pago'}).click();
 const dialog=page.getByRole('dialog',{name:'Confirmar movimentação'});await expect(dialog.getByLabel('Valor efetivo')).toHaveValue('200');const request=page.waitForRequest(r=>r.url().endsWith('/rpc/pay_event'));await dialog.getByRole('button',{name:'Confirmar',exact:true}).click();expect((await request).postDataJSON()).toMatchObject({p_event:'expense',p_account:'b',p_amount:200});await expect(dialog).toBeHidden();await page.getByRole('tab',{name:'Mais',exact:true}).click();await expect(form.getByLabel('Conta de origem ou destino')).toHaveValue('c');
});
test('cadastro e edição de contas ficam na aba Contas',async({page})=>{
 await seed(page);await expect(page.getByRole('heading',{name:'Contas',exact:true})).toBeHidden();await page.getByRole('tab',{name:'Contas',exact:true}).click();await expect(page.getByRole('button',{name:'Tornar principal'})).toHaveCount(0);
 await page.getByRole('button',{name:'Adicionar conta',exact:true}).click();const form=page.getByRole('dialog',{name:'Nova conta',exact:true}).locator('form');await form.getByPlaceholder('Nome da conta').fill('Reserva');await form.getByPlaceholder('Saldo inicial').fill('100');await form.getByLabel('Finalidade').selectOption('recurring');const request=page.waitForRequest(r=>r.url().endsWith('/rpc/save_account'));await form.getByRole('button',{name:'Salvar conta'}).click();expect((await request).postDataJSON()).toMatchObject({p_name:'Reserva',p_type:'recurring'});await expect(form).toBeHidden();
 await page.getByRole('button',{name:'Editar conta Conta Ana',exact:true}).click();await page.getByRole('dialog',{name:'Editar conta',exact:true}).getByPlaceholder('Nome da conta').fill('Conta Ana Editada');const edit=page.waitForRequest(r=>r.url().endsWith('/rpc/save_account'));await page.getByRole('button',{name:'Salvar conta',exact:true}).click();expect((await edit).postDataJSON()).toMatchObject({p_name:'Conta Ana Editada',p_account:'a',p_expected_balance:1000});
});
test('calendário, relatórios, simulador e tema em celular',async({page})=>{
 await page.setViewportSize({width:390,height:844});await seed(page);
 await page.getByRole('tab',{name:'Calendário',exact:true}).click();await expect(page.getByRole('heading',{name:/Calendário/})).toBeVisible();await page.getByRole('tab',{name:'Mais',exact:true}).click();await page.getByRole('button',{name:'Planejamento',exact:true}).click();
 await page.getByRole('button',{name:'Relatórios',exact:true}).click();await expect(page.getByRole('heading',{name:'Relatório por período'})).toBeVisible();
 await page.getByRole('button',{name:'Planejamento',exact:true}).click();await page.getByRole('button',{name:'Simulador',exact:true}).click();await expect(page.getByRole('heading',{name:'Simulador por data'})).toBeVisible();
 await page.getByRole('button',{name:'Alternar tema'}).click();await expect(page.locator('html')).toHaveClass('dark');
 await expect(page.locator('body')).toHaveJSProperty('scrollWidth',390);
});

test('criação da família abre o painel',async({page})=>{
 await seed(page,{hasFamily:false});
 await page.getByRole('button',{name:'Criar família',exact:true}).click();
 await expect(page.getByText('Saldo real disponível',{exact:true})).toBeVisible();
});
test('erro do Supabase é exibido com mensagem legível',async({page})=>{
 await seed(page,{hasFamily:false,creationError:{code:'42501',message:'Permissão negada para criar família'}});
 await page.getByRole('button',{name:'Criar família',exact:true}).click();
 await expect(page.getByRole('main').getByRole('alert')).toHaveText('Permissão negada para criar família');
 await expect(page.getByText('[object Object]',{exact:true})).toHaveCount(0);
});
test('função ausente orienta atualizar o banco',async({page})=>{
 await seed(page,{hasFamily:false,creationError:{code:'PGRST202',message:'Could not find the function public.create_household'}});
 await page.getByRole('button',{name:'Criar família',exact:true}).click();
 await expect(page.getByRole('main').getByRole('alert')).toContainText('Aplique as migrations pendentes no Supabase');
});
test('falha de consulta não oferece criar outra família e permite tentar novamente',async({page})=>{
 await seed(page,{membershipError:{code:'42501',message:'Permissão negada para consultar família'}});
 await expect(page.getByRole('main').getByRole('alert')).toContainText('Permissão negada para consultar família');
 await expect(page.getByRole('button',{name:'Criar família',exact:true})).toHaveCount(0);
 await page.route('**/rest/v1/household_members?**',route=>{const url=new URL(route.request().url());return route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(url.searchParams.get('select')==='household_id'?{household_id:house}:[{user_id:ana,display_name:'Ana'}])})});
 await page.getByRole('button',{name:'Tentar novamente'}).click();
 await expect(page.getByText('Saldo real disponível',{exact:true})).toBeVisible();
});

test('projeção navega seis períodos acumulados',async({page})=>{
 await seed(page);const chart=page.locator('#projection');
 await expect(chart.getByRole('button',{name:'Período anterior'})).toBeDisabled();
 await expect(chart).toContainText('dias 1 a 30');
 for(let i=0;i<5;i++)await chart.getByRole('button',{name:'Próximo período'}).click();
 await expect(chart).toContainText('dias 151 a 180');
 await expect(chart.getByRole('button',{name:'Próximo período'})).toBeDisabled();
});
test('salário gera previsão mensal sem débito bancário',async({page})=>{
 await seed(page);await page.getByRole('tab',{name:'Mais',exact:true}).click();await page.getByRole('button',{name:'Cadastrar salário',exact:true}).click();
 const form=page.locator('#new-entry');await form.getByPlaceholder('Descrição').fill('Salário PM');await form.getByPlaceholder('Valor',{exact:true}).fill('6000');
 const request=page.waitForRequest(r=>r.url().endsWith('/rpc/schedule_events'));await form.getByRole('button',{name:'Salvar lançamento'}).click();
 expect((await request).postDataJSON()).toMatchObject({p_kind:'income',p_unit:'months',p_every:1,p_amount:6000,p_category:'Salário'});
});
test('cores e categorias são persistidas e simulador aceita data',async({page})=>{
 await page.setViewportSize({width:390,height:844});await seed(page);
 await page.getByRole('tab',{name:'Mais',exact:true}).click();
 await page.getByRole('button',{name:'Personalização',exact:true}).click();const prefs=page.locator('#preferences');await prefs.getByLabel('Categoria',{exact:true}).fill('Animais');const created=page.waitForRequest(r=>r.url().includes('/rest/v1/categories')&&r.method()==='POST');await prefs.getByRole('button',{name:'Criar categoria'}).click();expect((await created).postDataJSON()).toMatchObject({name:'Animais'});
 await page.getByRole('button',{name:'Planejamento',exact:true}).click();await page.getByRole('button',{name:'Simulador',exact:true}).click();await expect(page.getByLabel('Simular até a data')).toBeVisible();
 await page.evaluate(()=>window.scrollTo(0,0));await expect(page.locator('body')).toHaveJSProperty('scrollWidth',390);await page.screenshot({path:'test-results/dashboard-mobile.png'});
});

test('celular mantém sessão, aba e período após atualizar',async({page})=>{
 await page.setViewportSize({width:390,height:844});await seed(page);
 await page.locator('#projection').getByRole('button',{name:'Próximo período'}).click();
 await page.getByRole('tab',{name:'Mais',exact:true}).click();await page.getByRole('button',{name:'Planejamento',exact:true}).click();await page.getByRole('button',{name:'Simulador',exact:true}).click();
 const selectedDate=new Date((await page.getByLabel('Simular até a data').inputValue())+'T12:00:00Z');selectedDate.setUTCDate(selectedDate.getUTCDate()-7);const date=selectedDate.toISOString().slice(0,10);await page.getByLabel('Simular até a data').fill(date);
 // A reload must restore the existing cookie without needing /auth/v1/user.
 await page.route('**/auth/v1/user',route=>route.abort('failed'));
 await page.reload();
 await expect(page.getByRole('heading',{name:'Finanças de Ana e Bruno',exact:true})).toBeVisible();
 await expect(page.getByRole('heading',{name:'Simulador por data'})).toBeVisible();
 await expect(page.getByLabel('Simular até a data')).toHaveValue(date);
 await expect(page.locator('#projection')).toContainText('dias 31 a 60');
 await expect(page.getByRole('button',{name:'Entrar',exact:true})).toHaveCount(0);
 await page.getByRole('button',{name:'Sair',exact:true}).click();
 await expect(page.getByRole('button',{name:'Entrar',exact:true})).toBeVisible();
 await page.reload();await expect(page.getByRole('button',{name:'Entrar',exact:true})).toBeVisible();
});
test('restauração lenta não mostra login prematuramente',async({page})=>{
 await seed(page);
 await page.addInitScript(()=>{window.__showedLogin=false;const observe=new MutationObserver(()=>{if(Array.from(document.querySelectorAll('button')).some(b=>b.textContent==='Entrar'))window.__showedLogin=true});observe.observe(document,{subtree:true,childList:true})});
 await page.reload();await expect(page.getByRole('heading',{name:'Finanças de Ana e Bruno',exact:true})).toBeVisible();
 expect(await page.evaluate(()=>window.__showedLogin)).toBe(false);
});

const currentDate=()=>new Intl.DateTimeFormat('en-CA',{timeZone:'America/Fortaleza',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
const dayOffset=n=>{const d=new Date(currentDate()+'T12:00:00Z');d.setUTCDate(d.getUTCDate()+n);return d.toISOString().slice(0,10)};
const movement=(id,title,days,status='pending',kind='expense')=>({id,title,due_date:dayOffset(days),status,kind,amount:100,paid_amount:status==='settled'?100:0,owner_id:ana,account_id:'a',category:'Moradia'});
test('abas isolam conteúdo, pendências filtram datas e exportam checklist',async({page})=>{
 await page.setViewportSize({width:390,height:844});await seed(page,{eventRows:[movement('next','Conta próxima',1),movement('far','Conta distante',20),movement('late','Atrasada recente',-1),movement('paid','Já paga recente',-1,'settled'),movement('old','Já paga antiga',-10,'settled')]});
 const home=page.locator('#screen-home');await expect(home.locator('#urgent').getByText('Atrasada recente',{exact:true})).toBeVisible();await expect(home.getByText('Já paga recente',{exact:true})).toBeVisible();await expect(home.getByText('Conta próxima',{exact:true})).toHaveCount(0);await expect(page.locator('#screen-accounts')).toBeHidden();
 await page.getByRole('tab',{name:'Pendências',exact:true}).click();await expect(home).toBeHidden();const pending=page.locator('#screen-pending');await expect(pending.getByText('Conta próxima',{exact:true})).toBeVisible();await expect(pending.getByText('Conta distante',{exact:true})).toHaveCount(0);await pending.getByRole('button',{name:/Ver dias seguintes/}).click();await expect(pending.getByText('Conta distante',{exact:true})).toBeVisible();await pending.getByLabel('Status',{exact:true}).selectOption('late');await expect(pending.getByText('Atrasada recente',{exact:true})).toBeVisible();await expect(pending.getByText('Conta próxima',{exact:true})).toHaveCount(0);
 const download=page.waitForEvent('download');await pending.getByRole('button',{name:'Baixar checklist',exact:true}).click();expect((await download).suggestedFilename()).toBe('despesas-'+currentDate().slice(0,7)+'.txt');
 await page.getByRole('tab',{name:'Calendário',exact:true}).click();await expect(page.locator('#screen-planning .calendar-grid')).not.toContainText('R$');await expect(page.locator('body')).toHaveJSProperty('scrollWidth',390);await page.screenshot({path:'test-results/calendar-mobile.png'});
});
test('recebimento automático permite corrigir valor e data',async({page})=>{
 await seed(page,{eventRows:[movement('salary','Salário recebido',-1,'settled','income')]});await page.locator('#screen-home').getByRole('button',{name:'Corrigir recebimento'}).click();const dialog=page.getByRole('dialog',{name:'Corrigir recebimento',exact:true});await dialog.getByLabel('Valor recebido').fill('120');const request=page.waitForRequest(r=>r.url().endsWith('/rpc/correct_income'));await dialog.getByRole('button',{name:'Salvar correção'}).click();expect((await request).postDataJSON()).toMatchObject({p_event:'salary',p_amount:120,p_expected:100,p_date:dayOffset(-1)});await expect(dialog).toBeHidden();
});

test('início mostra atrasadas e de hoje sem filtros e menu rápido só tem três ações',async({page})=>{
 await seed(page,{eventRows:[movement('due','Vencendo hoje',0),movement('old','Atrasada há dez dias',-10),movement('later','Somente amanhã',1)]});const urgent=page.locator('#urgent');await expect(urgent.getByText('Vencendo hoje',{exact:true})).toBeVisible();await expect(urgent.getByText('Atrasada há dez dias',{exact:true})).toBeVisible();await expect(urgent.getByText('Somente amanhã',{exact:true})).toHaveCount(0);await expect(urgent.locator('input,select')).toHaveCount(0);
 await page.getByRole('button',{name:'Nova movimentação'}).click();await expect(page.locator('.quick-menu').getByRole('button')).toHaveText(['Despesa','Receita','Transferência']);await page.locator('.quick-menu').getByRole('button',{name:'Transferência',exact:true}).click();await expect(page.getByRole('tab',{name:'Contas',exact:true})).toHaveAttribute('aria-selected','true');await expect(page.getByRole('heading',{name:'Transferência interna'})).toBeVisible();await expect(page.locator('#screen-preferences').getByRole('heading',{name:'Transferência interna'})).toHaveCount(0);
});
test('filtro soma saldo pendente e lista meses em ordem',async({page})=>{
 await seed(page,{eventRows:[movement('first','Conta A',0),{...movement('second','Conta B',2),paid_amount:25},movement('far','Outro mês',100)]});await page.getByRole('tab',{name:'Pendências',exact:true}).click();const pending=page.locator('#screen-pending');await pending.getByPlaceholder('Nome ou categoria').fill('Conta');await expect(pending.locator('.filtered-totals')).toContainText('R$ 175,00');const values=await pending.getByLabel('Mês/ano').locator('option').evaluateAll(options=>options.map(o=>o.value).filter(Boolean));expect(values).toEqual([...values].sort());expect(values.length).toBeGreaterThan(1);
});
test('edição de conta abre modal com foco e hover estável',async({page})=>{
 await seed(page);await page.getByRole('tab',{name:'Contas',exact:true}).click();const button=page.getByRole('button',{name:'Editar conta Conta Ana',exact:true});await button.hover();const before=await button.boundingBox();await button.hover();const after=await button.boundingBox();expect(Math.abs(before.y-after.y)).toBeLessThan(.5);await page.setViewportSize({width:390,height:844});await button.click();const dialog=page.getByRole('dialog',{name:'Editar conta',exact:true});await expect(dialog).toBeVisible();await expect(dialog.getByPlaceholder('Nome da conta')).toBeFocused();await page.screenshot({path:'test-results/account-edit-mobile.png'});await page.keyboard.press('Escape');await expect(dialog).toBeHidden();
});
test('categorias padrão podem ser editadas e excluídas sem reaparecer no cadastro',async({page})=>{
 await seed(page);let rows=[{id:'expense-default',name:'Outros',kind:'expense',color:'#e11d48',icon:'wallet',active:true}];await page.route('**/rest/v1/categories?**',async route=>{if(route.request().method()==='PATCH'){rows=rows.map(r=>({...r,...route.request().postDataJSON()}));return route.fulfill({status:204})}return route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(rows.filter(r=>!r.deleted_at))})});await page.route('**/rest/v1/rpc/delete_category',route=>{rows=rows.map(r=>({...r,active:false,deleted_at:new Date().toISOString()}));return route.fulfill({status:200,contentType:'application/json',body:'null'})});
 await page.getByRole('tab',{name:'Mais',exact:true}).click();await page.getByRole('button',{name:'Personalização',exact:true}).click();await page.getByRole('button',{name:'Editar categoria Outros despesa'}).click();const prefs=page.locator('#preferences');await prefs.getByLabel('Categoria',{exact:true}).fill('Casa');await prefs.getByRole('button',{name:'Salvar categoria'}).click();await expect(prefs.getByRole('button',{name:'Excluir categoria Casa despesa'})).toBeVisible();await prefs.getByRole('button',{name:'Excluir categoria Casa despesa'}).click();await expect(prefs.getByRole('button',{name:'Excluir categoria Casa despesa'})).toHaveCount(0);await page.getByRole('button',{name:'Lançamentos',exact:true}).click();await expect(page.locator('#new-entry select[name="category"] option')).toHaveCount(0);
});
test('alteração de senha autenticada usa API Supabase',async({page})=>{
 await seed(page);await page.getByRole('tab',{name:'Mais',exact:true}).click();await page.getByRole('button',{name:'Personalização',exact:true}).click();await page.getByRole('button',{name:'Alterar senha',exact:true}).click();await page.getByLabel('Senha atual',{exact:true}).fill('SenhaAtual123!');await page.getByLabel('Nova senha',{exact:true}).fill('NovaSenha123!');await page.getByLabel('Confirmar nova senha',{exact:true}).fill('NovaSenha123!');const request=page.waitForRequest(r=>r.method()==='PUT'&&r.url().endsWith('/auth/v1/user'));await page.getByRole('button',{name:'Salvar nova senha'}).click();expect((await request).postDataJSON()).toMatchObject({password:'NovaSenha123!',current_password:'SenhaAtual123!'});await expect(page.getByText('Senha alterada com sucesso.',{exact:true})).toBeVisible();
});
