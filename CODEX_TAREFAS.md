# Continuidade — abas e operação financeira

## Implementado localmente

- Cinco telas: Início, Pendências, Calendário, Contas, Mais. A aba Mais tem opções internas separadas de Lançamentos, Transferências, Planejamento, Histórico e Personalização. Conteúdo separado visualmente, com navegação acessível e restauração de sessão/aba/período/data/rolagem.
- Contas editáveis: finalidade (uso diário, recorrentes, investimentos), nome, cor, saldo e principal no formulário. Ajuste de saldo via ledger; preservação do titular em contas com histórico.
- Só contas do responsável para novos lançamentos, com validação no servidor e frontend; históricos existentes preservados.
- Investimentos fora do saldo disponível/projeção de caixa, apresentados com menor destaque e separados do cadastro informativo de investimentos.
- Pendências dos próximos sete dias, outros dias roláveis, filtros de nome/categoria/tipo/atraso/mês, checklist textual do mês vigente para copiar, baixar e compartilhar pelo seletor do aparelho.
- Resumo de pagas/recebidas/atrasadas nos últimos cinco dias com anteriores roláveis e filtros.
- Categorias ordenadas alfabeticamente, calendário ampliado (três colunas no celular) só com compromissos sem valores, gráficos de barras de entradas/saídas por dia com déficit e sem contar transferências internas como receita/despesa.
- Projeção por conta com data final configurável e persistida.
- Recebimentos automáticos idempotentes, correção de valor/data com estorno e novo lançamento atômicos. Worker privado e bloqueio de reconfirmação após estorno manual.

## Para publicar

Aplicar migrations pendentes em ordem, incluindo `010_accounts_and_receipts.sql`, e atualizar frontend na Vercel. Não usar `setup.sql` sobre banco existente; ele é apenas para instalação nova. Nenhum dado real foi alterado nesta tarefa.

Para confirmar receitas mesmo com o app fechado, habilitar pg_cron no Supabase e executar `supabase/enable_income_cron.sql`. Sem esse job, o app confirma ao abrir/retornar ao primeiro plano e a cada minuto visível. O worker inclui receitas pendentes com vencimento até hoje; revisar previsões antigas antes de habilitar em produção.

## Verificação

TypeScript, testes de projeção/nomes/checklist/barras, banco PGlite (001–010 e RLS/RPCs), instalador e 14 testes de navegador passaram no código local. Captura do calendário em 390px inspecionada, sem rolagem horizontal. Job Cron e autenticação real ainda precisam de homologação no Supabase hospedado. Consulte README para procedimentos e limitações das recorrências, relatórios e investimentos.
