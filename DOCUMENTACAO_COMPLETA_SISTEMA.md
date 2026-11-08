# Finanças Compartilhadas — guia funcional e técnico para reconstrução

> Elaborado em 08/11/2026 a partir do código local, incluindo migrations 001–022. Explica a implementação encontrada e propõe um roteiro para criar outra aplicação no Codex. Não confirma configuração do banco publicado, deploy, integrações externas ou execução atual dos testes. Não contém credenciais ou dados reais.

## 1. Objetivo e conceitos fundamentais

O sistema organiza finanças de uma família/grupo: participantes compartilham contas, receitas, despesas, cartões, patrimônio e planejamento. Apesar do diretório `financas-a-dois`, admite mais de duas pessoas.

Responde quanto existe disponível, o que falta pagar/receber, como ficará o caixa e como despesas/patrimônio estão distribuídos. A reconstrução precisa separar:

- **Previsão:** compromisso pendente/futuro; cadastro não altera saldo real.
- **Consumo:** despesa econômica, inclusive parcela de compra no cartão; alimenta categorias/relatórios.
- **Caixa:** entrada/saída de dinheiro em conta; compra no cartão não debita banco, pagamento da fatura debita.

Misturar essas dimensões duplica despesas e produz saldos incorretos.

## 2. Como foi elaborado e arquitetura

O código mostra evolução incremental: grupos/contas/eventos; segurança e ledger; planejamento e pagamentos parciais; recorrências/transferências; edição e patrimônio; crédito completo; importação; e-mail; PDFs protegidos e estornos.

Essa evolução é demonstrada pelas migrations e convivência de estruturas antigas/novas. Não é possível deduzir todos os prompts originais, autoria ou decisões não registradas. Aqui se explica a arquitetura observável.

A interface usa Next.js/React. O cliente consulta Supabase e chama funções PostgreSQL por RPC. Regras financeiras críticas ficam no banco: uma operação pode validar permissão, bloquear registros, registrar pagamento, lançar débito e atualizar situação na mesma transação. Rotas Next.js no servidor atendem integrações com segredos, como e-mail e abertura de PDF protegido.

| Camada | Tecnologia declarada em package.json | Papel |
| --- | --- | --- |
| Aplicação | Next.js ^16.4.5, React ^19.0.0, TypeScript ^5.8.0 | Rotas, componentes e tipos |
| Dados/acesso | Supabase JS ^2.49.0, SSR ^0.6.1, PostgreSQL | Auth, consultas, RPC e RLS |
| Interface | Tailwind ^3.4.0, CSS, Lucide, Motion | Layout, temas, ícones e animações |
| Gráficos | Recharts ^3.10.1 | Visualização financeira |
| Arquivos | PDF.js ^6.5.438, Tesseract ^6.0.1, idioma português | Extração e OCR |
| PDF no servidor | @napi-rs/canvas e criptografia Node.js | Renderização e senha |
| Testes | PGlite, Playwright e scripts Node.js | Regras, banco descartável e navegador |
| Infraestrutura prevista | Vercel, Supabase, Resend opcional | Aplicação, banco e e-mail |

São intervalos declarados, não confirmação das versões instaladas. O lockfile orienta instalação reproduzível. `AGENTS.md` manda consultar documentação local do Next.js antes de alterar código dessa versão.

```text
Usuário → React → Supabase → Auth / consultas com RLS
                         → RPC PostgreSQL
                            → validações e bloqueios
                            → registros + ledger + auditoria
                            → retorno e atualização da interface

Cron → POST /api/notifications → Supabase administrativo → Resend
PDF protegido → POST /api/statements/unlock → abertura → texto/imagens
PDF comum / CSV / OFX → leitura no navegador → revisão → RPC de importação
```

Não existe backend REST separado para cada cadastro. Uma parte fundamental do backend são os arquivos SQL.

## 3. Acesso, sessão e família

`components/login-panel.tsx` reúne acesso/cadastro e recuperação. Campos permitem mostrar/ocultar senha. Alteração autenticada fica em `password-management.tsx`; `/redefinir-senha` trata recuperação e salva pelo Supabase Auth. URLs/template/configuração estão em `supabase/PASSWORD_SETUP.md`.

A aplicação restaura sessão via `getSession` e `onAuthStateChange`, trata recuperação e evita que respostas antigas substituam sessão/dados atuais. Trocar usuário limpa os dados financeiros em memória.

Sem grupo, usuário informa nome e cria família ou aceita código. Convites usam hash, expiração, uso único, revogação e limite de tentativas. Nomes compõem o título. Isolamento é por família: titular de conta/cartão não cria área privada dentro do grupo.

## 4. Telas e funcionalidades

### 4.1 Início

Saldo disponível, entradas/saídas pendentes até o fim do mês e saldo projetado. Contas de investimento ficam fora do disponível. Atrasados entram na projeção de hoje.

Mostra vencimentos/atrasos, resumo recente dos últimos cinco dias, análise mensal por categoria, cartões, contas de investimento e patrimônio líquido em imóveis próprios. Análise mensal usa competência/vencimento e consumo; não é extrato bancário. Seu mês é independente de Transações.

### 4.2 Transações

Lista o mês escolhido com navegação mensal, pesquisa, categoria, entrada/saída e situação: pagas, atrasadas, a vencer ou todas; há recorte da semana atual em diante. Ordena por data/descrição em português, com altura limitada e rolagem.

Totais usam valores integrais dos registros classificados como consumo, incluindo pagos. Parcial mostra pago/restante e permanece pendente. Fatura aparece como consolidação de caixa sem repetir consumo de compras.

Ações encaminham cada origem ao fluxo correspondente: despesa, recebimento, fatura, obrigação ou compra. `transaction-actions.tsx` inclui criação e estorno por cartão.

Checklist mensal de despesas de caixa pode ser copiado, baixado TXT ou compartilhado pelo sistema operacional. Para Telegram, usuário escolhe conversa/confirma; não existe bot.

### 4.3 Calendário

Compromissos mensais e detalhes do dia. Quadrados priorizam descrição, confirmação e identificação de conta, indicando mais itens quando necessário. Inclui eventos bancários, transferências, faturas, obrigações e fechamento. É visualização; não confirma pagamento automaticamente. Usa eventos persistidos e virtuais de crédito.

### 4.4 Contas

Cadastro/edição de nome, titular, cor, finalidade, saldo e principal. Finalidades: uso diário (`checking`), despesas recorrentes (`recurring`) e investimento (`investment`). Conta principal é sugerida pelo responsável.

Clicar no saldo abre ajuste rápido: registra diferença no ledger, rejeita saldo desatualizado e não sobrescreve campos concorrentes. Conta com histórico/cartão/transferência conserva titular; outro titular exige outra conta.

Transferir começa na edição da origem: valor, destino e data. Contas diferentes obrigatórias. Passado/hoje efetivam imediatamente; futuro agenda. Confirmar agendamento movimenta ambos os lados preservando data prevista. Agendamento não muda saldo real.

Transferência entre contas disponíveis não é receita/despesa. Aplicação/resgate entre disponível e investimento muda disponibilidade sem duplicar patrimônio.

### 4.5 Mais, histórico e personalização

Reúne Lançamentos, Planejamento, Histórico e Personalização. Histórico oferece correção/desfazer; trilha completa também existe em pagamentos, ledger e auditorias.

Personalização reúne categorias, nome, convites, senha e e-mail. Categoria tem nome, tipo, ícone, cor e ativação; excluir/desativar retira opções preservando rótulos históricos. Ordenação em português.

Tema usa `localStorage`; navegação/períodos/rolagem usam `sessionStorage` por usuário/grupo/tela. Persistir interface não oferece operação financeira offline. Há teclado, Escape, controle de foco e respeito a movimento reduzido.

## 5. Lançamentos, pagamentos e recorrências

### 5.1 Formulário unificado

`entry-form.tsx`: Despesa, Receita, Salário, Investimento e Lançar no cartão. Campos variam por tipo.

Receita/despesa tem descrição, valor, responsável, conta ativa do responsável, data, categoria e recorrência. Despesa pode ter valor variável, imóvel, parcela de financiamento e anotação legada de crédito.

Recorrências: avulsa, semanal, mensal, bimestral, trimestral, semestral, anual ou intervalo em dias. Sem término gera um ano; com término, regras bancárias limitam cinco anos e 2.000 ocorrências. Não há renovação infinita automática do lote. Salário gera mês a mês no dia indicado, limitado ao último dia do mês.

Investimento cadastral tem nome, tipo Poupança/CDB/Outros, valor, responsável e liquidez opcional. É informativo: não debita conta. Aplicação/resgate efetivos usam transferências.

### 5.2 Quitação, parcial, correção e estorno

Conta prevista é separada da efetiva. Histórico conserva essa distinção conforme validações da operação.

Quitação por valor efetivo ajusta previsão ao real: previsto R$ 370,00 e pago R$ 369,12 resulta em quitação/débito de R$ 369,12. Diferença não vira pendência. Para manter restante, marcar pagamento parcial explicitamente. Valor maior também pode ajustar quitação.

Correção preserva histórico e grava compensação/novo movimento transacionalmente. Desfazer estorna sem apagar ledger. UUIDs de requisição evitam duplicação em novas tentativas.

### 5.3 Recebimento automático

Receitas com vencimento até hoje podem ser confirmadas pelo restante na conta prevista. Atualização do app executa rotina; Cron opcional permite app fechado. Inclui atrasadas antigas, exigindo previsões corretas antes da ativação. Estornar suprime reconfirmação daquela ocorrência; recebimento manual continua possível. Bloqueios/chave única impedem crédito duplicado.

### 5.4 Edição e cancelamento

Editor altera conta, valor, vencimento, categoria, imóvel e opções compatíveis. Alcance: só ocorrência ou ela e próximas. Alterar recorrência substitui previsões futuras elegíveis sem pagamento e preserva anteriores/confirmadas/parciais. Datas mensais limitadas ao fim do mês.

Pagamento existente protege contra edição/exclusão indevida. Revisões desatualizadas falham. Excluir cancela previsão preservando auditoria. Mudar conta prevista não movimenta saldo.

## 6. Planejamento e patrimônio

**Fluxo de caixa:** projeção diária por conta/pessoa com gráfico/tabela. Usa saldos atuais, restantes pendentes e transferências previstas. Investimentos ficam fora. Motor aceita até 365 dias.

**Cartões anteriores:** cadastro/parcelamentos antigos preservados. Cartão revisado no módulo novo não deve receber compras pelo fluxo antigo.

**Imóveis:** nome, cidade, Próprio/Alugado/Terceiro, valor, Quitado/Financiado, dívida e parcelas quando aplicável. Patrimônio = valor estimado menos dívida dos próprios; separado do disponível.

Despesa marcada parcela de financiamento reduz uma parcela ao completar pagamento integral. Parcial só reduz ao completar; estorno pode devolver sob as condições do mesmo financiamento. Não calcula juros/amortização nem atualiza dívida em reais automaticamente: valor informado conforme banco.

**Relatórios:** período, pessoa, conta, categoria, imóvel, cartão e natureza realizada/prevista. Competência e consumo sem repetir fatura. Não é conciliação bancária completa.

**Simulador:** receitas/despesas/transferências hipotéticas em memória, até uma data, com saldo final, primeiro déficit e menor saldo por conta. Usa motor compartilhado; não grava cenários.

## 7. Cartões completos

### 7.1 Cadastro e limite

Titular, conta, emissor, bandeira, últimos quatro dígitos, limite, fechamento, vencimento, cor, débito automático e situação ativo/bloqueado/arquivado. Adicional aponta ao principal, compartilhando limite/fatura/pagamento. Responsável pela compra pode diferir do titular. Conta válida de pagamento pertence ao titular do principal.

Limite considera principal restante de todas as parcelas, inclusive futuras e legado compatível. Encargos separados: pagar juros não libera principal. Indicar débito automático não confirma pagamento.

### 7.2 Compra, obrigação e recorrência

Compra gera aquisição/parcelas em faturas sem débito bancário. Até 120 parcelas. Divisão em centavos com resíduo na última: 100 em três = 33,33 + 33,33 + 33,34.

Parcelamento em andamento exige total original, quantidade total, próxima parcela e primeira fatura. A partir de 5/12 gera somente 5–12, sem inventar pagamentos anteriores.

Obrigação manual é previsão, só vira compra ao Lançar no cartão com data/valor reais; antes não usa limite nem cria cobrança efetiva. Automática futura fica prevista; devida pode virar cobrança no carregamento/worker. Falta de limite/cartão inválido mantém pendência com causa.

Recorrências: valor, modo, período dias/meses, início/fim, ativo/pausado/encerrado e variável. Geração única por regra/data. Mudança estrutural preserva histórico e substitui previsões elegíveis. Cron gera cobranças, nunca paga fatura.

### 7.3 Ciclos e operações

Compra no fechamento vai ao ciclo seguinte. Dias 29–31 se ajustam ao fim do mês. Ciclo usa mês de fechamento; vencimento pode ser no seguinte. Editar cartão não altera datas de faturas existentes.

Fatura consolida principal, encargos, estornos, descontos, crédito e ajustes. Situações derivadas: aberta, fechada, vencida, parcial, paga e crédito. Pagar debita conta e aloca por linha, encargos primeiro.

Operações: juros/multa informados, estorno, antecipação com desconto, crédito entre faturas do mesmo principal, desfazer com compensação. Estorno não é depósito bancário. Estorno por cartão pode vincular compra, valida acumulado e bloqueia repetição equivalente.

### 7.4 Legado e eventos virtuais

Coexistem `card_purchases`/`financial_events`, anotações `credit_state` e tabelas novas `cc_*`. Anotação Será pago/Já pago no cartão não cria compra/fatura, não usa limite e fica fora de totais para não repetir fatura existente. Já pago não confirma débito bancário. Não converter automaticamente anotações em compras.

`creditEvents` deriva eventos virtuais, sem copiar para `financial_events`:

| Origem | Papel |
| --- | --- |
| cc_invoice | Fatura consolidada: caixa, sem repetir consumo |
| cc_obligation | Previsão de consumo/caixa até lançamento |
| cc_charge | Compra/parcela: consumo sem débito individual |
| cc_closing | Marcador de fechamento |

`cc_charge` com `settled` significa compra lançada, não fatura paga. A alternativa pode usar estados mais explícitos.

## 8. Importação, ajustes e PDF protegido

CSV, OFX e PDF textual/digitalizado. Limites: 15 MB, 30 páginas, 1.000 linhas. CSV Data/Descrição/Valor e ID opcional; OFX diferencia débitos/créditos; PDF depende do layout. OCR português usa recursos servidos localmente.

Fluxo: cartão/fatura → leitura e SHA-256 → extração → comparação → revisão → decisão importar/vincular/descartar por linha → conferência → transação.

Ler não grava compras. Data incompleta, parcela e total original exigem revisão. Semelhança não comprova duplicidade. Mesmo arquivo/cartão e IDs bancários repetidos têm proteção. Falha reverte lote. Histórico registra metadados/contagens/decisões.

Ajustar total real cria complemento/redução em Ajuste de Fatura sem alterar compras ou saldo bancário. Reverter cria compensação. Após ajuste, preservar total durante importação exige escolha explícita e conciliação transacional.

PDF comum é lido no navegador. Protegido é exceção: arquivo vai à rota autenticada `/api/statements/unlock`, que valida cartão, abre por PDF.js e retorna texto/imagens para OCR no cliente. Portanto, nem todo PDF permanece apenas no navegador.

Senha opcional fica em `card_pdf_passwords` por usuário/cartão, AES-256-GCM, IV aleatório e autenticação associada ao usuário/cartão. Chave Base64 de 32 bytes só no servidor. Senha aberta não retorna ao cliente. Tabela sem acesso direto de usuários comuns. Alterar/perder chave afeta recuperação das senhas guardadas.

## 9. E-mail

Configuração por grupo: adesão, membros destinatários, horários manhã/noite, dias, fuso, feriados nacionais e datas adicionais. Padrão desabilitado/sem destinatários, 08:00/20:00, segunda–sexta, America/Fortaleza.

Cron chama POST `/api/notifications` com Bearer secreto comparado por `timingSafeEqual`. Servidor calcula janela, consulta pendências atuais e envia por Resend a e-mails confirmados de membros selecionados, consultados no servidor. Sem pendências não envia. Snapshot inclui despesas, faturas e obrigações relevantes sem repetir compras.

Chave única grupo/pessoa/data/horário, lease, payload persistido, idempotência do provedor e histórico reduzem duplicações. Janela local de dez minutos. Sem garantia absoluta de entrega única/minuto exato entre serviços.

Depende de DNS/domínio, credenciais, aplicação e agendador. Verificar cotas/preços ao implantar. Não há Open Finance, push ou Telegram bot.

## 10. Dados e integridade

| Domínio | Entidades centrais |
| --- | --- |
| Identidade | auth.users, households, household_members, household_invites |
| Caixa | financial_accounts, account_ledger, financial_transfers, scheduled_transfers |
| Compromissos | financial_events, event_payments, event_audit |
| Classificação/bens | categories, properties, investments |
| Legado crédito | credit_cards, card_purchases, invoice_payments |
| Crédito atual | cc_invoices, cc_recurrences, cc_obligations, cc_purchases, cc_lines |
| Pagamento crédito | cc_payments, cc_allocations, cc_requests, cc_audit |
| Importação | cc_imports, cc_invoice_targets, cc_adjustment_reversals |
| E-mail | notification_settings, notification_deliveries |
| PDF | card_pdf_passwords |

Campos mudam nas migrations; primeiro CREATE TABLE não é esquema final. Inventário ao final inclui auxiliares.

Regras fundamentais:

1. Isolamento `household_id`, RLS e validação de membro; filtro de tela não substitui autorização.
2. Dinheiro no banco `numeric(16,2)`, cálculos relevantes em centavos com arredondamento explícito.
3. Ledger com chave única conta/operação, saldo atualizado pelo banco e correções compensatórias.
4. Operações compostas transacionais, bloqueios e revisão/valor esperado conforme RPC.
5. UUID idempotente não repete efeito; reutilização com outro conteúdo deve falhar.
6. Validar grupo, titularidade, conta ativa, estado, datas, valor e vínculos.
7. Cancelar/estornar preserva trilha. Previsão não muda dinheiro antes da efetivação.
8. Helpers privilegiados internos não ficam abertos aos clientes; escrita direta depende de permissões.

Exemplos obrigatórios na alternativa:

- Saldo 1.000 + previsão despesa 100: real 1.000, projeção 900. Pagar torna real 900 e não desconta previsão outra vez.
- Compra cartão 300: consumo por parcelas, caixa inalterado. Pagar fatura debita 300 sem criar novamente consumo.
- Transferir 200 entre disponíveis mantém total; para investimento reduz disponível e preserva dinheiro no destino.
- Repetir mesma confirmação não cria outro pagamento; desfazer compensa.

## 11. Organização dos arquivos

| Arquivo/grupo | Responsabilidade |
| --- | --- |
| app/page.tsx | Sessão, família, carregamento, abas, diálogos e atualização |
| app/layout.tsx e app/globals.css | Estrutura e identidade visual |
| app/redefinir-senha/ | Recuperação |
| app/api/notifications/route.ts | Integração segura de e-mail |
| app/api/statements/unlock/route.ts | Abertura autenticada de PDF |
| components/entry-form.tsx | Cadastro unificado/recorrência |
| components/event-editor.tsx e payment-dialog.tsx | Edição e pagamento |
| components/movement-list.tsx e transaction-actions.tsx | Lista/filtros/checklist/ações |
| components/accounts-panel.tsx | Contas/saldo/transferências |
| components/credit-module.tsx e credit-fields.tsx | Crédito novo/anotação antiga |
| components/statement-tools.tsx | Importação/revisão/ajuste |
| components/planning.tsx e properties-panel.tsx | Planejamento/imóveis |
| components/monthly-overview.tsx e finance-visuals.tsx | Indicadores/gráficos |
| components/preferences.tsx e email-settings.tsx | Personalização/e-mail |
| components/login-panel.tsx e password-*.tsx | Acesso/senha |
| lib/supabase.ts | Cliente e cookies Supabase |
| lib/money.ts | Dinheiro, datas e projeção |
| lib/finance-view.ts | Filtros, totais e consumo/caixa |
| lib/credit.ts | Tipos, limite, ciclos e eventos virtuais |
| lib/statements.ts, statement-file.ts e pdf-layout.ts | Parser/leitura/comparação/texto |
| lib/pdf-password.ts e email-notifications.ts | Criptografia/horários/conteúdo |
| lib/identity.ts, errors.ts e use-view-state.ts | Nomes/mensagens/navegação |
| supabase/migrations/ | Backend transacional versionado |
| supabase/setup.sql | Instalador 001–022 para banco vazio |
| scripts/prepare-readers.mjs | Prepara workers/WASM/idioma antes de dev/build |
| tests/ e playwright.config.mjs | Regras, banco e navegador |
| docs/, README.md e CODEX_TAREFAS.md | Contexto/entregas históricas |

Arquivos agrupados na mesma célula seguem o diretório do primeiro quando aplicável. A tela atualiza ao abrir, voltar ao primeiro plano e a cada minuto visível, evitando certas atualizações durante ações. Versões de carregamento/usuário protegem contra respostas antigas. Não equivale a assinatura realtime ou modo offline.

Funções-chave: `project` projeta saldo; `transferFlows` representa transferência; `monthlyCashOutlook` resume mês; `isCashEvent`/`isConsumptionEvent` impedem dupla contagem; `transactionView` filtra; `monthlySummary` agrega categorias; `propertyEquity` calcula imóveis; `invoiceCycle`/`estimatedDue` calculam ciclos; `cardLimit` mede limite; `creditEvents` adapta crédito; parsers extraem/comparam linhas; `dueSlots` calcula janela; `sealPassword`/`openPassword` protegem senha.

## 12. Evolução das migrations

| Migration | Evolução |
| --- | --- |
| 001 | Famílias, contas e eventos |
| 002 | Segurança, convite e ledger |
| 003 | Planejamento, patrimônio e crédito antigo |
| 004 | Pagamento parcial |
| 005 | Integridade |
| 006 | Pagamento de fatura antiga |
| 007 | Contas |
| 008 | Modernização |
| 009 | Transferência agendada |
| 010 | Contas e recebimentos |
| 011 | Categoria editável |
| 012 | Ajuste rápido de saldo |
| 013 | Imóveis/investimentos |
| 014 | Edição e parcelas imobiliárias |
| 015 | Anotações de crédito e transferências datadas |
| 016 | Quitação efetiva, correção e desfazer |
| 017 | Categorias nos eventos |
| 018 | Responsável nos eventos |
| 019 | Crédito completo |
| 020 | Importação/ajustes |
| 021 | E-mail |
| 022 | Senhas de PDF e estorno por cartão |

Funções posteriores substituem/encapsulam anteriores. Contrato ativo depende da sequência e grants/revokes. Documentos antigos mencionam instalação até 016, 019 ou 021; instalador atual observado declara 001–022. Confirmar migrations aplicadas no destino.

## 13. Configuração e execução

| Variável | Uso |
| --- | --- |
| NEXT_PUBLIC_SUPABASE_URL | Projeto Supabase |
| NEXT_PUBLIC_SUPABASE_ANON_KEY | Chave pública; autorização depende de RLS |
| SUPABASE_SERVICE_ROLE_KEY | Só servidor, administração para e-mail/PDF |
| RESEND_API_KEY | Só servidor, envio |
| NOTIFICATIONS_FROM | Remetente verificado |
| NOTIFICATIONS_CRON_SECRET | Autenticação do agendador |
| APP_URL | URL nos e-mails |
| PDF_PASSWORD_ENCRYPTION_KEY | Só servidor, 32 bytes aleatórios em Base64 |

Copiar `.env.example` para `.env.local`. Não copiar segredos de produção para a alternativa. Chaves administrativas nunca recebem prefixo NEXT_PUBLIC.

1. Instalar Node compatível (README indica 20.9+) e `npm ci`.
2. Criar Supabase independente e configurar Auth/redirecionamentos.
3. Banco vazio: revisar/aplicar `supabase/setup.sql`. Banco existente: backup e somente migrations pendentes em ordem. Instalador protege contra estrutura existente.
4. Configurar variáveis e executar `npm run dev`.
5. Validar dados fictícios, compilar e publicar.
6. Configurar separadamente Cron de receitas, cartões e e-mails.

Scripts: `enable_income_cron.sql` (cinco minutos), `credit_enable_cron.sql` (horário) e `notifications_enable_cron.sql` (cinco minutos). Notificações exigem pg_cron/pg_net/Vault e segredos previstos no script. Sem agendador externo, rotinas dependentes da aplicação podem processar ao atualizar, mas não garantem app fechado.

`repair_balance_adjustment.sql` restaura RPC/permissões do ajuste e recarrega schema da API; não substitui migrations. `credit_diagnostic_before.sql` e `credit_validate_after.sql` apoiam diagnóstico do legado.

## 14. Testes existentes

| Comando | Finalidade |
| --- | --- |
| npm run typecheck | Tipos |
| npm test | Dinheiro, identidade, visões, crédito, parser e regras incluídas |
| npm run test:db | Migrations/regras em PGlite |
| npm run test:credit | Crédito/importação/ajustes no teste específico |
| node tests/setup.mjs | Instalador/proteção |
| npm run test:password | PDF protegido/rota |
| npm run test:e2e | Navegador com APIs simuladas |
| npm run build | Build e leitores |

Playwright cobre finanças, crédito e senha; configuração Windows usa Edge. Relatos nos documentos são históricos; este levantamento documental não reexecutou as suítes.

Aceitação mínima da alternativa: isolamento de famílias; titularidade; saldo versus ledger; quitação/parcial; estorno; idempotência; revisão concorrente; centavos; meses curtos; adicional; consumo versus caixa; parcela antiga; rollback de importação; PDF textual/OCR/protegido; horários de e-mail. PGlite/mocks não comprovam concorrência multiconexão, banco remoto ou entrega de e-mail.

## 15. Limitações e decisões para a alternativa

- Sem sincronização bancária direta; arquivos exigem revisão.
- Sem privacidade individual dentro da família; ACL nova exige projeto no banco.
- Sem paginação geral de históricos; carregamento pode crescer com volume.
- Sem operação financeira offline completa, exportação geral de relatórios ou conciliação bancária completa.
- Investimento cadastral e conta de investimento não são bens independentes para soma automática.
- Financiamento não calcula juros/amortização/saldo devedor automaticamente.
- Recorrência bancária usa lote limitado; crédito tem geração própria.
- Legado de cartões pode ser simplificado em banco novo; migração exige classificação de histórico.
- Coordenação concentrada em app/page.tsx e componentes extensos pode ser separada em módulos/hooks/serviços.
- Documentos antigos mencionam ausência de importação/e-mail; código 020–022 já inclui. Configuração remota não foi verificada.

## 16. Roteiro de reconstrução no Codex

Proposta para outra aplicação, não código já implementado:

1. Definir identidade visual, público e primeira versão. Criar repositório/banco independentes.
2. Modelar grupo, conta, evento, pagamento, transferência, ledger, auditoria e requisição idempotente. Validar isolamento.
3. Entregar caixa: login, contas, receitas/despesas, quitação/parcial, correção e estorno.
4. Adicionar recorrências, edição por alcance, transações, calendário, projeções e relatórios compartilhando cálculos.
5. Implementar crédito: principal/adicional, ciclos, parcelas, obrigações, faturas, limite, alocação e reversões. Separar consumo/caixa desde o início.
6. Adicionar patrimônio informativo, investimentos e imóveis.
7. Importação revisável e atômica: CSV/OFX, depois PDF/OCR/senha.
8. Automações idempotentes com histórico.
9. Homologar com dados fictícios, executar cenários, publicar e configurar integrações independentes.

Estrutura sugerida:

```text
src/app/                 rotas e composição
src/modules/             auth, households, accounts, transactions,
                         credit, planning, properties, imports, notifications
src/domain/              regras puras e tipos
src/services/            acesso a dados e contratos RPC
src/components/ui/       componentes compartilhados
supabase/migrations/     esquema, RLS, funções, triggers e permissões
tests/                   unidade, banco e navegador
```

Se trocar Supabase, substituir também Auth, isolamento, transações, jobs e segredos. Copiar somente telas perde parte essencial do comportamento.

### Prompt pronto para usar

```text
Crie uma aplicação alternativa de finanças compartilhadas usando este documento
como especificação. Use projeto e banco independentes. Leia tudo antes de
implementar e organize módulos/modelo. Separe previsão, consumo e caixa.

Implemente por etapas: autenticação/grupos; contas/ledger; receitas/despesas;
quitação efetiva/parcial e estorno; recorrências; transações/calendário;
projeções/relatórios; cartões completos; patrimônio; importação; notificações.

Operações financeiras compostas devem ser transacionais, autorizadas por grupo,
auditáveis, idempotentes e protegidas contra revisão concorrente. Use centavos
nos cálculos e decimal exato no banco. Compra no cartão não debita conta;
pagamento de fatura não duplica consumo; transferência interna não é receita.

Crie interface responsiva em português, reais, regra de datas America/Fortaleza,
temas claro/escuro e navegação acessível. Teste dados fictícios. Não presuma
integrações configuradas. Entregue migrations, variáveis sem segredos,
instruções de execução e testes dos cenários deste documento.

Em banco novo, simplifique caminhos legados sem perder regras atuais. Se houver
migração, planeje conciliação/preservação antes de converter anotações antigas.
```

## 17. Anexo: inventário técnico extraído dos arquivos

Nomes SQL podem representar versões históricas, sobrecargas e helpers internos. Para contrato ativo/argumentos/permissões, ler última definição, wrappers, GRANT e REVOKE na sequência das migrations. O inventário registra símbolos; as seções anteriores explicam comportamentos por domínio.

### 17.1 Tabelas por migration

- `001_initial.sql`: `households`, `household_members`, `financial_accounts`, `financial_events`, `financial_transfers`.
- `002_security_ledger.sql`: `household_invites`, `account_ledger`.
- `003_planning.sql`: `properties`, `investments`, `credit_cards`, `card_purchases`, `event_audit`.
- `004_partial_payments.sql`: `event_payments`.
- `006_invoice_payments.sql`: `invoice_payments`.
- `008_modernization.sql`: `categories`, `recurrence_requests`, `invite_attempts`.
- `009_scheduled_transfers.sql`: `scheduled_transfers`.
- `010_accounts_and_receipts.sql`: `account_edits`, `income_corrections`.
- `014_event_editing_and_property_installments.sql`: `property_installment_payments`, `installment_series_flags`, `event_series_rules`, `event_change_requests`.
- `015_credit_annotations_and_dated_transfers.sql`: `credit_annotation_requests`.
- `016_effective_payments_and_undo.sql`: `payment_action_requests`.
- `017_event_categories.sql`: `event_category_requests`.
- `019_credit_module.sql`: `cc_requests`, `cc_invoices`, `cc_recurrences`, `cc_obligations`, `cc_purchases`, `cc_lines`, `cc_payments`, `cc_allocations`, `cc_audit`.
- `020_statement_imports.sql`: `cc_imports`, `cc_invoice_targets`, `cc_adjustment_reversals`.
- `021_email_notifications.sql`: `notification_settings`, `notification_deliveries`.
- `022_pdf_passwords_and_refunds.sql`: `card_pdf_passwords`.

### 17.2 Funções SQL por migration

- `001_initial.sql`: `is_household_member`, `create_household`, `join_household`, `settle_event`, `transfer_funds`.
- `002_security_ledger.sql`: `create_invite`, `join_household`, `create_household`, `post_ledger`, `open_account_ledger`, `settle_event`, `reverse_event`, `transfer_funds`, `set_primary_account`.
- `003_planning.sql`: `create_card_purchase`, `create_series`, `edit_occurrence`, `audit_event`.
- `004_partial_payments.sql`: `pay_event`, `reverse_event`, `edit_occurrence`.
- `005_integrity.sql`: `default_primary_account`.
- `006_invoice_payments.sql`: `pay_invoice`.
- `007_accounts.sql`: `create_account`.
- `008_modernization.sql`: `set_account_color`, `rename_member`, `schedule_events`, `edit_future`, `estimate_variable`, `issue_invite`, `revoke_invite`, `accept_invite`.
- `009_scheduled_transfers.sql`: `schedule_transfer`, `execute_transfer`.
- `010_accounts_and_receipts.sql`: `save_account`, `validate_event_owner`, `suppress_reversed_income`, `post_due_income`, `confirm_due_income`, `correct_income`.
- `011_editable_categories.sql`: `seed_household_categories`, `seed_new_household_categories`, `delete_category`.
- `012_quick_balance.sql`: `adjust_account_balance`.
- `013_properties_and_investments.sql`: `save_property`, `register_investment`.
- `014_event_editing_and_property_installments.sql`: `property_financing_epoch`, `save_property`, `validate_event_revision`, `count_property_installment`, `schedule_events`, `get_event_recurrence`, `revise_events`.
- `015_credit_annotations_and_dated_transfers.sql`: `transfer_funds`, `execute_transfer`, `validate_credit_annotation`, `reject_credit_bank_payment`, `schedule_events`, `revise_events`.
- `016_effective_payments_and_undo.sql`: `manage_event_payment`.
- `017_event_categories.sql`: `revise_events`.
- `018_event_owner.sql`: `revise_events`.
- `019_credit_module.sql`: `cc_validate_card`, `cc_day`, `cc_cycle`, `cc_invoice`, `cc_post_purchase`, `cc_generate`, `cc_action`, `create_card_purchase`, `cc_audit_row`.
- `020_statement_imports.sql`: `cc_reconcile`, `cc_action`, `record_cc_import_error`.
- `021_email_notifications.sql`: `save_notification_settings`, `notification_snapshot`, `notification_claim`.
- `022_pdf_passwords_and_refunds.sql`: `cc_action`.

### 17.3 Exportações das bibliotecas

- `lib/credit.ts`: `emptyCredit`, `sumMoney`, `invoiceTotals`, `rootCard`, `cardLimit`, `invoiceCycle`, `estimatedDue`, `creditEvents`, `creditStatus`, `cardCategorySummary`.
- `lib/email-notifications.ts`: `nationalHoliday`, `dueSlots`, `emailText`.
- `lib/errors.ts`: `errorMessage`.
- `lib/finance-view.ts`: `cashDate`, `isCashEvent`, `isConsumptionEvent`, `eventIsPaid`, `weekStart`, `transactionView`, `propertyEquity`, `monthlyCashOutlook`, `alphabetic`, `moveMonth`, `monthLabel`, `monthlySummary`, `shiftDate`, `checklist`, `dailyMovements`.
- `lib/identity.ts`: `firstName`, `familyTitle`, `palette`, `defaults`.
- `lib/money.ts`: `brl`, `today`, `project`, `transferSuggestions`, `transferFlows`.
- `lib/pdf-layout.ts`: `statementPageText`.
- `lib/pdf-password.ts`: `sealPassword`, `openPassword`.
- `lib/statement-file.ts`: `readStatementFile`, `recognizeProtectedPages`.
- `lib/statements.ts`: `money`, `statementDate`, `installmentTotal`, `makeRow`, `parseStatement`, `compareRow`.
- `lib/supabase.ts`: `supabase`.
- `lib/use-view-state.ts`: `useViewState`, `validPeriod`, `validDate`, `validMonth`, `usePagePosition`.

### 17.4 Componentes e rotas

- `app/api/notifications/route.ts`
- `app/api/statements/unlock/route.ts`
- `app/layout.tsx`
- `app/page.tsx`
- `app/redefinir-senha/layout.tsx`
- `app/redefinir-senha/page.tsx`
- `components/accounts-panel.tsx`
- `components/credit-fields.tsx`
- `components/credit-module.tsx`
- `components/email-settings.tsx`
- `components/entry-form.tsx`
- `components/event-editor.tsx`
- `components/finance-visuals.tsx`
- `components/login-panel.tsx`
- `components/month-nav.tsx`
- `components/monthly-overview.tsx`
- `components/movement-list.tsx`
- `components/password-input.tsx`
- `components/password-management.tsx`
- `components/payment-dialog.tsx`
- `components/planning.tsx`
- `components/preferences.tsx`
- `components/properties-panel.tsx`
- `components/site-footer.tsx`
- `components/statement-tools.tsx`
- `components/transaction-actions.tsx`
- `components/ui/button.tsx`

### 17.5 Operações do despachante de cartões

`cc_action(p_id, p_household, p_action, p_data)` recebe UUID idempotente, grupo, ação e parâmetros JSON. Wrappers posteriores acrescentam capacidades e preservam implementação anterior como caminho interno restrito.

| Ação | Efeito |
| --- | --- |
| save_card | Criar/editar cartão e situação |
| purchase | Registrar compra/parcelas |
| obligation | Criar obrigação prevista |
| recurrence | Criar regra recorrente |
| confirm_obligation | Converter previsão em compra |
| edit_obligation / cancel_obligation | Alterar/cancelar obrigação elegível |
| edit_recurrence | Alterar regra, estado ou estrutura |
| pay_invoice | Debitar conta/alocar pagamento |
| fee | Juros/multa informados |
| refund / card_refund | Estorno por fluxo de fatura/cartão |
| anticipate | Antecipação com desconto |
| transfer_credit | Crédito em outra fatura do mesmo principal |
| undo_payment | Compensar pagamento/reabrir alocações |
| import_statement | Confirmar importação atômica |
| adjust_invoice | Ajustar total real |
| reverse_adjustment | Compensar ajuste |

### 17.6 Como rastrear uma função de ponta a ponta

Exemplo: confirmar despesa bancária. A ação da lista em `movement-list.tsx` chama o controlador em `app/page.tsx`, que abre `payment-dialog.tsx`. O diálogo monta parâmetros, gera/reutiliza chave e chama `manage_event_payment`. A definição SQL ativa valida estado/permissões/revisão, executa a operação com pagamentos e ledger e retorna. O componente recarrega dados e fecha o diálogo. Conferir a definição final na migration 016 e alterações posteriores aplicáveis.

Exemplo: importar fatura. `statement-tools.tsx` usa `statement-file.ts` para leitura, `pdf-layout.ts` para organizar texto e `statements.ts` para extração/comparação. A pessoa revisa cada decisão. A confirmação chama `cc_action` com `import_statement`; migrations 020 e 022 compõem o caminho atual, validando lote e estornos existentes. A transação registra compras/linhas e histórico ou reverte integralmente.

Exemplo: lembrar pendências. Cron chama a rota de notificações, que usa `dueSlots`, `notification_snapshot` e `notification_claim`. A rota consulta e-mails confirmados pelo Auth administrativo, envia com payload/chave persistidos e atualiza `notification_deliveries`.

Ao modificar regras, atualize testes, contratos SQL e exemplos desta documentação. Para reconstrução visual diferente, mantenha os invariantes financeiros mesmo que substitua toda a interface.
