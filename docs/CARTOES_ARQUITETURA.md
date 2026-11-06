# Módulo de cartões — análise e decisões

## Estado anterior

- `financial_accounts.balance` é atualizado pelo ledger; compras nunca devem escrever saldos diretamente.
- `credit_cards` guarda titular e conta. A política antiga de inserção só verifica conta do grupo, sem validar titularidade. Há compras legadas em `card_purchases`, parcelas em `financial_events` e pagamentos em `invoice_payments`.
- `credit_state` é anotação legada: não gera cobrança nem controla limite. Está excluída de totais para evitar duplicar uma fatura cadastrada manualmente.
- Membros do mesmo grupo compartilham leitura/movimentação. Não há ACL de contas compartilhadas além do titular; a nova regra de débito usa uma conta ativa do titular do cartão.
- Projeções usam pendências por conta e data, em horizontes de até 365 dias. Gráficos atuais somam competência mensal. O calendário usa os mesmos eventos.

## Implementação incremental

1. Manter tabelas, RPCs e dados antigos. Acrescentar metadados de cartões e tabelas `cc_*` para novas operações.
2. Não promover anotações antigas a compras. Diagnóstico SQL somente leitura entregue separadamente. Dados reais só podem ser examinados pelo usuário, pois acesso remoto está proibido.
3. Obrigações manuais e cobranças são ligadas por identificador único. A confirmação cria uma compra uma única vez; antes dela não existe parcela/fatura efetiva nem limite utilizado.
4. Novas faturas são obrigações consolidadas virtuais na interface; parcelas são consumo para relatórios, e apenas faturas entram no fluxo bancário. Nenhuma compra nova é copiada para `financial_events`.
5. Pagamentos gravam ledger e alocação por linha, encargos primeiro. Desfazer usa lançamentos compensatórios, preservando linhas e auditoria.
6. Fechamento: compras no dia do fechamento entram no ciclo seguinte. Dias 29–31 são limitados ao último dia de cada mês. Alterar datas do cartão só afeta operações futuras; faturas existentes mantêm suas datas.
7. Adicionais compartilham fatura, limite e conta do principal. Titular do plástico e responsável pela compra permanecem distintos. O principal é o responsável pelo pagamento.
8. Valores monetários são inteiros de centavos na divisão e numeric(16,2) no banco. A última parcela recebe o resíduo. Importação em 5/12 gera somente 5–12.
9. Recorrências são geradas até um horizonte explícito, com chave única (regra,data). Automáticas futuras ficam como previsão até a data da cobrança; manuais permanecem obrigações. A rotina local de atualização materializa cobranças devidas sem confirmar faturas.
10. Sem commit, push, migração remota ou conversão de histórico. As validações relatadas serão exclusivamente sobre bancos locais descartáveis e mocks de navegador.
