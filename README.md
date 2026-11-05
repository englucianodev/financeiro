# Finanças compartilhadas

Aplicação Next.js + Supabase com cinco telas: **Início, Pendências, Calendário, Contas e Mais**. Navegação, sessão e preferências persistem ao atualizar na mesma aba, por participante.

## Execução e implantação

1. Node.js 20.9+; execute `npm ci`.
2. Copie `.env.example` para `.env.local` com URL do Supabase e chave pública/anon/publishable. Nunca use `service_role` em `NEXT_PUBLIC_*`.
3. Configure Supabase Auth com Site URL e redirecionamentos do domínio.
4. **Banco com migrations 001–010:** revise e aplique somente `011_editable_categories.sql`. Se a 010 ainda não tiver sido aplicada, execute-a antes da 011. Se houver etapas anteriores pendentes, aplique-as primeiro, em ordem. Faça backup antes de atualizar banco publicado.
5. **Banco sem estrutura do aplicativo:** use `supabase/setup.sql` (001–011 em transação, com proteção contra instalação sobre tabelas existentes). Nunca use o instalador para atualizar banco existente.
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
- **Contas:** transferências imediatas ou agendadas e adicionar/editar nome, titular, finalidade, cor, saldo e preferência de conta principal. A opção de principal aparece somente no formulário. Ajustes de saldo são auditados. Conta com histórico, cartão ou transferência preserva o titular; crie outra conta para outra pessoa.
- **Mais:** opções internas de Lançamentos, Planejamento, Histórico e Personalização. Cada opção exibe somente seus formulários. Planejamento reúne fluxo de caixa, cartões, patrimônio, relatórios e simulador; Personalização reúne categorias, nomes e convites.

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

Banco: PostgreSQL embarcado PGlite, migrations 001–011, RLS/RPCs, isolamento, preservação de legado, idempotência, edição auditada e recebimentos automáticos/correções. Playwright: API simulada e Edge no Windows; em outros sistemas instale Chromium. Testes locais não comprovam concorrência com múltiplas conexões nem a configuração remota do Cron.

## Limites

Recorrências sem término geram um ano, sem renovação automática do lote; com término, limite de cinco anos e 2.000 ocorrências. Relatórios por competência (vencimento), sem conciliação, paginação, exportação de relatórios ou reserva mínima configurável. O checklist é uma exportação textual específica das despesas do mês, independente dos filtros da tela.

Cadastros de investimentos continuam informativos e são apresentados separados das contas de investimento: não se somam os dois valores como se fossem patrimônio independente. O saldo bancário das contas classificadas como investimento fica fora do disponível e da projeção de caixa. Cron offline exige configuração explícita no Supabase, e permanece pendente de homologação no ambiente publicado.

## Senhas, edição de contas e categorias padrão

- Login com mostrar/ocultar senha e recuperação por e-mail. Alteração autenticada em Mais → Personalização → Senha e acesso. A rota `/redefinir-senha` valida o link e salva a nova senha no Supabase Auth. Configuração necessária de redirecionamentos, template e envio: `supabase/PASSWORD_SETUP.md`.
- A edição de conta abre em janela com foco no nome, cancelamento por Escape e retorno do foco. O movimento de hover nos cartões/botões foi estabilizado para evitar oscilação do cursor. Erros de saldo desatualizado continuam sendo tratados pelo servidor sem sobrescrever movimentações.
- Menu “+”: somente Despesa, Receita e Transferência. Transferências ficam na aba Contas; salário continua em Mais → Lançamentos.
- Migration 011 transforma as categorias padrão em registros editáveis por grupo, sem duplicar nomes já cadastrados. Novos grupos recebem a mesma lista inicial. Excluir uma categoria remove a opção dos cadastros, preservando os rótulos dos lançamentos históricos. Ela não reaparece pelo fallback do frontend. A migration não altera valores ou saldos.
