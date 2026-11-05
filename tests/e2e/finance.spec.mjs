import {test,expect} from '@playwright/test';
const ana='11111111-1111-4111-8111-111111111111',bruno='22222222-2222-4222-8222-222222222222',house='33333333-3333-4333-8333-333333333333';
const user={id:ana,aud:'authenticated',role:'authenticated',email:'ana@example.test',app_metadata:{provider:'email'},user_metadata:{},created_at:'2026-01-01T00:00:00Z'};
const accounts=[{id:'a',name:'Conta Ana',owner_id:ana,balance:1000,is_primary:true},{id:'b',name:'Conta Bruno',owner_id:bruno,balance:2000,is_primary:true}];
async function seed(page){
 await page.addInitScript(({user})=>{const token='eyJhbGciOiJIUzI1NiJ9.'+btoa(JSON.stringify({sub:user.id,exp:Math.floor(Date.now()/1000)+3600,role:'authenticated'}))+'.fake';localStorage.setItem('sb-finance-test-auth-token',JSON.stringify({access_token:token,refresh_token:'fake',expires_at:Math.floor(Date.now()/1000)+3600,expires_in:3600,token_type:'bearer',user}));},{user});
 await page.route('https://finance-test.supabase.co/**',async route=>{const url=new URL(route.request().url());let data=[];if(url.pathname.endsWith('/user'))data=user;else if(url.pathname.endsWith('/household_members'))data=url.searchParams.get('select')==='household_id'?{household_id:house}:[{user_id:ana,display_name:'Ana'},{user_id:bruno,display_name:'Bruno'}];else if(url.pathname.endsWith('/financial_accounts'))data=accounts;else if(url.pathname.endsWith('/financial_events'))data=[{id:'expense',title:'Energia',amount:200,paid_amount:0,due_date:'2026-11-06',account_id:'b',owner_id:bruno,status:'pending',kind:'expense',category:'Casa'}];await route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(data)});});
 await page.goto('/');await expect(page.getByRole('heading',{name:'Finanças a Dois',exact:true})).toBeVisible();await expect(page.getByRole('heading',{name:'Nova receita ou despesa'})).toBeVisible();
}
test('responsável sugere conta principal e mantém escolha manual após recarga',async({page})=>{
 await seed(page);const form=page.locator('form').filter({has:page.getByPlaceholder('Descrição')});
 await form.locator('select').nth(1).selectOption(bruno);await expect(form.locator('select').nth(2)).toHaveValue('b');
 await form.locator('select').nth(2).selectOption('a');await expect(form.locator('select').nth(2)).toHaveValue('a');
 await page.getByRole('button',{name:'Marcar pago'}).click();await expect(page.getByRole('dialog',{name:'Confirmar movimentação'})).toBeVisible();
 await expect(page.getByLabel('Valor efetivo')).toHaveValue('200');
});
test('calendário, relatórios, simulador e tema em celular',async({page})=>{
 await page.setViewportSize({width:390,height:844});await seed(page);
 await expect(page.getByRole('heading',{name:/Calendário/})).toBeVisible();
 await page.getByRole('button',{name:'Relatórios',exact:true}).click();await expect(page.getByRole('heading',{name:'Relatório por período'})).toBeVisible();
 await page.getByRole('button',{name:'Simulador',exact:true}).click();await expect(page.getByRole('heading',{name:'Simulador de 365 dias'})).toBeVisible();
 await page.getByRole('button',{name:'Alternar tema'}).click();await expect(page.locator('html')).toHaveClass('dark');
 await expect(page.locator('body')).toHaveJSProperty('scrollWidth',390);
});
