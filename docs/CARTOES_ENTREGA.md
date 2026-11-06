# Entrega local do módulo de cartões

## Arquivos criados

| Arquivo | Função |
| --- | --- |
| `components/credit-module.tsx` | Cadastro/edição/arquivamento, despesas, faturas, operações, recorrências, histórico, alertas e gráficos por cartão |
| `lib/credit.ts` | Tipos, datas de ciclo, consumo, limite e conversão para as visualizações existentes |
| `supabase/migrations/019_credit_module.sql` | Metadados, tabelas cc_*, RLS, auditoria, geração e RPC transacional |
| `supabase/credit_diagnostic_before.sql` | Inventário e diagnóstico somente leitura dos dados anteriores |
| `supabase/credit_validate_after.sql` | Validação somente leitura de saldos, vínculos, parcelas, alocações e pagamentos |
| `supabase/credit_enable_cron.sql` | Instalação manual opcional do agendador, após habilitar pg_cron |
| `tests/credit-database.mjs` | Testes reais da migration em PostgreSQL PGlite descartável |
| `tests/credit-view.mjs` | Testes financeiros de consumo, caixa, faturas e limites |
| `tests/e2e/credit.spec.mjs` | Oito cenários de interface e integração com APIs simuladas |
| `docs/CARTOES_ARQUITETURA.md` | Mapeamento da implementação anterior e decisões incrementais |
| `docs/CARTOES_MIGRACAO.md` | Ordem de execução, operação, riscos e pendências |
| `docs/CARTOES_TESTES.md` | Matriz de evidências e limites da validação |
| `docs/CARTOES_ENTREGA.md` | Este inventário |

## Arquivos alterados

| Arquivo | Alteração |
| --- | --- |
| `app/page.tsx` | Carregamento do módulo, novas visualizações em Contas/Início e operações por origem |
| `app/globals.css` | Estilos restritos aos novos componentes, usando a paleta existente |
| `components/entry-form.tsx` | Nova opção Despesa no cartão no formulário unificado |
| `components/movement-list.tsx` | Faturas consolidadas, obrigações e estados próprios do cartão |
| `components/planning.tsx` | Calendário, relatório e projeções sem dupla contagem; filtros por cartão e natureza |
| `components/credit-fields.tsx` | Identificação clara da anotação anterior para evitar novas compras no fluxo antigo |
| `lib/finance-view.ts` | Distinção entre consumo e fluxo bancário, preservando cálculos anteriores |
| `supabase/setup.sql` | Instalador protegido 001–019 para banco novo |
| `package.json` | Teste de crédito e inclusão dos testes de consumo/caixa em npm test |
| `README.md` | Entrada para o módulo e instruções |
| `CODEX_TAREFAS.md` | Registro de continuidade, validações e pendências |

Não foram alteradas migrations 001–018 nem os testes anteriores para fazê-los aceitar mudanças de comportamento.

## Validação executada

- `npm run typecheck`: passou.
- `npm test`: passou, incluindo testes novos de consumo/caixa.
- `npm run test:db`: passou com migrations 001–019 em banco local.
- `npm run test:credit` (também executado diretamente por `node tests/credit-database.mjs`): passou com 019 efetivamente aplicada, incluindo o helper do cron em isolamento.
- `node tests/setup.mjs`: passou; instalador e proteção dos dados existentes.
- `npm run test:e2e`: 57 testes passaram (50 anteriores e sete iniciais do módulo).
- Rodada final `npm run test:e2e -- tests/e2e/credit.spec.mjs`: oito testes passaram, incluindo o novo cenário de calendário/relatórios/projeção.
- `npm run build`: compilação final passou.
- `git diff --check`: passou.
- Capturas de quatro cartões simultâneos e formulário em 390px inspecionadas.

## Pendências manuais

1. Executar os diagnósticos no banco real e revisar os vínculos e anotações anteriores.
2. Aplicar somente migrations pendentes em ordem, terminando na 019, e validar o resultado.
3. Publicar o frontend pela rotina habitual.
4. Se desejar geração com o aplicativo fechado, habilitar pg_cron e instalar o script opcional; sua instalação e execução remotas não foram testadas aqui.
5. Homologar em ambiente remoto com dados de teste antes de usar pagamentos reais.
6. Autorizar separadamente qualquer futura reconciliação de anotações antigas. Nenhuma conversão foi executada.

Alertas são internos ao sistema. Não há integração com emissor, leitura automática de extratos, nem envio push/e-mail. Débito automático continua exigindo confirmação do usuário. Nenhum commit, push, deploy, migração remota ou acesso aos registros reais ocorreu nesta entrega.
