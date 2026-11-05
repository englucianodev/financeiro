# Recuperação e alteração de senha

O frontend utiliza Supabase Auth com a chave pública existente. Não é necessário criar tabela de senhas, chave privada ou um serviço de e-mail no frontend.

## Configurar no projeto Supabase da Vercel

1. Em **Authentication → URL Configuration**, defina Site URL como `https://nossascoisinhas.vercel.app`.
2. Em Redirect URLs, inclua exatamente `https://nossascoisinhas.vercel.app/redefinir-senha`. Para desenvolvimento, inclua `http://localhost:3000/redefinir-senha`. Inclua também o domínio próprio, se for diferente do domínio Vercel.
3. Em **Authentication → Email Templates → Reset Password**, copie o conteúdo de `supabase/password_recovery_email.html`. O template aponta para a página de redefinição com `token_hash` e `type=recovery`.
4. Verifique o provedor de e-mail do Supabase e, para entrega em produção, configure SMTP conforme o provedor utilizado. Se o serviço padrão restringir destinatários ou atingir limites, o código da aplicação não consegue contornar essa configuração. Ajuste remetente, domínio e SMTP no Supabase.
5. Publique o frontend. Solicite recuperação com uma conta de testes real, abra o e-mail, cadastre a nova senha e confira o login com ela. Teste também link expirado e tentativa de reutilização.

## Fluxos implementados

- Login: botão Mostrar/Ocultar senha e “Esqueci minha senha”. A chamada `resetPasswordForEmail` envia ao Supabase o e-mail e `redirectTo` para `/redefinir-senha`.
- Template recomendado: a página valida o token no servidor Auth com `verifyOtp`. Isso permite abrir o e-mail em outro navegador/aparelho. O token é de uso único e a validade é controlada pelo Supabase.
- Template padrão: o fluxo PKCE é suportado no navegador que iniciou a recuperação e mantém o verificador local. O SDK troca o código pela sessão. Para abrir o link em outro aparelho, utilize o template recomendado com TokenHash.
- Após validação, `updateUser` grava a nova senha no Supabase. Confirmação de senha e mínimo de oito caracteres são validados no formulário; as demais regras do Auth continuam valendo. Links inválidos não exibem o formulário. Tokens e códigos são removidos da URL após o processamento.
- Mais → Personalização → Senha e acesso: alteração autenticada com senha atual; há opção de enviar código de reautenticação se o Supabase exigir essa confirmação. Também é possível solicitar o link por e-mail.
- Nenhuma senha é salva no banco financeiro ou no armazenamento de navegação.

A validação local utiliza a API Auth simulada e não envia e-mails reais. Configuração SMTP, template hospedado e entrega de e-mail ainda precisam ser homologados no projeto publicado.

Referências oficiais: [Senhas](https://supabase.com/docs/guides/auth/passwords), [resetPasswordForEmail](https://supabase.com/docs/reference/javascript/auth-resetpasswordforemail), [Templates](https://supabase.com/docs/guides/auth/auth-email-templates).
