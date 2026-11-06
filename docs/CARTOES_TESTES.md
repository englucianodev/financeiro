# Evidências e limites dos testes locais

## Banco e integridade

`tests/credit-database.mjs` cria um PostgreSQL PGlite descartável, aplica efetivamente 001–018, insere um vínculo legado e aplica a 019. Ele verifica:

| Requisito | Evidência |
| --- | --- |
| Vários cartões/titulares/contas | Cadastro de cartões Ana, Bruno e adicional; conta de outro titular rejeitada |
| Preservação | Vínculo antigo e saldos comparados antes/depois; diagnóstico somente leitura executado |
| Compra à vista/parcelada | 1, 3 e 12 parcelas; centavos 33,33 + 33,33 + 33,34 |
| Parcelamento antigo | Importação 5/12 gera oito parcelas e R$ 800 de dívida |
| Ciclos | Fechamento no próprio dia, fevereiro e anos bissextos |
| Limite | Principal futuro integral comprometido; excesso bloqueado; adicional compartilha limite |
| Fatura/pagamentos | Várias compras; parcial, múltiplos pagamentos, integral; conta autorizada; revisão desatualizada |
| Encargos | Juros/multa informados; pagamento de encargos não libera principal |
| Desfazer | Compensação no ledger e retorno do principal; segunda reversão rejeitada |
| Estorno/crédito | Estorno parcial gera crédito e reduz limite; crédito transferido entre faturas do mesmo principal |
| Antecipação | Parcela futura movida; desconto informado reduz principal |
| Manual | Sem fatura/limite antes da confirmação; compra vinculada única depois dela; repetição segura |
| Automática | Sem confirmação individual; data real prevista; excesso de limite fica pendente com erro visível |
| Recorrência | Geração repetida sem duplicação; manual e automática; valor variável; pausa/reativação/encerramento; troca de periodicidade |
| Segurança | Sem acesso de outro grupo; tabelas novas sem escrita direta; helpers internos não executáveis pelos clientes |
| Auditoria | Alterações registradas em cc_audit; pagamentos e reversões em ledger e alocações |
| Cron | Somente o helper restrito foi executado em isolamento; pg_cron e instalação do job remoto NÃO foram executados |

`tests/database.mjs` mantém a regressão de RLS, contas, pagamentos, recorrências, imóveis e dados legados, com migrations 001–019. `tests/setup.mjs` verifica o instalador em banco vazio e sua recusa de reinstalação sobre dados existentes.

## Cálculos e projeções

`tests/credit-view.mjs` verifica consumo separado de caixa, fatura consolidada única, valor do consumo constante após pagamento, redução gradual do principal, obrigação manual sem limite, datas de ciclo, adicionais compartilhados e parcelas legadas no limite.

`tests/finance-view.mjs`, `tests/money.mjs` e `tests/identity.mjs` mantêm os cálculos anteriores, incluindo projeção até o fim do mês, centavos, transferências e gráficos existentes.

## Navegador

`tests/e2e/credit.spec.mjs` usa Supabase simulado para validar:

1. Quatro gráficos simultâneos e manutenção do gráfico atual.
2. Cadastro com filtro por titular e arquivamento.
3. Obrigação manual dentro/fora do cartão sem duas despesas independentes.
4. Pagamento parcial de fatura e reversão.
5. Formulário unificado e importação em 5/12.
6. Responsável diferente do titular e recorrência automática.
7. Migration ausente sem bloquear contas anteriores.
8. Calendário, despesa realizada, relatório por titular/cartão e projeção sem dupla saída bancária.

As telas de gráficos e formulário são verificadas em 390px e capturadas em `test-results`. A suíte anterior de 50 testes de finanças e autenticação permanece no projeto.

## O que esta validação não comprova

- Que a 019 foi aplicada no Supabase do usuário.
- Que registros reais antigos foram reconciliados ou estão corretos.
- Que o job pg_cron está instalado/rodando remotamente.
- Que uma cobrança existe no emissor do cartão: o sistema registra informações fornecidas pelo usuário, sem integração com bancos.
- Entrega de notificações push/e-mail: os alertas desta implementação são dentro do sistema.

Os resultados concretos dos comandos executados são registrados na entrega e em CODEX_TAREFAS.md. Consultas e migrações remotas devem ser executadas manualmente conforme CARTOES_MIGRACAO.md.
