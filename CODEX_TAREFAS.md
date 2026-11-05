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
