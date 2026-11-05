# Finanças a Dois — MVP inicial

Aplicação Next.js + Supabase para duas pessoas gerenciarem contas, receitas e despesas avulsas, pagamentos, transferências internas e previsão diária de saldos por conta (90 dias).

## Iniciar
1. Instale Node.js 20 ou superior.
2. Execute `npm install`.
3. Copie `.env.example` para `.env.local` e preencha a URL e a chave pública do Supabase.
4. No Supabase SQL Editor, **revise** e execute `supabase/migrations/001_initial.sql` em projeto de testes primeiro.
5. No Supabase Auth, configure URL do site e redirecionamentos; habilite autenticação por e-mail.
6. Execute `npm run dev` e abra http://localhost:3000.
7. Crie a primeira conta, crie a família e compartilhe o código de convite com a segunda pessoa.
8. Para deploy, importe o repositório na Vercel e configure as duas variáveis de ambiente.

## Implementado
- Autenticação por e-mail/senha (Supabase Auth).
- Núcleo familiar compartilhado, com dois membros.
- Contas bancárias individuais, saldo e preferência de conta principal.
- Lançamentos avulsos de receita/despesa, atribuição ao responsável e conta prevista.
- Confirmação transacional de pagamentos/recebimentos.
- Transferências internas com movimentação entre saldos, sem alterar saldo consolidado.
- Projeção diária de 90 dias, alertas de saldo negativo e menor saldo por conta.
- RLS para isolamento por núcleo familiar.

## Ainda NÃO implementado (para o Codex)
- Recorrências e edição de ocorrências, cartões e faturas parceladas.
- Investimentos, imóveis, calendário, relatórios e simulador.
- Convites seguros com token expirável: o código de família é apenas provisório e **não deve ser usado com dados reais**.
- Auditoria completa, estorno, conciliação e testes automatizados.
- Lançamentos já pagos no cadastro, agendamento de transferências e troca de conta no modal de pagamento.
- Projeção de 6/12 meses e lógica de reserva financeira.
- Contabilidade com livro-razão imutável (o MVP guarda saldo materializado; evoluir antes de produção).
- Paginação, regras de valores variáveis, validação de formulários com Zod.

## Atenção
Este é um protótipo funcional inicial, **não um produto pronto para dados financeiros reais**. Use contas e dados fictícios até passar por revisão de segurança, migrações, testes e auditoria de lançamentos. A projeção parte do saldo real atual e considera apenas lançamentos pendentes com vencimento futuro; lançamentos pendentes vencidos precisam de tratamento de atraso na próxima etapa. Saldos negativos são permitidos para representar déficits. A chave de acesso do Supabase no frontend deve ser a chave pública, nunca a service_role.

## Próxima tarefa sugerida ao Codex
Leia `CODEX_TAREFAS.md`, execute os testes de instalação/build e implemente os itens na ordem indicada, preservando a migration inicial e sem destruir dados.
