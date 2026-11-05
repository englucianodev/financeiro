# Finanças compartilhadas

Aplicação Next.js + Supabase para receitas, despesas, contas, cartões e projeções por participante e grupo. O cabeçalho usa os primeiros nomes cadastrados, sem nomes fixos. Perfis antigos identificados por e-mail aparecem como “Participante”; informe seu nome em Mais → Seu nome.

## Executar

1. Use Node.js 20.9+ e execute `npm ci`.
2. Copie `.env.example` para `.env.local`. Informe `NEXT_PUBLIC_SUPABASE_URL` e `NEXT_PUBLIC_SUPABASE_ANON_KEY` (chave pública/publishable ou anon; nunca service_role).
3. Prepare o banco conforme instruções abaixo.
4. Configure autenticação por e-mail no Supabase e execute `npm run dev`.

## Banco e atualização

- **Banco existente com migrations 001–007:** revise e execute `008_modernization.sql`, depois `009_scheduled_transfers.sql` no SQL Editor do Supabase ligado à Vercel. Faça backup antes de atualizar o ambiente publicado.
- **Banco novo:** execute `supabase/setup.sql`, que reúne 001–009 em uma transação. O script recusa instalar sobre estrutura existente. Nunca remova essa proteção para atualizar um banco.
- A migration 008 adiciona cores, categorias, recorrências, perfil e novos convites; a 009 adiciona transferências agendadas. Elas não apagam tabelas nem lançamentos.
- Convites antigos continuam aceitos pelo novo endpoint até sua expiração, uso ou revogação. Os endpoints antigos de convite ficam desabilitados para evitar contornar revogação e limites de tentativas. Atualize também o frontend.
- A API solicita atualização do cache ao terminar as migrations. Se necessário, execute `NOTIFY pgrst, 'reload schema';`.

## Funcionalidades

- Dashboard mobile com saldos real/projetado, receitas/despesas previstas, pendências prioritárias, resumo da semana, gráficos por conta e navegação inferior com ações rápidas.
- Tema claro/escuro, ícones Lucide, animações Motion, componente Button no padrão shadcn/ui e gráficos Recharts. Inclinação 3D discreta em contas somente com mouse; preferência por movimento reduzido respeitada.
- Nome dinâmico para qualquer quantidade de participantes. Conta principal sugerida conforme responsável e escolha manual preservada.
- Cores personalizadas salvas por conta e usadas em cartões, lançamentos, calendário, projeção e simulador.
- Cadastro específico de salário com dia de pagamento, início, fim opcional e previsões mensais. Meses curtos limitam o dia ao último disponível.
- Receitas/despesas avulsas, semanais, mensais, bimestrais, trimestrais, semestrais, anuais ou com intervalo personalizado em dias. Receitas não exigem imóvel; despesas mantêm vínculo opcional. Vínculos históricos foram preservados.
- Edição individual e atualização de valores futuros ainda não pagos, preservando confirmações. Despesas variáveis usam o último valor integralmente confirmado para estimar ocorrências futuras sem pagamentos.
- Categorias predefinidas e categorias personalizadas com ícone, cor, edição e desativação. Desativar ou renomear não apaga movimentações e não reescreve rótulos históricos.
- Projeção em seis blocos de 30 dias, de hoje até o 180º dia. Saldos acumulados nunca reiniciam entre blocos. Pendências atrasadas entram hoje.
- Calendário mensal com painel de todas as movimentações do dia; descrições compactas no desktop e indicadores no celular.
- Simulador até uma data, limitado a 365 dias, com saldo inicial, receitas, despesas, saldo final, gráfico, mínimos e resultados por conta/participante. Usa o mesmo motor do dashboard. Cenários hipotéticos ficam apenas em memória.
- Transferências imediatas e agendadas. Agendar não movimenta saldo real; a confirmação manual na data ou depois efetiva a operação. A projeção considera os dois lados sem alterar o consolidado.
- Cartões e compras parceladas, faturas, pagamentos integrais/parciais com conta/data/valor efetivos, estorno e auditoria por ledger. Compras e previsões não alteram saldo real.
- Convites aleatórios ou personalizados (8–64 letras/números/hífens), hash no banco, expiração de 1–168 horas, uso único, copiar/compartilhar e revogação. Entrar exige autenticação; dez tentativas inválidas por usuário/hora bloqueiam novas tentativas nessa janela. Sem limite fixo de dois participantes no novo fluxo.

## Testes

```sh
npm run typecheck
npm test
npm run test:db
node tests/setup.mjs
npm run test:e2e
npm run build
```

Banco testado em PostgreSQL embarcado PGlite, com RLS, RPCs, isolamento entre famílias, preservação de legado, salários/recorrências, meses curtos, valores variáveis, categorias, convites e transferências. Playwright usa API simulada, sessão em cookie e Edge no Windows; em outros sistemas instale Chromium (`npx playwright install chromium`). Porta de teste: 3100.

## Vercel

Importe o repositório Git, use preset Next.js e a pasta que contém `package.json` como Root Directory. Build: `npm run build`; saída automática. Configure as duas variáveis públicas antes do deploy. Ajuste Site URL e redirecionamentos do Supabase Auth para o domínio publicado. Publique o código junto das migrations e teste login, criação/convite, recebimento, pagamento, estorno e transferência em homologação.

## Limites atuais

- Recorrências sem término geram um ano de previsões; não há renovação automática em background. Com término, o limite é cinco anos e 2.000 ocorrências por cadastro. Personalizada significa intervalo em dias.
- Relatórios usam vencimento (competência); não substituem extrato por data/conta efetiva. O calendário não reconstrói saldos anteriores a hoje.
- Investimentos e imóveis continuam informativos. Investimentos não entram no saldo bancário; registre o resgate ao recebê-lo para evitar dupla contagem.
- Ainda não há conciliação, paginação, reserva mínima configurável ou exportação de relatórios. Faturas variam pelas compras cadastradas; ajustes devem corresponder a compras reais, sem criar outra despesa da mesma fatura.
- Testes locais não substituem homologação com autenticação real e concorrência entre conexões no Supabase hospedado.
- Esta modernização não executou migrations em dados reais nem publicou na Vercel.
