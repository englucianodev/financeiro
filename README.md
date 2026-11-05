# Finanças a Dois

Aplicação Next.js, React, TypeScript e Supabase para finanças compartilhadas de duas pessoas.

## Executar localmente

1. Instale Node.js 20.9 ou superior e execute `npm ci`.
2. Copie `.env.example` para `.env.local` e informe a URL e a chave pública do Supabase.
3. Em um Supabase de desenvolvimento, revise e aplique **todas** as migrations de `supabase/migrations` na ordem numérica, de `001` a `007`. Em banco existente, aplique somente as ainda não executadas. Não reaplique scripts nem substitua tabelas existentes.
4. Configure autenticação por e-mail, URL do site e redirecionamentos no Supabase Auth.
5. Execute `npm run dev` e abra [localhost:3000](http://localhost:3000).
6. Cadastre o primeiro usuário e crie a família. Gere um convite de uso único, válido por 24 horas, para o segundo usuário.

Use somente a chave pública/publishable ou anon no frontend. Nunca use `service_role` nas variáveis `NEXT_PUBLIC_*`.

## Funcionalidades existentes

- Login individual, família com até dois membros, convites aleatórios armazenados por hash e isolamento por RLS.
- Contas por pessoa, conta principal transacional e sugestão da conta conforme o responsável, preservando escolha manual durante recargas.
- Receitas/despesas avulsas ou mensais com até 60 ocorrências, categoria, imóvel, valor estimado variável e edição/cancelamento individual.
- Pagamentos integrais/parciais com conta, valor e data efetivos; estorno que preserva histórico e reabre a pendência.
- Livro de movimentações, auditoria de alterações dos lançamentos e operações financeiras por RPC transacional com chaves de repetição.
- Transferências internas sem alterar o saldo consolidado.
- Cartões, fechamento/vencimento, compras parceladas e pagamento integral/parcial de faturas sem duplicar o débito bancário.
- Projeção diária de 30/60/90/180/365 dias por conta, pessoa e casal; atrasados entram hoje. Alertas de primeiro déficit, menor saldo e sugestões de transferências.
- Calendário mensal, relatórios por vencimento com filtros e gráfico por categoria, cadastro informativo de imóveis/investimentos e simulador de receitas, despesas e transferências.
- Tema claro/escuro e interface responsiva em português.

## Verificação

```sh
npm run typecheck
npm test
npm run test:db
npm run test:e2e
npm run build
```

`test:db` aplica todas as migrations em PostgreSQL embarcado PGlite e verifica RLS, RPCs, preservação dos saldos legados, pagamentos, estornos, recorrências e cartões. Não conecta ao seu Supabase.

Os testes Playwright usam respostas simuladas do Supabase e sessão em cookie, sem dados reais. No Windows usam Microsoft Edge instalado; em outros sistemas instale Chromium com `npx playwright install chromium`. O servidor de teste usa a porta 3100.

Validação local em 05/11/2026: TypeScript, cálculos financeiros, banco, três testes E2E no Edge e build de produção passaram.

## Implantação na Vercel

- Importe o repositório e selecione `financas-a-dois` como Root Directory se o repositório contiver a pasta acima do app.
- Use o preset Next.js e o comando de build `npm run build`.
- Configure `NEXT_PUBLIC_SUPABASE_URL` e `NEXT_PUBLIC_SUPABASE_ANON_KEY` em cada ambiente e faça novo build após alterações.
- Aplique as migrations no Supabase de destino, em ordem e com backup antes de atualizar banco existente.
- Ajuste Site URL e URLs de redirecionamento no Supabase Auth para o domínio publicado.
- Valide com duas contas de teste: convite, isolamento entre famílias, pagamento, estorno e transferência antes de inserir dados reais.

## Limitações conhecidas

- Ainda precisa de homologação no Supabase hospedado e na Vercel. Testes locais com PGlite e API simulada não substituem essa validação nem comprovam concorrência com várias conexões.
- Recorrências geram um lote finito; não há edição futura em lote nem atualização automática pelo último valor variável confirmado.
- Transferências futuras existem no simulador; não há agendamento persistente. Não há reserva mínima configurável, conciliação bancária, paginação ou exportação dos relatórios.
- Investimentos são informativos e ficam fora do saldo disponível, inclusive os líquidos. O resgate deve ser registrado na conta quando recebido, evitando somar o mesmo dinheiro duas vezes.
- Relatórios usam vencimento (competência); não fornecem extrato por data/conta efetiva de pagamento. O saldo de calendário é projetado de hoje até 365 dias; datas anteriores não reconstituem o saldo histórico.
- A auditoria cobre lançamentos e movimentações; não existe ainda interface de consulta completa ao ledger ou auditoria de todos os cadastros.

Consulte `CODEX_TAREFAS.md` para o ponto de continuidade.

## Correção de login/criação de família no ambiente publicado

A API pública utilizada por `nossascoisinhas.vercel.app` respondeu `PGRST205` ao consultar somente a estrutura de `household_members`, sem ler registros: a tabela `public.household_members` não estava disponível no cache de esquema. Verifique se as variáveis da Vercel apontam para o projeto Supabase correto e se as migrations foram aplicadas nesse projeto.

Para um banco sem estrutura do aplicativo, abra `supabase/setup.sql`, copie o conteúdo inteiro para uma nova consulta no SQL Editor do Supabase correto e execute. O script reúne as migrations 001–007 em uma transação e solicita a atualização do cache da API. Ele recusa executar se encontrar tabelas existentes do aplicativo, sem apagar dados. Se essa proteção for acionada, aplique somente as migrations pendentes; não remova a proteção.

Se as tabelas já existem e todas as migrations foram aplicadas, atualize somente o cache no SQL Editor:

```sql
NOTIFY pgrst, 'reload schema';
```

Publique também o código corrigido na Vercel. A interface passa a mostrar erros legíveis do Supabase e separa falha de consulta de usuário realmente sem família. Não publique senhas nem chaves privadas. O banco remoto não foi alterado por esta correção.

Verificação adicional do instalador: `node tests/setup.mjs`. Foram validados sete testes de navegador, build de produção, instalação inicial, criação autenticada de família e recusa de reinstalação preservando dados.
