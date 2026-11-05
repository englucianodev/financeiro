import {test,expect} from '@playwright/test';
const ana='11111111-1111-4111-8111-111111111111',bruno='22222222-2222-4222-8222-222222222222',house='33333333-3333-4333-8333-333333333333';
const user={id:ana,aud:'authenticated',role:'authenticated',email:'ana@example.test',app_metadata:{provider:'email'},user_metadata:{},created_at:'2026-01-01T00:00:00Z'};
const accounts=[{id:'a',name:'Conta Ana',owner_id:ana,balance:1000,is_primary:true},{id:'b',name:'Conta Bruno',owner_id:bruno,balance:2000,is_primary:true}];
async function seed(page,{hasFamily=true,membershipError=null,creationError=null}={}){
 let linked=hasFamily;
 const expires=Math.floor(Date.now()/1000)+3600;
 const token='eyJhbGciOiJIUzI1NiJ9.'+Buffer.from(JSON.stringify({sub:user.id,exp:expires,role:'authenticated'})).toString('base64url')+'.fake';
 const session={access_token:token,refresh_token:'fake',expires_at:expires,expires_in:3600,token_type:'bearer',user};
 await page.context().addCookies([{name:'sb-finance-test-auth-token',value:'base64-'+Buffer.from(JSON.stringify(session)).toString('base64url'),url:'http://127.0.0.1:3100',sameSite:'Lax'}]);
 await page.route('https://finance-test.supabase.co/**',async route=>{const url=new URL(route.request().url());let data=[];
 if(url.pathname.endsWith('/rpc/create_household')){if(creationError)return route.fulfill({status:400,contentType:'application/json',body:JSON.stringify(creationError)});linked=true;return route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(house)});}
 if(url.pathname.endsWith('/household_members')&&membershipError)return route.fulfill({status:403,contentType:'application/json',body:JSON.stringify(membershipError)});
 if(url.pathname.endsWith('/user'))data=user;else if(url.pathname.endsWith('/household_members'))data=url.searchParams.get('select')==='household_id'?(linked?{household_id:house}:null):[{user_id:ana,display_name:'Ana'},{user_id:bruno,display_name:'Bruno'}];else if(url.pathname.endsWith('/financial_accounts'))data=accounts;else if(url.pathname.endsWith('/financial_events'))data=[{id:'expense',title:'Energia',amount:200,paid_amount:0,due_date:'2026-11-06',account_id:'b',owner_id:bruno,status:'pending',kind:'expense',category:'Casa'}];await route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(data)});});
 await page.goto('/');await expect(page.getByRole('heading',{name:'Finanças a Dois',exact:true})).toBeVisible();if(membershipError)await expect(page.getByRole('button',{name:'Tentar novamente'})).toBeVisible();else if(hasFamily)await expect(page.getByRole('heading',{name:'Nova receita ou despesa'})).toBeVisible();else await expect(page.getByRole('button',{name:'Criar família',exact:true})).toBeVisible();
}
test('responsável sugere conta principal e mantém escolha manual após recarga',async({page})=>{
 await seed(page);const form=page.locator('form').filter({has:page.getByPlaceholder('Descrição')});
 await form.locator('select').nth(1).selectOption(bruno);await expect(form.locator('select').nth(2)).toHaveValue('b');
 await form.locator('select').nth(2).selectOption('a');await expect(form.locator('select').nth(2)).toHaveValue('a');
 await page.getByRole('button',{name:'Marcar pago'}).click();await expect(page.getByRole('dialog',{name:'Confirmar movimentação'})).toBeVisible();
 await expect(page.getByLabel('Valor efetivo')).toHaveValue('200');
 const dialog=page.getByRole('dialog',{name:'Confirmar movimentação'});
 const request=page.waitForRequest(r=>r.url().endsWith('/rpc/pay_event'));
 await dialog.getByRole('button',{name:'Confirmar',exact:true}).click();
 const payload=(await request).postDataJSON();
 expect(payload).toMatchObject({p_event:'expense',p_account:'b',p_amount:200,p_expected_paid:0});
 await expect(dialog).toBeHidden();
 await expect(form.locator('select').nth(2)).toHaveValue('a');
});
test('novo cadastro de conta recebe nova chave após sucesso',async({page})=>{
 await seed(page);
 const form=page.locator('form').filter({has:page.getByPlaceholder('Nome da conta')});
 await form.getByPlaceholder('Nome da conta').fill('Reserva');
 await form.getByPlaceholder('Saldo inicial').fill('100');
 const keys=[];
 for(let i=0;i<2;i++){
  const request=page.waitForRequest(r=>r.url().endsWith('/rpc/create_account'));
  await form.getByRole('button',{name:'Salvar conta'}).click();
  keys.push((await request).postDataJSON().p_id);
  await expect(form.getByRole('button',{name:'Salvar conta'})).toBeEnabled();
 }
 expect(keys[0]).not.toBe(keys[1]);
});
test('calendário, relatórios, simulador e tema em celular',async({page})=>{
 await page.setViewportSize({width:390,height:844});await seed(page);
 await expect(page.getByRole('heading',{name:/Calendário/})).toBeVisible();
 await page.getByRole('button',{name:'Relatórios',exact:true}).click();await expect(page.getByRole('heading',{name:'Relatório por período'})).toBeVisible();
 await page.getByRole('button',{name:'Simulador',exact:true}).click();await expect(page.getByRole('heading',{name:'Simulador de 365 dias'})).toBeVisible();
 await page.getByRole('button',{name:'Alternar tema'}).click();await expect(page.locator('html')).toHaveClass('dark');
 await expect(page.locator('body')).toHaveJSProperty('scrollWidth',390);
});

test('criação da família abre o painel',async({page})=>{
 await seed(page,{hasFamily:false});
 await page.getByRole('button',{name:'Criar família',exact:true}).click();
 await expect(page.getByRole('heading',{name:'Nova receita ou despesa'})).toBeVisible();
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
 await expect(page.getByRole('heading',{name:'Nova receita ou despesa'})).toBeVisible();
});
