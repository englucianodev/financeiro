# Finanças compartilhadas

Aplicação Next.js + Supabase com cinco telas: **Início, Pendências, Calendário, Contas e Mais**. Navegação, sessão e preferências persistem ao atualizar na mesma aba, por participante.

## Execução e implantação

1. Node.js 20.9+; execute `npm ci`.
2. Copie `.env.example` para `.env.local` com URL do Supabase e chave pública/anon/publishable. Nunca use `service_role` em `NEXT_PUBLIC_*`.
3. Configure Supabase Auth com Site URL e redirecionamentos do domínio.
4. **Banco com migrations 001–015:** revise e aplique somente `016_effective_payments_and_undo.sql`. Se houver migrations anteriores pendentes, execute-as primeiro em ordem. Faça backup antes de atualizar banco publicado.
5. **Banco sem estrutura do aplicativo:** use `supabase/setup.sql` (001–016 em transação, com proteção contra instalação sobre tabelas existentes). Nunca use o instalador para atualizar banco existente.
6. Execute `npm run dev` ou publique na Vercel com preset Next.js, diretório contendo `package.json`, build `npm run build` e saída automática. Informe as duas variáveis públicas antes do deploy.

Nenhuma migration foi aplicada remotamente nesta implementação. A homologação no Supabase hospedado e o deploy na Vercel continuam necessários.

## Recebimentos automáticos

Receitas pendentes com vencimento até hoje são confirmadas automaticamente, pelo saldo restante, na conta prevista. Isso inclui receitas antigas atrasadas; revise as previsões antes de habilitar em produção. O worker usa a data de Fortaleza, bloqueio de cada lançamento e chave única no ledger para impedir crédito duplicado.

Com o app aberto, a conciliação roda ao carregar, voltar ao primeiro plano e a cada minuto visível. Para executar também com o celular/app fechado:

1. Habilite **Supabase Cron / pg_cron** em Integrations → Cron.
2. Depois da migration 010, execute `supabase/enable_income_cron.sql` como proprietário do banco no SQL Editor.
3. Verifique as execuções do job `finance-confirm-income` no painel Cron. O job chama o worker privado a cada cinco minutos; ele não é exposto aos usuários da API.

Referência: [Supabase Cron](https://supabase.com/docs/guides/cron/quickstart).

“Corrigir recebimento” altera valor/data com estorno e novo lançamento dentro de uma única transação, preservando o histórico. A correção permite datas até hoje. Estornar uma receita interrompe a confirmação automática dessa ocorrência; ela pode ser recebida manualmente depois, sem o cron desfazer o estorno.

## Organização das telas

- **Início:** pendências em atraso e do dia, sem filtros, além do saldo disponível sem contas de investimento, saldos separados de uso diário e despesas recorrentes; investimentos em menor destaque. Resumo de pagas/recebidas/atrasadas dos últimos cinco dias, anteriores em lista rolável, filtros, barras de entradas/saídas previstas e projeção por conta até uma data escolhida (até 365 dias).
- **Pendências:** próximos sete dias; filtro de atrasadas e filtros por nome/categoria, entrada/saída e mês. Outros dias ficam em lista rolável expansível. Totais de entradas, saídas, soma e saldo do filtro selecionado, com mês/ano em lista cronológica. Checklist do mês vigente disponível para copiar, baixar como TXT ou abrir o compartilhamento nativo e selecionar Telegram. O usuário escolhe a conversa e confirma o envio; nenhum bot ou credencial do Telegram é necessário.
- **Calendário:** quadros maiores, descrições sem valores, indicação de confirmação e painel com todos os compromissos do dia. Investimentos e transferências preservam identificação das contas.
- **Contas:** transferências imediatas ou agendadas dentro da edição da conta de origem e adicionar/editar nome, titular, finalidade, cor, saldo e preferência de conta principal. A opção de principal aparece somente no formulário. Ajustes de saldo são auditados. Conta com histórico, cartão ou transferência preserva o titular; crie outra conta para outra pessoa.
- **Mais:** opções internas de Lançamentos, Planejamento, Histórico e Personalização. Cada opção exibe somente seus formulários. Planejamento reúne fluxo de caixa, cartões, imóveis, relatórios e simulador; Personalização reúne categorias, nomes e convites.

Categorias são ordenadas alfabeticamente em português em cadastros, filtros e relatórios. Novas previsões exigem conta ativa do próprio responsável no frontend e no servidor. Pagamentos podem manter conta efetiva diferente da prevista, preservando o histórico.

As barras financeiras agregam previsões por dia, exibem apenas dias com movimentações e destacam déficit em qualquer conta disponível. Transferências internas entre contas disponíveis não viram receita/despesa no gráfico. Transferências entre conta disponível e investimento alteram somente a disponibilidade, sem duplicar o patrimônio.

## Funcionalidades preservadas

Nomes dinâmicos, tema claro/escuro, navegação acessível, animações e efeitos 3D leves com respeito a movimento reduzido. Conta principal sugerida conforme responsável. Salários e recorrências semanais, mensais, bimestrais, trimestrais, semestrais, anuais e intervalo em dias; edição individual/futura, variável estimado pelo último confirmado; cartão parcelado, pagamentos parciais, estorno e ledger. Categorias personalizadas com ícone/cor e desativação, convites com hash, uso único, expiração, revogação e limite de tentativas, grupos com mais de duas pessoas.

O simulador usa o mesmo motor de projeção, até uma data, com cenários hipotéticos em memória. Agendar transferências não altera o saldo real: confirmação manual efetiva os dois lados. Perfis antigos com e-mail aparecem como “Participante”; informe seu nome em Mais → Seu nome.

## Verificação

```sh
npm run typecheck
npm test
npm run test:db
node tests/setup.mjs
npm run test:e2e
npm run build
```

Banco: PostgreSQL embarcado PGlite, migrations 001–016, RLS/RPCs, isolamento, preservação de legado, idempotência, edição auditada e recebimentos automáticos/correções. Playwright: API simulada e Edge no Windows; em outros sistemas instale Chromium. Testes locais não comprovam concorrência com múltiplas conexões nem a configuração remota do Cron.

## Limites

Recorrências sem término geram um ano, sem renovação automática do lote; com término, limite de cinco anos e 2.000 ocorrências. Relatórios por competência (vencimento), sem conciliação, paginação, exportação de relatórios ou reserva mínima configurável. O checklist é uma exportação textual específica das despesas do mês, independente dos filtros da tela.

Cadastros de investimentos continuam informativos e são apresentados separados das contas de investimento: não se somam os dois valores como se fossem patrimônio independente. O saldo bancário das contas classificadas como investimento fica fora do disponível e da projeção de caixa. Cron offline exige configuração explícita no Supabase, e permanece pendente de homologação no ambiente publicado.

## Senhas, edição de contas e categorias padrão

- Login com mostrar/ocultar senha e recuperação por e-mail. Alteração autenticada em Mais → Personalização → Senha e acesso. A rota `/redefinir-senha` valida o link e salva a nova senha no Supabase Auth. Configuração necessária de redirecionamentos, template e envio: `supabase/PASSWORD_SETUP.md`.
- A edição de conta abre em janela com foco no nome, cancelamento por Escape e retorno do foco. O movimento de hover nos cartões/botões foi estabilizado para evitar oscilação do cursor. Erros de saldo desatualizado continuam sendo tratados pelo servidor sem sobrescrever movimentações.
- Menu “+”: somente Despesa, Receita e Transferência. Transferências ficam na aba Contas; salário continua em Mais → Lançamentos.
- Migration 011 transforma as categorias padrão em registros editáveis por grupo, sem duplicar nomes já cadastrados. Novos grupos recebem a mesma lista inicial. Excluir uma categoria remove a opção dos cadastros, preservando os rótulos dos lançamentos históricos. Ela não reaparece pelo fallback do frontend. A migration não altera valores ou saldos.

## Ajuste rápido de saldo e menu “+”

Em Contas, toque no valor exibido para abrir somente o campo Novo saldo, já focado. Salvar registra um ajuste no ledger e atualiza os saldos; Cancelar/Escape preservam o valor. A RPC da migration 012 modifica o saldo sem sobrescrever alterações concorrentes em nome, cor, titular ou finalidade. Mantém prevenção de duplicidade e rejeita saldo desatualizado.

O menu “+” fecha ao tocar/clicar fora, mover o foco para fora ou pressionar Escape. Tocar fora também continua executando a ação escolhida na tela; não há uma camada que bloqueie os outros controles.

## Formulário único, transferências pela conta e imóveis

- Mais → Lançamentos apresenta um único seletor Tipo: Despesa, Receita, Salário ou Investimento. Os campos aparecem conforme a opção. Salário mantém previsão mensal e dia de pagamento; investimento usa descrição, valor, responsável, tipo de investimento e data de disponibilidade.
- Os investimentos anteriores continuam cadastrados e aparecem ao selecionar Investimento. Esse cadastro é patrimonial/informativo, como antes: não debita contas nem gera receita/despesa. Para movimentar dinheiro, use transferências entre contas, inclusive contas classificadas como investimento.
- Para transferir, abra Contas → Editar na conta que vai enviar → Transferir. A origem fica fixa, e são informados valor, conta recebedora e data. O destino não pode ser a própria origem. Datas futuras preservam o agendamento; os agendamentos e sua confirmação ficam na edição da respectiva conta de origem.
- O atalho Transferência no “+” leva a Contas e orienta selecionar Editar na conta de origem. Não há formulário geral de transferências na tela.
- O quadro inicial se chama Vencimentos e Atrasos, sem subtítulo de prioridade/filtros.
- Planejamento → Imóveis substitui Patrimônio e contém apenas imóveis. Cada imóvel possui cidade, tipo Alugado/Próprio, status Quitado/Financiado, dívida em reais e parcelas pendentes em meses. Parcelas aparecem somente para Próprio + Financiado; imóveis quitados têm dívida zero, e as demais combinações não mantêm parcelas ocultas.
- A migration 013 preserva registros anteriores e vínculos de despesas com imóveis, adiciona os campos e RPCs com validação/RLS e evita cadastro duplicado de investimento em tentativas repetidas. Imóveis legados começam como Próprio/Quitado, dívida zero e cidade não informada; podem ser editados para completar os dados.

## Edição de lançamentos e parcelas dos imóveis

- Editar abre uma janela com conta, valor, vencimento e vínculo com imóvel. A conta deve pertencer ao responsável original. A opção Só este lançamento ou Este e os próximos vale para salvar e excluir. A exclusão pede confirmação, cancela previsões e conserva a auditoria.
- Alterar recorrência é opcional e aplica uma nova frequência a partir do lançamento selecionado. Aceita intervalo em dias/meses ou Sem repetição. Mantém lançamentos anteriores e pagamentos confirmados/parciais; substitui apenas as próximas previsões sem pagamento. Sem nova frequência, os lançamentos existentes são atualizados no alcance escolhido. Ao mover vencimentos mensais, o dia é limitado ao último dia de cada mês.
- Lançamentos pagos ou parcialmente pagos ficam protegidos contra edição/exclusão. Revisões desatualizadas são rejeitadas; novas tentativas com a mesma chave não duplicam lançamentos. Trocar a conta de uma previsão não movimenta saldo antes do pagamento.
- Início apresenta Saldo aplicado em imóveis: soma do valor estimado menos a dívida de cada imóvel Próprio. Alugado e Terceiro ficam fora desse resumo. Os três tipos continuam disponíveis no cadastro/edição de Imóveis e nos vínculos de despesas. Esse patrimônio não integra o saldo bancário disponível.
- Ao cadastrar ou editar uma despesa de imóvel Próprio + Financiado, marque Parcela do financiamento. O pagamento integral reduz uma parcela pendente; pagamentos parciais só reduzem quando completarem o valor. Cada ocorrência conta uma vez, mesmo após novas tentativas. Estornar devolve a parcela enquanto ainda for o mesmo financiamento. Gastos de manutenção e meses sem pagamento não reduzem parcelas automaticamente. Para despesas já cadastradas, vincule o imóvel e marque a opção na edição, inclusive Este e os próximos quando necessário.
- A baixa das parcelas não calcula amortização ou juros: a dívida em reais continua sendo informada na edição do imóvel conforme o saldo fornecido pela instituição financeira. Pagamentos históricos não recebem vínculo retroativo automático.
- Para publicar, aplique as migrations pendentes até 014 no Supabase e publique o frontend atualizado na Vercel. Não há novas variáveis de ambiente nesta alteração. O instalador `setup.sql` é somente para banco novo.

## Nova identidade, Transações e análise mensal

- Tema em azul profundo, verde e tons claros, com versão escura, botões alinhados e navegação adaptada ao celular. Login e título público: Finanças Compartilhadas. Rodapé com créditos a Luciano (@englucianodev), direitos reservados e links para GitHub e Instagram.
- Transações substitui Pendências. Uma única lista rolável mostra o mês completo, incluindo lançamentos pagos e pendentes. As setas trocam o mês e a seleção mensal persiste após atualizar. A lista tem altura limitada a no máximo dez linhas, reduzida à altura disponível no celular.
- Em Filtrar transações, pesquisar ou selecionar movimentação/categoria/status consulta todo o mês selecionado em ordem de vencimento. Status: A vencer (inclui hoje), Pagas, Atrasadas ou Todas; Semana atual em diante aplica um recorte opcional quando os outros filtros estiverem vazios. Pagas corresponde à liquidação integral ou à anotação Já pago no cartão. Pagamentos parciais continuam pendentes.
- Saldo das transações é entradas menos saídas dos registros filtrados; o campo Total Parcial foi removido. Entrada soma positivamente; Saída é apresentada negativa. O cálculo usa o valor integral dos lançamentos mostrados, incluindo os pagos; valores pagos/restantes de um pagamento parcial aparecem como informação na linha. Totais são calculados em centavos. Não há contagem de lançamentos ou mês/ano abaixo do resumo. Nova transação abre o formulário unificado em Mais.
- O resumo da semana não tem filtros: lista apenas pagamentos/recebimentos e atrasos dos últimos cinco dias. O saldo aplicado em imóveis próprios fica ao final do Início.
- O gráfico diário e a projeção por conta foram retirados do Início. Seu mês em números apresenta despesas por categoria, cores distintas, valores e percentuais. Entradas e saídas indica déficit, sobra ou equilíbrio. Usa o valor integral de lançamentos não cancelados por vencimento, pagos e previstos; não soma saldo bancário inicial nem transferências internas. Meses do gráfico e de Transações são independentes e persistem.

## Despesas no cartão e transferências retroativas

- Marque Pagamento no cartão de crédito no cadastro ou edição da despesa, escolhendo Será pago no cartão ou Já pago no cartão e, opcionalmente, um cartão do responsável. Use para valores que já fazem parte de uma fatura cadastrada. É uma anotação: não cria compra/parcelamento/fatura nem movimenta saldo bancário.
- Esses registros permanecem identificados em Transações, mas ficam fora dos totais de despesas, projeções, relatórios, gráfico mensal e checklist para não duplicar a fatura. O pagamento bancário individual fica bloqueado no servidor. Pagar a fatura continua sendo a movimentação financeira. Não é possível marcar parcelas da própria fatura ou despesas já pagas por conta bancária como anotações de crédito. Estorne primeiro um pagamento bancário indevido antes de trocar sua forma de pagamento.
- A opção pode ser alterada com o alcance Só este lançamento ou Este e os próximos. As mesmas proteções de revisão, permissão e repetição de requisições são mantidas. Marcar Já pago no cartão registra a data da anotação para o resumo da semana; não equivale ao pagamento bancário da fatura.
- Em Contas → Editar conta de origem → Transferir, datas anteriores e a data de hoje registram a transferência imediatamente; datas futuras são agendadas. O banco guarda a data efetiva escolhida e mantém o horário real de registro no ledger para auditoria. O saldo atual é atualizado, sem reescrever lançamentos históricos. Confirmar um agendamento vencido preserva sua data prevista como data efetiva.
- Publicação: aplicar migrations anteriores pendentes e `015_credit_annotations_and_dated_transfers.sql`, depois publicar o frontend na Vercel. O instalador 001–015 é somente para banco novo. Nenhuma nova chave ou configuração Auth é necessária.

## Erro de API desatualizada no ajuste rápido de saldo

O saldo clicável usa `adjust_account_balance`, da migration 012. A mensagem genérica da interface também cobre outros erros de tabela/função ausente; confirme a chamada original nos logs da API quando necessário.

No SQL Editor do mesmo projeto Supabase configurado na Vercel, execute `supabase/repair_balance_adjustment.sql`. O reparo restaura a função e suas permissões e envia `NOTIFY pgrst, 'reload schema'`. Pode ser repetido sem modificar saldos, contas ou lançamentos. Exige a base das migrations anteriores, incluindo 010; se ela faltar, interrompe antes de fazer alterações e orienta aplicar as pendências em ordem. Atualize a página após a execução. Um deploy da Vercel não instala funções no banco.

Verificação local do reparo: `node tests/setup.mjs`, incluindo função removida, repetição do reparo, permissões, preservação do saldo e ajuste posterior auditado sem duplicidade.

## Quitação por valor efetivo, correção e desfazer

- Marcar pago usa o valor efetivo como quitação por padrão. Exemplo: previsão R$ 370,00 e pagamento R$ 369,12 resultam em lançamento quitado com valor R$ 369,12 e débito de R$ 369,12. A diferença não vira pendência. Um valor maior também ajusta a despesa ao total real.
- Pagamento parcial só ocorre ao marcar explicitamente Pagamento parcial (manter restante pendente). O campo de restante é calculado em centavos, evitando valores como 0,879999999 e bloqueios por validação decimal do navegador.
- Para resíduos anteriores, abra Marcar pago e escolha Quitar pelo valor já pago. O total da transação é ajustado ao que já foi confirmado, sem outro débito, preservando pagamentos e datas. Não há correção automática dos resíduos na migration, pois podem existir parcelamentos/pagamentos parciais intencionais.
- Corrigir pagamento aparece nas despesas que têm algum valor pago, tanto no Início/Transações quanto em Mais → Histórico. Informe o total efetivamente pago e a data. O servidor estorna os pagamentos anteriores e registra o valor corrigido na conta selecionada; a diferença é refletida no saldo. Quando há pagamentos em várias contas, é necessário escolher explicitamente a conta final. As parcelas de imóveis permanecem contadas uma única vez.
- Desfazer pagamento pede confirmação, devolve às contas de origem exatamente o valor registrado e retorna a transação a pendente. Os registros anteriores são preservados como estornados. Recebimentos podem ser desfeitos; nesse caso, o valor é retirado da conta e a confirmação automática fica suspensa até novo registro manual. Anotações Já pago no cartão voltam a A pagar no cartão sem movimentação bancária.
- A nova RPC `manage_event_payment` verifica a revisão da transação, permissões, valores e datas e mantém as operações atômicas e repetíveis sem duplicidade. As rotas antigas de pagamento parcial e pagamento de fatura continuam disponíveis para integrações existentes.
- Publicação: aplique as migrations pendentes até `016_effective_payments_and_undo.sql`, depois publique o frontend atualizado na Vercel. A atualização não altera automaticamente pagamentos no banco publicado e não exige novas chaves.

## Saldo previsto e saldo das transações

- Início: o cartão Saldo previsto em DD/MM estima o dinheiro disponível no último dia do mês atual. Parte do saldo bancário atual (uso diário e contas recorrentes), soma os recebimentos ainda pendentes, subtrai o restante das despesas pendentes e considera transferências agendadas até essa data, inclusive compromissos vencidos. Investimentos e anotações de despesas já incluídas no cartão ficam fora desse caixa. Pagamentos já confirmados não são debitados novamente.
- A previsão anterior usava os próximos 30 dias apesar do título do mês; agora termina no último dia do mês calendário, inclusive fevereiro bissexto e dezembro. Os cartões de receitas/despesas previstas usam o mesmo prazo, indicado na descrição.
- Transações: Saldo das transações mostra somente entradas menos saídas dos lançamentos exibidos, considerando o mês e os filtros. Não inclui o dinheiro inicial das contas. Por padrão, a lista abrange o mês selecionado, com entradas e saídas, todas as categorias e todos os status. O gráfico mensal e o saldo das transações coincidem para o mesmo mês completo, sem filtros adicionais, pois ambos usam o valor integral dos lançamentos não cancelados e excluem anotações de cartão.
- Esses números têm finalidades diferentes e podem divergir. Exemplo: R$ 1.000 disponíveis e R$ 200 de despesas pendentes, sem receitas no mês, significam R$ 800 de caixa previsto e resultado de −R$ 200 nas transações.
- Total Parcial foi removido. Permanecem Entradas, Saídas e Saldo das transações, com indicação Entradas − saídas exibidas. Alteração somente no frontend; publicar por novo deploy na Vercel, mantendo as migrations anteriores em dia.

## Atualização: categorias e filtros iniciais

Transações inicia com entradas e saídas, todas as categorias e todos os status, exibindo todo o mês selecionado. O recorte semanal é opcional. Na edição, Categoria permite escolher uma categoria ativa do mesmo tipo ou manter a categoria original, inclusive quando inativa. O alcance individual ou dos próximos lançamentos também se aplica à categoria.

Aplique as migrations pendentes em ordem, incluindo `016_effective_payments_and_undo.sql` e `017_event_categories.sql`, antes de publicar o frontend. `setup.sql` inclui 001–017 e é somente para instalações novas.

O Início usa um painel destacado para contas de investimento e mantém somente Marcar pago em Vencimentos e Atrasos; ações de edição e recebimento estão em Transações. Tema claro e escuro com movimentos sutis, desativados quando o sistema solicita movimento reduzido.

## Alterar responsável e organização do Início

Em Transações → Editar, selecione o Responsável e uma conta dessa pessoa. A troca limpa o cartão anterior; você pode escolher um cartão da nova pessoa quando aplicável. O alcance Só este lançamento ou Este e os próximos inclui o responsável. Previsões com pagamento bancário registrado continuam protegidas. A edição não movimenta o saldo.

O painel compacto Contas de investimento aparece depois do gráfico e antes de Saldo aplicado em imóveis. O sistema e o login usam a paleta ameixa, grafite e marfim, com tema escuro equivalente.

Para atualizar um banco existente, aplique as migrations pendentes em ordem, incluindo `018_event_owner.sql`, e publique o frontend. O instalador `setup.sql` inclui 001–018 e deve ser usado somente em banco novo.
