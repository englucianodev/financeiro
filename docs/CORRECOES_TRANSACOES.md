# Correções de transações e edição de compras

## Problemas reproduzidos no código

- O resumo semanal usava a data de anotação de crédito como data de confirmação sem limitar ocorrências futuras. A marcação de uma série como já paga registra a mesma data nas ocorrências futuras, que apareciam no resumo de hoje. A consulta financeira principal não faz joins multiplicadores; não foi necessário excluir registros. O caso específico de produção não foi consultado.
- A lista mensal misturava `cc_charge` e `cc_invoice`: compras e consolidação apareciam simultaneamente, embora os totais já separassem consumo e caixa.
- Não havia edição transacional de compras `cc_purchases`. O despachante atendia obrigações e faturas, mas não correção da compra e sequência.
- A importação presumia total original multiplicando valor da parcela pela quantidade. Agora o total de parcelamentos é uma informação explícita de revisão.
- As opções de despesa eram abertas por seleção sem alternância. Agora há botão Despesa com estado de menu independente do formulário escolhido.

## Comportamento entregue

- Identidade de eventos elimina repetição do mesmo ID sem agrupar por descrição, valor ou data. Recorrências e parcelas distintas são preservadas. Ocorrência futura com anotação legada não é confirmação recente.
- Lista mensal representa compras por fatura real (`invoice_id`), usando vencimento, nome e total da consolidação existente. Detalhes mostram todas as linhas da fatura e botão Editar compra. Categorias/pesquisa filtram consumo, enquanto os detalhes preservam o total completo da fatura. Situação é a da fatura, não o estado lançado da compra.
- Editor compartilhado acessível pelos detalhes em Transações e pelo módulo de cartões. Campos: descrição, valor total original, data, categoria, cartão, tipo, quantidade, primeira parcela restante e fatura de referência (mês do fechamento).
- RPC `cc_action` ganhou `edit_purchase`, com revisão da compra e das faturas, bloqueio por grupo, validação do limite e idempotência.
- Correção mantém IDs de linhas em sequência. Principal retirado é zerado, com parcela nula e auditoria; não se apagam linhas, vínculos de importação ou registros de pagamento. Esses registros técnicos não são exibidos como compras ativas.
- Alterações financeiras em compras/faturas com histórico de pagamento são bloqueadas, inclusive pagamento desfeito que ainda possui trilha/alocações. Descrição/categoria podem ser corrigidas com confirmação quando necessária. Não se reescrevem pagamentos históricos.
- Fechamento, importação ou ajuste exigem confirmação explícita. Estornos/descontos permanecem vinculados na fatura histórica; compras com esses créditos preservam o cartão. Total não pode ficar abaixo dos estornos/descontos.
- Em faturas com total conciliado, confirmar a correção atualiza esse total para a soma corrigida, auditando a mudança. Não há compensação bancária porque editar compra não movimenta saldo.
- Revisão da importação permite transformar à vista/parcelada e alterar posição. Total original não é inventado. Suspeitas marcadas como novas exigem confirmação adicional. Restrições de arquivo/ID bancário e rollback existentes permanecem.
- Botão Despesa abre/fecha o menu; escolher opção fecha o menu e abre o formulário em desktop/mobile.

## Instalação

Aplicar somente `supabase/migrations/023_purchase_corrections.sql` após 001–022 em banco existente, com a rotina habitual de backup/homologação. `setup.sql` atualizado até 023 é somente para banco vazio. Publicar frontend depois da migration. Nenhuma nova variável de ambiente é necessária.

A migration não corrige nem apaga dados existentes ao ser instalada. Não foram executadas alterações remotas, commit, push ou deploy.

## Verificação

As suítes incluem novos casos de identidade semanal, faturas/cartões/mês/status, conversão à vista/parcelada, 3/10 → 2/10 → 4/10, centavos, limite, rollback, preservação de identificadores importados, revisão concorrente, confirmação de período, pagamento e isolamento.

Comandos: `npm test`, `npm run typecheck`, `npm run test:db`, `npm run test:credit`, `node tests/setup.mjs`, `npm run test:password`, `npm run test:e2e` e `npm run build`. Resultados efetivos são informados na entrega; a presença do comando aqui não afirma que ele passou.

## Arquivos desta entrega

- `app/page.tsx`
- `app/globals.css`
- `components/credit-module.tsx`
- `components/movement-list.tsx`
- `components/statement-tools.tsx`
- `components/transaction-actions.tsx`
- `lib/credit.ts`
- `lib/finance-view.ts`
- `lib/statements.ts`
- `supabase/migrations/023_purchase_corrections.sql` (novo)
- `supabase/setup.sql`
- `tests/credit-database.mjs`
- `tests/credit-view.mjs`
- `tests/finance-view.mjs`
- `tests/statements.mjs`
- `tests/e2e/credit.spec.mjs`
- `tests/e2e/finance.spec.mjs`
- `docs/CORRECOES_TRANSACOES.md` (este documento)

O consolidado também preserva saldo credor e mostra o total líquido real após estornos, mesmo quando o valor pago anteriormente era maior que o novo total. A aplicação não repete esses valores como consumo.

## Resultados locais em 08/11/2026

- `npm run typecheck`, `npm test`, `npm run test:db`, `npm run test:credit`, `node tests/setup.mjs` e `npm run test:password`: passaram.
- `npm run build -- --webpack`: passou na versão final, incluindo geração das páginas e rastreamento de arquivos.
- Navegador: rodada completa com 75 cenários, 72 aprovados e três falhas de expectativas/seletores dos testes. Após ajustar os testes, os três cenários passaram isoladamente. O detalhe/edição de fatura também passou em 390px; menu foi validado em 390px e 1280px. A suíte completa não foi repetida após os ajustes nos testes.
- A execução padrão do Playwright com Turbopack expirou na inicialização; build Turbopack não concluiu e foi interrompido. A validação de build/navegador usou Webpack com configurações temporárias removidas, sem mudar os scripts de publicação do projeto.
- `git diff --check`: sem erros. Testes de banco utilizaram PostgreSQL PGlite descartável; navegador utilizou APIs simuladas. Não houve migração remota, commit, push ou deploy.
