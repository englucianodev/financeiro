# Importações: histórico, movimentação e desfazimento seguro

## Problemas tratados

A estrutura anterior guardava decisões e um identificador de linha na primeira fatura, mas não registrava a origem exata de todas as parcelas futuras e ajustes criados. Também impedia reimportar o mesmo arquivo mesmo depois de uma reversão. Desfazer por descrição, valor ou proximidade de datas seria inseguro.

O editor já permitia conversão à vista/parcelada e correção de sequência. Alterar apenas a quantidade de parcelas, porém, reiniciava a posição em 1. Agora a posição permanece como informada; se ficar incompatível com o novo total, o formulário exige sua correção explícita.

## Funcionamento

- A importação usa UUID próprio e guarda compras, todas as parcelas e ajustes criados em `cc_import_items`, com snapshots. Itens apenas identificados/vinculados são registrados separadamente e nunca selecionados para exclusão.
- Todos os registros financeiros, metadados, auditoria e manifesto são gravados na mesma transação. Uma linha inválida reverte tudo.
- Possíveis duplicidades exigem confirmação no cliente e no servidor. Identificador bancário já existente exige vincular ao registro, em vez de recriar.
- Edição permite descrição, valor, data, categoria, cartão, à vista/parcelada, quantidade, primeira parcela restante e referência com mês/ano. O destino pode ser uma fatura ainda inexistente, criada pelo backend segundo o ciclo do cartão.
- A interface mostra período original, faturas de origem e intervalo de destino. Mudar o período exige confirmação explícita; a transação reorganiza as parcelas e atualiza os totais/revisões das faturas afetadas, sem duplicar as parcelas anteriores.
- Em Contas → Cartões de crédito → Recorrências e histórico, há Histórico de importações. A seção também aparece no diálogo Importar/Ajustar fatura.
- Histórico mostra cartão, nome do arquivo, data/hora em Fortaleza, mês/ano da fatura original (competência de fechamento), quantidades, total importado naquela fatura e status. Valores ausentes no legado não são inventados.

## Desfazer

1. Desfazer importação consulta a prévia no servidor.
2. A prévia informa compras/parcelas a remover, vínculos a preservar, faturas afetadas e impedimentos.
3. Quando seguro, Confirmar desfazimento integral pede confirmação e revalida tudo dentro da transação.
4. São removidos apenas os UUIDs de compras, parcelas e ajustes comprovadamente criados naquele lote. Registros manuais, de outros lotes ou somente vinculados permanecem.
5. Exclusões registram o conteúdo anterior em `cc_audit`; o manifesto e o histórico da importação permanecem. Faturas são recalculadas pela soma das linhas e têm sua revisão incrementada.
6. Status passa para Desfeita, com autor/data. O arquivo pode ser reimportado com novo UUID. A unicidade de cartão/hash vale para importações ativas.

Não existe limite de data para desfazer: importações retroativas podem ser revertidas se conservarem origem confiável e não tiverem dependências inseguras. Importações não movimentam saldo bancário; o desfazimento seguro preserva contas e ledger. Limite disponível e totais das faturas refletem as linhas restantes.

## Bloqueios

- Importações antigas sem manifesto confiável: revisão individual obrigatória. Não há inferência por nome, arquivo, valor ou data, nem migração automática de propriedade.
- Compras/linhas alteradas desde a importação, inclusive conversão ou mudança de período.
- Histórico de pagamento nas faturas afetadas, mesmo que posteriormente desfeito, e alocações.
- Vínculos feitos por outras importações ativas, inclusive referências registradas no histórico antigo.
- Novas parcelas, estornos ou descontos ligados à compra e não criados pelo lote.
- Ajustes revertidos e conciliações posteriores, inclusive outro lote que preservou um total conciliado e passou a depender do anterior.

O motivo aparece na prévia; a confirmação não contorna esses bloqueios. Restrições adicionais do banco também abortam integralmente a reversão, preservando os registros e a auditoria anteriores à tentativa.

## Instalação

Aplicar `supabase/migrations/024_import_lifecycle.sql` depois de 001–023 em banco existente, conforme a rotina de backup/homologação. O instalador `supabase/setup.sql` inclui 001–024 e continua exclusivo para banco vazio. Não há variáveis ou serviços novos. Publicar o frontend atualizado somente após preparar o banco pela rotina autorizada.

A migration adiciona metadados, origem confiável para importações novas, RLS de leitura, RPCs e auditoria de exclusão. Ela não remove compras ou altera saldos existentes. Supabase, Auth, permissões por grupo e auditoria foram preservados.

## Verificação

`npm run test:imports` aplica as migrations reais em PGlite e verifica: desfazimento retroativo, parcelas futuras, vínculos preservados, outra importação independente, reimportação, idempotência, confirmação de duplicidade, rollback de importação e de reversão, ajuste conciliado, dependências entre conciliações, legado, mês/ano, conversão, pagamento, RLS e auditoria.

Também executar `npm test`, `npm run typecheck`, `npm run test:db`, `npm run test:credit`, `node tests/setup.mjs`, `npm run test:password`, `npm run test:e2e` e `npm run build`. O resultado efetivo consta na entrega; mocks/PGlite não comprovam configuração ou concorrência do ambiente remoto.

## Arquivos alterados

- `README.md`
- `components/credit-module.tsx`
- `components/statement-tools.tsx`
- `components/import-history.tsx` (novo)
- `package.json`
- `supabase/setup.sql`
- `supabase/migrations/024_import_lifecycle.sql` (novo)
- `tests/credit-database.mjs`
- `tests/import-lifecycle.mjs` (novo)
- `tests/e2e/credit.spec.mjs`
- `docs/IMPORTACOES_NOTIFICACOES.md`
- `docs/IMPORTACOES_CICLO_DE_VIDA.md` (este documento)

## Resultados locais

- `npm run typecheck`, `npm test`, `npm run test:password`, `npm run test:db`, `npm run test:credit`, `npm run test:imports` e `node tests/setup.mjs`: passaram.
- Playwright: **77 testes passaram** na rodada completa com servidor Webpack, incluindo histórico, legado, desfazimento, preservação de itens manuais e reimportação. O reteste dirigido também passou para mudar o total sem reiniciar a parcela 3 e mover mês/ano com confirmação.
- `npm run build -- --webpack`: versão final compilada com sucesso, incluindo TypeScript, páginas e rastreamento de arquivos. A configuração temporária dos testes foi removida; os comandos de publicação existentes foram preservados.
- `git diff --check`: sem erros. Nenhuma conexão ao banco real, alteração de produção, commit, push ou deploy foi executado.
