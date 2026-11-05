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
