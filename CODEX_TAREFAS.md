## Formulário único, transferências no editor e imóveis — alteração atual

- Transferir dentro da edição da conta de origem, com destino, valor, data, idempotência e agendamentos preservados. Removido formulário geral. Atalho “+” leva à escolha da conta de origem.
- Lançamento único com tipos Despesa, Receita, Salário e Investimento e campos condicionais, sem os três botões separados. Investimentos informativos anteriores preservados na mesma tabela, listados no tipo Investimento.
- Vencimentos e Atrasos no Início, sem texto de prioridade.
- Patrimônio renomeado para Imóveis, com cidade, tipo, status, dívida e parcelas apenas para próprio financiado. Cadastro e edição preservam identificadores e vínculos anteriores.
- Nova migration `013_properties_and_investments.sql`; aplicar somente após as anteriores. `setup.sql` atualizado para banco novo. Nenhum dado real ou deploy foi alterado.
- Validação desta etapa: TypeScript, testes financeiros, banco PGlite 001–013, instalador, 30 testes de navegador e build de produção passaram. Tela de imóveis em 390px inspecionada.

## Ajuste rápido de saldo e menu — nova alteração

- Saldo clicável em Contas: diálogo com somente Novo saldo, foco automático, salvar e cancelar.
- RPC `adjust_account_balance` na migration `012_quick_balance.sql`, reutilizando ledger, validação de saldo esperado e chave de repetição, preservando os dados atuais da conta.
- Menu “+” fecha com toque/clique/foco fora ou Escape, permitindo executar o controle externo.
- Validação desta alteração: TypeScript, banco PGlite (incluindo idempotência, saldo desatualizado, preservação de metadados e isolamento), instalador e oito testes de navegador passaram.
- Para publicar: aplicar migrations pendentes, incluindo 012, e novo deploy do frontend. Nenhuma alteração foi feita no banco remoto.

# Continuidade — senhas e ajustes de usabilidade

## Implementado no código

- Login com visualizar/ocultar senha, recuperação por e-mail e rota `/redefinir-senha` com validação Supabase Auth (token hash ou PKCE). Alteração autenticada com senha atual em Personalização, incluindo código de reautenticação se exigido pelo Supabase.
- Pendências de hoje e atrasadas no Início, sem filtros. Filtros da aba Pendências mostram totais em centavos e lista cronológica de mês/ano.
- Edição de contas em diálogo nativo com foco, Escape e hover estável, preservando ajuste de saldo auditado no servidor.
- Transferências em Contas. Menu “+” somente Despesa, Receita e Transferência. Salários continuam no cadastro de lançamentos.
- Categorias padrão armazenadas por grupo e editáveis junto das personalizadas. Exclusão lógica preserva lançamentos históricos e remove opções dos novos cadastros, sem fallback que as faça reaparecer.

## Para publicar

1. Aplicar migrations pendentes em ordem, incluindo `011_editable_categories.sql` (banco com 001–010). `setup.sql` é somente para banco novo.
2. Publicar frontend na Vercel.
3. Configurar Supabase Auth conforme `supabase/PASSWORD_SETUP.md`: redirecionamento `/redefinir-senha`, template de recuperação e serviço SMTP/remetente para entrega de e-mail. Modelo HTML incluído.
4. Homologar com conta de teste e e-mail real. Os testes locais usam API simulada e não enviam e-mails.

Nenhuma configuração Auth ou migration foi aplicada remotamente. Continuam válidas as instruções de Cron dos recebimentos automáticos no README.

## Validação local

24 testes de navegador passaram, incluindo retorno PKCE, token hash, link expirado, troca autenticada de senha, persistência, modal de edição, totais, navegação e exclusão de categorias padrão. Verificação de tipos, testes financeiros, banco (001–011, RLS/RPCs) e instalador passaram. Edição de conta em 390px inspecionada visualmente.

# Continuidade — lançamentos recorrentes e imóveis

- A edição de previsão permite trocar a conta, limitada ao responsável, e ajustar valor, vencimento e vínculo com imóvel. Salvar e excluir oferecem Só este lançamento ou Este e os próximos. Exclusão com confirmação cancela previsões sem apagar a auditoria. Pagamentos confirmados e parciais são preservados.
- Alterar recorrência é opcional: intervalo em dias/meses ou encerrar a repetição. Refaz apenas as próximas previsões não pagas, mantendo anteriores, histórico e pagamentos. Datas mensais respeitam o fim do mês; vencimentos duplicados ao mover a data são rejeitados.
- Nova RPC transacional com controle de revisão e chave para tentativas repetidas. As chaves originais de criação das séries continuam imutáveis, mesmo depois de edições e exclusões.
- Início exibe valor líquido dos imóveis próprios (valor estimado menos dívida), separado do caixa disponível. Alugado e Terceiro ficam fora desse resumo; continuam cadastráveis e editáveis em Imóveis.
- Despesas de imóveis próprios financiados podem ser identificadas como Parcela do financiamento no cadastro e na edição. A liquidação integral baixa uma parcela; o estorno a devolve enquanto for o mesmo financiamento. Gastos de manutenção e passagem do tempo sem pagamento não baixam parcelas. A dívida em reais é atualizada manualmente conforme saldo do banco, sem estimar amortização ou juros.
- A contagem atualiza tanto Início quanto a aba Imóveis após um pagamento, sem recarregar. Interface de edição inspecionada em 390px, com seletores e rolagem adequados.
- Validação: tipos, testes financeiros, banco com migrations 001–014 e instalador passaram. A suíte de 35 testes de navegador passou, seguida de cinco cenários para os ajustes finais, incluindo o novo cenário de atualização das parcelas nas duas telas.
- Publicação: aplicar somente migrations pendentes, incluindo `014_event_editing_and_property_installments.sql`, e fazer deploy do frontend atualizado. `setup.sql` (001–014) continua exclusivo para instalação nova. Nenhuma migration ou configuração foi aplicada no ambiente remoto; não são necessárias novas chaves.

# Continuidade — identidade, Transações e crédito

- Repaginação em azul profundo/verde, temas claro e escuro, botões alinhados, login Finanças Compartilhadas e rodapé com Luciano (@englucianodev), direitos reservados, GitHub e Instagram. Cabeçalho compacto fora do Início.
- Transações substitui Pendências, com uma única lista rolável por mês e botão Nova transação. Padrão: segunda-feira da semana atual em diante no mês vigente; demais meses completos. Qualquer filtro ativo consulta todo o mês, ordenado por vencimento. Status A vencer, Pagas, Atrasadas, Todas e opção de voltar ao recorte padrão.
- Resumo centralizado: Total Parcial e Saldo são entradas menos saídas, com cartões separados para entradas positivas e saídas negativas. Usa valor integral dos registros filtrados e aritmética de centavos; pagamentos parciais são detalhados nas linhas. Contagem de registros/mês abaixo dos totais removida.
- Resumo da semana somente com transações dos últimos cinco dias, sem filtros. Patrimônio líquido dos imóveis próprios ao final do Início. Rosca mensal por categoria ou balanço substitui os dois gráficos/projeções anteriores do Início.
- Despesas podem ser anotadas como já pagas ou a pagar no cartão, opcionalmente vinculando cartão do responsável. Anotações não criam compras nem novas faturas e não afetam saldos/relatórios/gráficos/totais/checklist; o débito continua no pagamento da fatura. Bloqueio de pagamento bancário duplicado no servidor. Opção disponível também na edição individual/em série com repetição segura e auditoria.
- Transferências aceitam datas retroativas e registram data efetiva separada do horário real do ledger, atualizando saldos uma vez. Datas futuras continuam agendadas. Nova migration 015; setup atualizado para 001–015.
- Publicação: aplicar somente migrations pendentes, incluindo 015, e publicar frontend na Vercel. Sem novas chaves. Nenhuma atualização remota foi realizada.
- Verificações já concluídas: tipos, testes financeiros/mensais, banco PGlite com migrations 001–015 (crédito, fatura única, datas retroativas, permissões e idempotência) e instalador. Suíte ampliada de 40 testes de navegador passou, incluindo crédito sem duplicidade, transferências retroativas e todos os filtros/sinais de Transações. Tela de Transações em celular inspecionada visualmente. Quatro cenários adicionais dos ajustes finais dos filtros e a compilação de produção também passaram.
