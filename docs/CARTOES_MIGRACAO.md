# Publicação e homologação do módulo de cartões

Tudo foi preparado nos arquivos locais. Não foi feito commit, push, acesso a dados reais nem execução remota.

## Ordem de execução manual

1. Confirme no seu controle quais migrations já foram aplicadas. Os nomes estão em `supabase/migrations/`. Não reaplique scripts antigos e não use `setup.sql` em banco existente.
2. No mesmo projeto Supabase usado pela aplicação, aplique somente as migrations pendentes 001–018, na ordem numérica. A 019 depende de todas elas.
3. Execute separadamente as consultas de `supabase/credit_diagnostic_before.sql`. Exporte os resultados e conserve seu backup anterior. Elas não alteram registros. Compare os saldos ao ledger e revise os vínculos antigos de cartões e contas.
4. No SQL Editor, execute **019_credit_module.sql uma única vez**, preferencialmente envolvida em `begin;` e `commit;`. Se uma instrução falhar, execute `rollback;` e investigue antes de repetir. O arquivo não limpa tabelas, registros ou saldos anteriores.
5. Execute as consultas de `supabase/credit_validate_after.sql`. As consultas de anomalias devem retornar vazias; os resumos operacionais podem retornar linhas normalmente. Compare a contagem e os totais das tabelas antigas com o diagnóstico anterior.
6. Publique o frontend local na sua rotina habitual. Nenhum deploy é executado pelo agente nesta entrega.
7. Homologue com cartões e contas de teste: dois titulares, conta correta, compra simples, 5/12, obrigação manual, cobrança automática, parcial, estorno e reversão de pagamento. Confirme os saldos antes/depois.

`supabase/setup.sql` é o instalador completo 001–019, com proteção contra banco já existente; é somente para instalação nova.

## Uso

- **Contas → Cartões de crédito**: cadastrar, editar, bloquear e arquivar; selecionar titular e conta principal. Para adicionais, escolher o principal. A conta cadastrada no adicional pertence ao seu titular, mas a fatura e seu pagamento pertencem ao principal.
- **Mais → Lançamentos → Tipo: Despesa no cartão** ou **Contas → Cartões de crédito → Nova despesa no cartão**: compra realizada, cobrança automática ou obrigação manual. Responsável pela compra é independente do titular.
- **Primeira fatura** usa o mês do fechamento. Uma compra no próprio dia do fechamento entra no ciclo seguinte. Dias 29–31 são limitados ao último dia do mês. Não há cálculo de juros automático.
- Em parcelamento antigo, informe valor total original, quantidade total, próxima parcela e primeira fatura. Somente parcelas restantes são criadas, sem reconstituir pagamentos bancários anteriores.
- Obrigações manuais aparecem em Transações, no calendário, nos alertas e no detalhe do cartão. **Lançar no cartão** recebe valor e data reais. Antes disso não existe cobrança efetiva nem uso de limite.
- A fatura aparece consolidada em Transações. **Pagar fatura** aceita pagamentos integrais ou parciais; débito automático nunca confirma um pagamento. O cartão também oferece histórico e **Desfazer pagamento**, com compensação na conta original.
- Em faturas: **Juros / multa**, **Estorno**, **Antecipar parcela** com desconto informado e **Usar crédito em outra fatura**. Um estorno pode produzir saldo credor; ele não é depósito bancário. Transfira esse crédito a outra fatura do mesmo cartão quando aplicável.
- Recorrências: editar valor, pausa, reativação, encerramento, periodicidade, início e término. Mudar periodicidade/início encerra a regra anterior e cria outra, substituindo somente obrigações futuras pendentes. Regras encerradas exigem nova regra para reiniciar. Cobranças já lançadas permanecem no histórico.

## Automação e limites

A aplicação chama `cc_generate(grupo, horizonte)` ao carregar/atualizar, inclusive na atualização de um minuto já existente. A geração é idempotente por recorrência/data. Automáticas futuras ficam previstas até a data da cobrança; ao vencerem são inseridas na fatura sem confirmação individual. Falhas de limite/cartão permanecem pendentes com a causa visível. Pausar suspende novas cobranças automáticas.

Para geração com o aplicativo fechado, habilite pg_cron no Supabase e execute manualmente `supabase/credit_enable_cron.sql` após a 019. O arquivo instala uma rotina horária, restrita ao proprietário do banco, que gera cobranças com o contexto de um membro de cada grupo. Ele não confirma faturas. Nenhum cron, segredo ou acesso de serviço foi instalado automaticamente. O script opcional deve ser revisado e executado por você; a extensão pg_cron não está disponível no PGlite e a instalação do agendador remoto não foi testada nesta máquina. **Sem esse agendador, a geração devida acontece na próxima atualização da aplicação**, preservando a data prevista e sem duplicar cobranças. Os lembretes entregues são dentro do sistema; não há envio de notificações por e-mail/push.

O limite compromete todo o principal restante, inclusive parcelas futuras. Pagamentos alocam encargos primeiro e liberam apenas o principal efetivamente liquidado. Estornos e descontos reduzem o principal. Adicionais compartilham o total do principal. Parcelas legadas ainda pendentes também entram no cálculo do limite e não são copiadas para o novo módulo.

## Contabilização e histórico anterior

- Compras novas são consumo nos gráficos/relatórios por parcela faturada; faturas e pagamentos não são novamente consumo.
- No fluxo bancário entram faturas pendentes e previsões separadas de obrigações ainda não lançadas. A confirmação substitui a previsão pela fatura, sem duas saídas para a mesma obrigação.
- O relatório distingue realizadas e previstas e filtra cartão, titular/responsável, categoria e período. Gráficos do Início permanecem e os cartões recebem blocos simultâneos próprios.
- Registros antigos em `financial_events`, `card_purchases` e `invoice_payments` ficam preservados. O planejamento anterior continua disponível para compras/faturas antigas. A RPC antiga de compra rejeita cartões já revisados no módulo novo, impedindo que novas compras desviem das faturas consolidadas.
- Anotações antigas `credit_state` continuam identificadas e excluídas conforme a regra anterior. **Não é seguro promovê-las a consumo sem saber se sua fatura já está cadastrada**, pois isso duplicaria despesas. O diagnóstico lista candidatas e possíveis sobreposições; nenhuma reconciliação foi executada. É necessária sua revisão/autorização antes de uma eventual conversão.
- Cartões anteriores começam com limite zero no novo campo. Isso não representa o limite real do banco: revise o limite e a conta em Editar antes de usar novas compras. Revisar cartão não converte parcelas anteriores.
- A permissão existente é por grupo: todos os seus membros podem consultar e movimentar. Não foi criada uma separação privada entre titulares. Para o novo pagamento, a conta precisa estar ativa e pertencer ao titular do principal. Se ficar indisponível, o histórico permanece e outro vínculo válido será exigido.

## Testes e limites da validação

`npm test`, `npm run test:db`, `npm run test:credit`, `node tests/setup.mjs`, `npm run typecheck`, `npm run test:e2e` e `npm run build` são os comandos locais. O teste de crédito executa a 019 efetivamente em PGlite descartável; navegador usa APIs simuladas. Esses testes não comprovam que seu banco remoto foi migrado nem que seus dados reais estão reconciliados.

As consultas de diagnóstico foram entregues para execução manual; nenhum resultado de dados reais foi inferido. A homologação remota e a eventual reconciliação histórica permanecem pendentes do usuário.
