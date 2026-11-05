# Continuidade — 05/11/2026

## Ponto recuperado

A execução anterior parou nos testes de navegador e documentação. O código já contém migrations 001–007 e as telas de planejamento. A migration inicial foi preservada.

Nesta retomada: corrigida sessão simulada em cookie nos testes E2E; liberada nova chave de cadastro de conta após sucesso; ajustados limites de largura mobile; adicionadas verificações de pagamento de fatura parcial, repetição, rejeição de excesso e estorno; atualizadas instruções de implantação e limitações no README.

## Validação desta retomada

- TypeScript, testes de projeção e testes de banco: passaram.
- Build de produção: passou.
- Playwright: 3 testes passaram no Edge (conta por responsável e pagamento, nova chave de cadastro após sucesso, navegação e largura mobile).
- Configurada a origem de desenvolvimento `127.0.0.1` exigida pelo Next.js para carregar os recursos locais nos testes.
- Nenhuma migration foi executada em banco remoto.

## Próximas entregas

1. Homologar as migrations em Supabase de desenvolvimento e os fluxos de dois usuários com autenticação real. Medir concorrência com conexões independentes (PGlite local não cobre esse cenário).
2. Recorrências: edição futura em lote, propagação do último valor variável e renovação do lote finito.
3. Transferências agendadas persistentes e reserva mínima configurável.
4. Extrato com data e conta efetiva do pagamento, consulta do ledger e auditoria de todos os cadastros.
5. Paginação, conciliação e exportação de relatórios.
6. Publicar na Vercel após configurar Supabase e validar o ambiente de desenvolvimento.

As instruções originais abaixo continuam sendo referência; várias etapas já foram implementadas. Consulte o README para evitar repetir migrations ou alegar validação remota ainda não realizada.

---

# Plano de continuidade para Codex

Você recebeu um MVP parcial Next.js/Supabase. Antes de alterar código, rode `npm install`, `npm run typecheck` e `npm run build`. Corrija problemas de compilação e teste com Supabase de desenvolvimento. Não execute migrations destrutivas.

Prioridades:
1. Segurança: substituir `join_household` baseado em UUID por convite com token aleatório, expiração e emissão restrita a membros; garantir limite de dois membros com lock transacional. Testar RLS e RPCs, abuso de permissões, e verificação de usuário pertencente ao núcleo.
2. Modelo contábil: substituir mutação direta de saldo por ledger auditável com operações atômicas e reversíveis; idempotency keys; histórico de ajustes; prevenção de corrida.
3. Formulários: permitir selecionar conta efetiva no pagamento; registrar valor e data efetivos; corrigir sugestão da conta principal para funcionar sem sobrescrever escolha manual; criar/alterar conta principal com atualização transacional e preservar histórico.
4. Recorrências: regras e ocorrências, despesas variáveis com último valor conhecido, meses curtos, cancelamento individual e edição futura.
5. Cartões: compras parceladas, ciclo fechamento/vencimento, faturas, pagamentos parciais, sem dupla contagem.
6. Projeção: tratar atrasados, movimentações do dia, transferências previstas, janelas 30/60/90/180/365 dias; saldo mínimo e necessidade de transferência por conta.
7. Imóveis, investimentos com liquidez, calendário, relatórios, simulador, reserva mínima.
8. UX mobile, acessibilidade, testes de integração e E2E, documentação de deploy.

Regras centrais: quem cadastra != responsável != conta de origem; transferência interna não é despesa; receita/despesa prevista não altera saldo real; não somar investimentos duas vezes; projeção por conta, por pessoa e casal.

Evite alegar funcionalidades ainda não existentes. Registre em README os avanços e limitações.
