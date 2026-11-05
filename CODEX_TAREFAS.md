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
