# Duo para Android

Aplicativo Android que abre o Duo em `https://www.luciano.net.br/` e usa o próprio site como interface. Assim, usa o mesmo Supabase, autenticação, permissões, grupos, contas, cartões e histórico já publicados. Não há um segundo banco, cópia de dados financeiros nem chave administrativa no APK.

## Instalar

O arquivo gerado fica em `android/build/outputs/Duo-Android.apk`. Transfira para o celular, abra o arquivo e autorize a instalação para o aplicativo usado para abri-lo. Compatível com Android 8 ou superior. Entre com o mesmo e-mail/senha e o mesmo grupo familiar do site; o login é independente da sessão do navegador.

O acesso financeiro requer internet e a disponibilidade do site/Supabase. Atualizações e sincronização seguem as rotinas do site (carregamento, retorno ao primeiro plano e atualização periódica); o botão superior permite recarregar. Não há operação financeira offline nem promessa de sincronização instantânea por push.

## Integrações Android

- Sessão persistida pelo WebView, usando os cookies e armazenamento do site.
- Seletor de documentos Android para PDF, CSV e OFX, sem permissão ampla para ler o armazenamento.
- Compartilhamento de texto com o seletor nativo; a pessoa escolhe o destinatário e confirma no aplicativo escolhido.
- Copiar texto e salvar checklist TXT pelo seletor de destino do Android. Exportações nativas de texto limitadas a 256 KiB; não há download genérico de arquivos binários via blob.
- Voltar navega no histórico e fecha diálogos HTML antes de sair.
- Estado de falha de conexão com nova tentativa; falhas TLS são bloqueadas.
- Links externos abrem em outro aplicativo. Dentro do WebView só ficam HTTPS do domínio configurado e sua variante www.

A recuperação de senha por e-mail continua usando a página HTTPS existente. O link recebido pode abrir no navegador; depois de alterar a senha, entre novamente no aplicativo. Não foram configurados Android App Links, OAuth nativo ou notificações push.

## Compilar no Windows com o SDK instalado

```powershell
npm run android:test
npm run android:build
```

`android:build` gera o APK de release, com depuração desativada e assinatura própria. O script usa Java, AAPT2, D8, zipalign e apksigner do SDK local e não precisa baixar dependências Gradle. Os caminhos podem ser informados explicitamente:

```powershell
powershell -ExecutionPolicy Bypass -File android/build-apk.ps1 -Release -AndroidSdk 'C:\caminho\Android\Sdk' -ToolJavaHome 'C:\caminho\jdk'
```

Padrões: SDK em `%LOCALAPPDATA%\Android\Sdk`, Java no JBR do Android Studio, plataforma 36 e Build Tools 36.0.0. O Java local 25 foi usado para compilar classes compatíveis com Java 17; D8 produz o código Android a partir delas.

O arquivo `android/.local-signing/duo-release.p12` e sua senha em `duo-release-password.txt` são gerados localmente e ficam fora do Git. Guarde backup privado dos dois: são necessários para atualizar o APK mantendo a mesma instalação. Não envie a senha junto com o APK. As chaves de desenvolvimento e release são diferentes.

Para uma compilação depurável no emulador: `npm run android:debug`. Uma instalação de desenvolvimento deve ser removida antes de instalar a release com outra assinatura; essa remoção apaga apenas o armazenamento local daquele app, não os dados do Supabase.

## Android Studio / Gradle

Abra a pasta `android/`. Projeto Java com AGP 8.13.0, Gradle 8.14.3, compile/target SDK 36 e min SDK 26. Use JDK 17 ou 21 para executar esse Gradle. O wrapper pode baixar a distribuição/dependências oficiais na primeira execução. Depois:

```powershell
cd android
.\gradlew.bat assembleDebug
```

Para release pelo Gradle, gere antes a assinatura com `build-apk.ps1 -Release` e execute `assembleRelease`. O Gradle utiliza a mesma chave local. Não foi publicada nenhuma versão em loja ou no servidor.

## Segurança e validação

A única permissão de aplicativo é INTERNET. Não há acesso de arquivo por `file://`, tráfego HTTP, bypass de certificado, interface JavaScript global ou backup dos dados do WebView. O canal nativo usa WebMessagePort entregue apenas ao documento principal do domínio permitido; mensagens de outros frames são recusadas.

Teste local de política: `npm run android:test`. Verifica HTTPS, domínio, alias www, portas, credenciais na URL, esquemas locais e nomes dos arquivos exportados.

Teste de integração no emulador temporário `emulator-5580`: `node android/tests/webview-smoke.mjs`. Requer uma compilação debug instalada e ADB local. Abre a tela pública, testa compartilhamento sem enviar mensagem, exportação TXT com o mesmo link destacado usado pelo site, seletor de importação sem upload e botão voltar em diálogo. Não solicita senha nem grava dados financeiros.

Referências de implementação: [segurança de WebView](https://developer.android.com/privacy-and-security/risks/webview-unsafe-file-inclusion), [WebChromeClient e seletor de arquivos](https://developer.android.com/reference/android/webkit/WebChromeClient).

## Validação desta entrega — 15/11/2026

- `npm run android:test`: testes de origem HTTPS, protocolos, portas, nomes de arquivo, handshake entre frames e exportação por link destacado passaram.
- `npm test`: regressão das regras financeiras existentes passou; o código financeiro do site não foi alterado.
- APK de release gerado e verificado por AAPT, zipalign e apksigner. `br.net.luciano.duo`, versão 1.0.0, min SDK 26, target SDK 36, somente permissão INTERNET, sem flag de depuração, assinaturas v2/v3 válidas.
- Instalação e abertura no emulador Android API 37 em modo somente leitura. Tela real de login do site carregada; seletores nativos de compartilhar/salvar/importar e voltar em diálogo verificados com conteúdo sintético. O checklist de teste foi salvo pelo Android e o conteúdo conferido. Nenhuma mensagem foi enviada, arquivo enviado ao servidor, login realizado ou registro financeiro criado.
- Revisão estática identificou a exportação por âncora destacada, que foi corrigida e ganhou teste de regressão. Não houve alteração em Supabase, deploy, commit ou push.
- Limite da validação: sem teste autenticado de transações reais e sem homologação em aparelho físico. O APK usa a mesma aplicação HTTPS e as mesmas regras do site; a pessoa deve entrar com sua conta e grupo já existentes.

O APK é intencionalmente pequeno: o WebView do Android apresenta a aplicação publicada. Ele não contém cópia do frontend financeiro nem dados do banco; alterações futuras publicadas no site aparecem também no aplicativo. Mudanças na camada Android exigem recompilar e instalar uma atualização assinada com a mesma chave.
