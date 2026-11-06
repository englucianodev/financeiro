# Importações, ajustes e e-mails — entrega local

## Arquitetura reutilizada

O módulo existente mantém `cc_lines`, `cc_purchases`, `cc_invoices`, `cc_requests`, ledger, alocações, RLS e auditoria. A 020 estende a RPC existente, sem substituir suas operações. A 021 acrescenta configurações e histórico de notificações. Não houve leitura/correção de produção, commit, push ou deploy.

## Execução manual

1. Confirme quais migrations já foram aplicadas. Aplique somente as pendentes em ordem até 019.
2. Execute `supabase/migrations/020_statement_imports.sql`, depois `021_email_notifications.sql`, uma vez, preferencialmente em transação (`begin;` / `commit;`). Em falha, `rollback;` antes de investigar. Não use `setup.sql` em banco existente; o instalador é somente para banco vazio.
3. Publique pela sua rotina habitual somente após homologar. `prebuild` copia workers, WASM e idioma português para arquivos locais da aplicação; mantenha as dependências instaladas. Não há CDN ou serviço pago para ler PDFs.
4. Configure no servidor Vercel: `SUPABASE_SERVICE_ROLE_KEY`, `RESEND_API_KEY`, `NOTIFICATIONS_FROM`, `NOTIFICATIONS_CRON_SECRET` (aleatório forte), `APP_URL` (URL HTTPS do sistema). `NEXT_PUBLIC_SUPABASE_URL` continua o existente. Nunca prefixe segredos com NEXT_PUBLIC.
5. No Resend, cadastre/verifique um domínio remetente e seus registros DNS; gere uma chave com permissão de envio. O modo de testes do provedor pode restringir destinatários. Nenhum e-mail foi enviado pelo agente.
6. Habilite pg_cron, pg_net e Vault no Supabase. No Vault, cadastre manualmente `finance_app_url` e `finance_notifications_secret` com o mesmo segredo do servidor. Execute `supabase/notifications_enable_cron.sql` manualmente. O job chama a rota autenticada a cada cinco minutos. Não instale um segundo agendador para a mesma rotina.
7. Em Mais → Personalização → Notificações por e-mail, escolha destinatários atuais do grupo e habilite. Padrão: 08:00/20:00, segunda–sexta, America/Fortaleza, feriados nacionais e datas locais adicionais bloqueados. Inicialmente o envio está desabilitado e não há destinatários selecionados.

## Uso da importação

Em Contas → Cartões de crédito, use Importar fatura / Ajustar valor da fatura. Escolha a fatura (competência de fechamento) e o arquivo. Leitura/OCR ocorre no navegador; somente linhas aprovadas, nome e SHA-256 do arquivo são enviados na confirmação. O PDF original não é armazenado publicamente nem enviado ao Resend.

CSV aceita Data/Descrição/Valor e ID/FITID opcional, com vírgula ou ponto e vírgula como separador. OFX interpreta débitos como compras e créditos como créditos; pagamentos anteriores precisam ser descartados/vinculados, nunca tratados automaticamente como novas despesas. PDF textual depende de linhas reconhecíveis; PDF digitalizado usa OCR local em português. Limites: 15 MB, 30 páginas, 1.000 linhas por importação. Arquivos protegidos, malformados ou layouts não reconhecidos podem exigir exportação CSV.

Datas sem ano, valores e cronogramas incertos ficam para revisão. Para parcela 3/10, informe explicitamente o valor total original e confirme a primeira fatura; o sistema não presume que parcela × quantidade seja o total real. A divisão e o resíduo usam a regra financeira existente. Se o valor da parcela não corresponder ao total informado, a operação é rejeitada integralmente.

A comparação considera cartão, descrição/estabelecimento, parcela, valor e identificador bancário. Mesma data/valor em outro estabelecimento não basta para declarar duplicidade. Correspondências por semelhança ficam como possíveis/divergentes e exigem decisão. Cada linha deve ser importada, vinculada ou descartada explicitamente. Ações em lote atuam nas linhas selecionadas. Nenhuma leitura grava compras.

Mesmo arquivo/cartão não pode ser importado duas vezes; o histórico conserva decisões, metadados e contagens. Identificadores bancários são únicos por cartão. Falha em qualquer linha reverte toda a importação. Uma decisão humana de criar uma compra semelhante sem identificador não prova que são compras distintas: confira cuidadosamente.

## Ajustes

O total real é comparado à soma atual, incluindo ajustes anteriores, sem mexer nas compras, parcelas, alocações ou saldo bancário. A diferença vira Complemento/Redução de Fatura, categoria Ajuste de Fatura, na data de fechamento. Reverter produz lançamento compensatório, mantendo auditoria.

Ao importar depois de um ajuste, marque explicitamente a opção de manter o total real anterior. A conciliação reduz/recompõe o ajuste dentro da mesma transação; o total real não muda silenciosamente. Desmarcada a opção, novas compras aumentam o total e o ajuste anterior fica preservado.

## Lançamentos em Transações

Compras efetivadas, inclusive cobranças automáticas e obrigações manuais já confirmadas, aparecem como lançamentos no cartão. A obrigação original fica no histórico do cartão e deixa de ser uma segunda linha geral. Faturas são consolidações de caixa; não somam novamente o consumo. Compras não debitam conta bancária.

## Agendamento, gratuidade e segurança

A rotina reconsulta pendências em cada horário, inclusive à noite. Inclui despesas bancárias/recorrentes, faturas consolidadas e obrigações manuais ainda pendentes; não inclui cada compra outra vez. Sem pendências não há envio. E-mails confirmados de integrantes atuais selecionados são consultados no servidor, nunca informados livremente pelo cliente.

Cada destinatário/data/horário possui chave única, lease e histórico. Tentativas usam o mesmo payload e chave Resend para reduzir duplicações após falha de rede. Resend mantém idempotência por 24h; a janela de execução local é de 10 minutos. Não é uma garantia matemática de entrega única entre serviços externos. Falhas constam no histórico. Projetos pausados, limites do provedor, DNS, timeout e indisponibilidade podem impedir ou atrasar o envio. Os horários não são garantidos no minuto exato.

Fontes oficiais consultadas: [Supabase Cron](https://supabase.com/docs/guides/cron), [agendamento de funções](https://supabase.com/docs/guides/functions/schedule-functions), [limites Resend](https://resend.com/pricing), [idempotência Resend](https://resend.com/docs/dashboard/emails/idempotency-keys). O plano gratuito Resend anuncia 100 e-mails/dia; confirme a cota mensal vigente e a capacidade do seu projeto antes de habilitar. Não habilite upgrades pagos ou cobranças automáticas sem decidir isso explicitamente. O job só funciona enquanto banco e aplicação estiverem disponíveis.

## Diagnóstico somente leitura

Execute cada consulta separadamente após as migrations:

```sql
select card_id,file_hash,count(*) from cc_imports group by 1,2 having count(*)>1;
select card_id,bank_transaction_id,count(*) from cc_lines where bank_transaction_id is not null group by 1,2 having count(*)>1;
select household_id,user_id,local_date,slot,count(*) from notification_deliveries group by 1,2,3,4 having count(*)>1;
select a.id,a.balance,coalesce(sum(l.amount),0) ledger from financial_accounts a left join account_ledger l on l.account_id=a.id group by a.id having a.balance<>coalesce(sum(l.amount),0);
select id,household_id,file_name,summary,created_at from cc_imports order by created_at desc limit 20;
select local_date,slot,status,error from notification_deliveries order by claimed_at desc limit 50;
```

Continue utilizando `credit_diagnostic_before.sql` e `credit_validate_after.sql` para cartões/parcelas/alocações. Nenhuma inconsistência real foi inferida sem acessar o seu banco.

## Arquivos principais e limites

Criados: migrations 020/021; `lib/statements.ts`, `lib/statement-file.ts`, `lib/email-notifications.ts`; `components/statement-tools.tsx`, `components/email-settings.tsx`; `app/api/notifications/route.ts`; `scripts/prepare-readers.mjs`; script de cron; testes de extração/horários e PDF/OCR.

Alterados: módulo de cartões, preferências, tipos e visualização de crédito, CSS, instalador, dependências/lockfile, variáveis de exemplo e testes de regressão. Serviços de envio e agendamento remotos não foram configurados nem testados com credenciais reais. O resultado local não comprova migração, reconciliação ou entrega de e-mail em produção.

## Resultados locais desta entrega

- Tipos/compilação, npm test, banco 001–021, teste específico de crédito/importação/ajustes e instalador passaram.
- Na rodada completa do navegador, 60 cenários passaram; o OCR ainda carregava os recursos anteriores e falhou. Após a correção de idioma descompactado/motor estável, o reteste oficial --last-failed passou. PDF textual e digitalizado também passaram em testes isolados no celular.
- Três testes adicionais passaram: CSV bloqueado até a conferência final, prévia/confirmação de ajuste e padrões de notificações.
- Testes de banco confirmam rollback total, repetição idempotente, mesmo arquivo rejeitado, importação a partir de 3/10, estorno/tarifa, conciliação do complemento, saldo preservado e bloqueio de outro grupo. Envio Resend e instalação do cron remoto não foram executados.
