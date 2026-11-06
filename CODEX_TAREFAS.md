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

## Reparo do ajuste rápido de saldo

- Relato de erro genérico de API/banco desatualizado ao ajustar saldo. A RPC usada é `adjust_account_balance`, introduzida em 012. O erro bruto do ambiente publicado não foi obtido; função ausente/cache desatualizado são hipóteses compatíveis com o código.
- Preparado `supabase/repair_balance_adjustment.sql`: transação com verificação dos pré-requisitos (base até 010), criação/substituição da função equivalente à 012, permissões explícitas e recarga do cache PostgREST. Não modifica dados financeiros e pode ser repetido.
- `node tests/setup.mjs` passou com remoção simulada da função, reaplicação repetida do reparo, bloqueio de acesso anônimo, preservação de saldos e metadados, rejeição de saldo desatualizado e prevenção de duplicidade no ajuste.
- Ainda precisa executar o arquivo no SQL Editor do projeto Supabase usado pela Vercel. Nenhuma alteração foi feita no banco remoto. Não foi necessário alterar o frontend.

## Quitação real e desfazer pagamentos — migration 016

- Causa do resíduo: a confirmação anterior sempre acumulava pagamento parcial, e 370 − 369,12 também preenchia o restante com uma representação decimal inválida para step .01. Novo diálogo calcula em centavos e usa quitação pelo valor efetivo como padrão; parcial exige marcação explícita.
- Nova RPC `manage_event_payment`: confirmar (quitar/parcelar explicitamente), corrigir total pago, encerrar pelo total já pago sem novo débito e desfazer. Controle de revisão, chaves de repetição, RLS/permissões e transações atômicas; auditoria/ledger preservados. Endpoints antigos de pagamentos/faturas mantêm seu contrato.
- Novo diálogo nativo para confirmação/correção/desfazer, com erros visíveis dentro da janela. Corrigir pagamento e Desfazer pagamento disponíveis no Início, Transações e Histórico. Correções devolvem os lançamentos antigos às contas originais e registram o total correto na conta escolhida; pagamentos de múltiplas contas exigem seleção explícita.
- Desfazer recebimento reduz o saldo e mantém supressão de confirmação automática. Desfazer anotação de cartão só retorna a A pagar no cartão. Estornos/correções preservam a contagem de parcelas dos imóveis.
- Resíduos existentes não são alterados automaticamente: Marcar pago → Quitar pelo valor já pago, sem débito adicional. Correção total também pode ser feita pelo botão Corrigir pagamento.
- Verificados localmente: tipos, testes financeiros, PGlite migrations 001–016, instalação nova e reparo do ajuste de saldo. Banco cobre 370→369,12, resíduo de 0,88, pagamento parcial explícito, valor maior, correção de conta/data/valor, desfazer com repetição segura, stale revisions, permissões e parcelas de imóveis.
- Publicação pendente: aplicar migrations em ordem até 016 e fazer deploy do frontend. Nenhuma alteração remota foi executada.

- Validação de navegador: 45 cenários passaram, incluindo quitação 370→369,12, fechamento sem débito do resíduo, corrigir/desfazer nas listas, erros visíveis e pagamento parcial explícito; três cenários adicionais passaram após destacar a quitação do resíduo. Compilação de produção passou. Correções de parcelas já quitadas preservam o vínculo com o financiamento original, inclusive após reconfiguração do imóvel; despesas variáveis mantêm atualização de previsões futuras.

## Clareza dos saldos e remoção de Total Parcial

- Identificada a diferença: Início usava caixa atual + pendências dos próximos 30 dias (apesar do título do mês); Transações usa entradas menos saídas dos registros exibidos, sem caixa inicial e com recorte de semana/filtros.
- Nova função pura monthlyCashOutlook utiliza o motor de projeção existente com prazo até o último dia do mês calendário. Calcula valores em centavos, desconta apenas o restante de pagamentos parciais, preserva compromissos vencidos, trata transferências agendadas e exclui investimentos/anotações de cartão do caixa.
- Cartão do Início renomeado para Saldo previsto em DD/MM, com data e base do cálculo claras. Receitas e despesas previstas usam o mesmo prazo. Transações identifica Saldo das transações e sua fórmula; Total Parcial removido, mantendo apenas três cartões de totais alinhados.
- Testes financeiros/tipos passaram, incluindo fim de mês, fevereiro bissexto, dezembro, registros pagos, parciais de 0,88, investimentos e transferências. Nenhum banco remoto alterado; não há nova migration nesta atualização.

- Validação final desta alteração: seis testes de navegador passaram (previsão mensal, filtros/totais, crédito e visualização em celular), além dos testes financeiros, tipos e compilação de produção. Interface sem Total Parcial inspecionada em 390px.

# Continuidade — Início, tema e categorias

- Retomado o pedido interrompido: Saldo Disponível sem subtítulo, remoção dos resumos Uso diário, Contas de despesas recorrentes e investimentos informativos. Contas de investimento têm painel próprio com total e saldo por conta.
- Início sem botões de edição, recebimento ou correção. Apenas Marcar pago em Vencimentos e Atrasos. Ações completas continuam em Transações.
- Tema pérola, azul profundo e champanhe, com fundo discreto, sombras, profundidade, transições entre abas e animações finitas nos ícones e gráfico. Movimento reduzido respeitado.
- Transações abre com Entradas e saídas, Categoria Todas e Status Todas, mostrando o mês completo. Semana atual em diante continua opcional.
- Edição permite trocar categoria com alcance individual ou próximos, incluindo recriação de recorrência. Categoria antiga preservada como opção; novas escolhas limitadas às categorias ativas do mesmo tipo e grupo. Migration 017 mantém permissões, revisão e repetição segura.
- Publicação: aplicar migrations pendentes em ordem, incluindo 016 e 017, e publicar frontend. Nenhuma alteração remota nesta etapa.

- Validação desta etapa: tipos, testes financeiros, PGlite 001–017 e instalador passaram. 46 cenários existentes de navegador passaram; o novo cenário de categoria/filtros passou após ajuste do rótulo acessível e navegação por teclado para evitar o indicador do servidor de desenvolvimento. Compilação final passou. Capturas móveis de Transações e Início inspecionadas.

# Continuidade — responsável, investimentos compactos e paleta ameixa

- Editar lançamento permite escolher Responsável entre os membros do grupo. Trocar pessoa limpa conta e cartão, solicitando uma conta da nova pessoa. Alcances individual e próximos preservados.
- Migration 018 grava responsável/conta/cartão juntos, com validação de grupo, revisão, repetição segura e preservação de pagamentos. Clientes antigos continuam usando o fluxo anterior quando não enviam responsável. Recorrências refeitas usam a nova pessoa.
- Contas de investimento fica depois do gráfico mensal e antes do patrimônio imobiliário. Cabeçalho compacto alinha título e total, com detalhes decorativos reduzidos no celular.
- Nova paleta ameixa, grafite e marfim, com dourado suave, aplicada ao login, navegação, saldos e temas claro/escuro.
- Publicação: aplicar somente migrations pendentes, incluindo 018, depois publicar frontend. Nenhuma atualização remota nesta etapa.

- Validação desta etapa: tipos, testes financeiros, banco PGlite com 001–018 e instalador passaram. 50 testes de navegador passaram, incluindo troca de responsável, limpeza de conta/cartão e alinhamento/posição do painel de investimentos. Capturas móveis, desktop, tema escuro e login inspecionadas. Compilação de produção passou.
