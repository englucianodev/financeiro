import Link from 'next/link';
import {Download,ShieldCheck,Smartphone} from 'lucide-react';
import DuoLogo from '@/components/duo-logo';
import {APK_PATH,APP_VERSION} from '@/lib/app-download';

export const metadata={title:'Duo para Android',description:'Baixe e instale o aplicativo Duo no seu Android.'};

export default function AndroidAppPage(){
  return <main className="card app-download">
    <div className="login-brand"><DuoLogo size={56}/></div>
    <h1>Duo para Android</h1>
    <p className="app-download-lead">O app abre o mesmo Duo do site: mesma conta, mesmo grupo e os mesmos dados. Nada muda no que vocês já cadastraram.</p>
    <a className="app-download-button" href={APK_PATH} download="Duo-Android.apk"><Download size={20} aria-hidden="true"/>Baixar o app (APK)</a>
    <p className="app-download-meta">Versão {APP_VERSION} · Android 8 ou superior · menos de 1 MB</p>

    <h2>Como instalar</h2>
    <ol className="app-download-steps">
      <li><strong>Baixe o arquivo</strong> tocando no botão acima. Se o navegador perguntar, confirme o download.</li>
      <li><strong>Abra o arquivo</strong> pela notificação de download concluído ou pela pasta <em>Downloads</em>.</li>
      <li><strong>Permita a instalação.</strong> O Android pode avisar que o app não vem da Play Store. Toque em <em>Configurações</em>, ative <em>Permitir desta fonte</em> e volte.</li>
      <li><strong>Toque em Instalar.</strong> Se o Play Protect mostrar &ldquo;App não reconhecido&rdquo;, toque em <em>Mais detalhes</em> e depois em <em>Instalar mesmo assim</em>.</li>
      <li><strong>Abra o Duo</strong> e entre com o mesmo e-mail e senha do site.</li>
    </ol>

    <div className="app-download-note"><ShieldCheck size={20} aria-hidden="true"/><p>O app só pede acesso à internet. Ele não lê seus arquivos, contatos nem fotos; para importar um extrato, você escolhe o arquivo.</p></div>
    <div className="app-download-note"><Smartphone size={20} aria-hidden="true"/><p>Está no computador? Abra <strong>www.luciano.net.br/android</strong> no navegador do celular.</p></div>

    <p><Link href="/">Voltar ao Duo</Link></p>
  </main>;
}
