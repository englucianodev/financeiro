import "./globals.css";
import localFont from 'next/font/local';
import SiteFooter from '@/components/site-footer';
// Fontes do Duo embutidas no projeto (licença SIL OFL, ver app/fonts): não dependem de rede no build.
const inter=localFont({src:'./fonts/inter.woff2',weight:'100 900',display:'swap',variable:'--font-body-face'});
const sora=localFont({src:'./fonts/sora.woff2',weight:'100 800',display:'swap',variable:'--font-head-face'});
export const metadata={title:"Duo",description:"Duo · finanças a dois: contas, cartões e planos do casal num só lugar."};
export default function Layout({children}:{children:React.ReactNode}){return <html lang="pt-BR" className={inter.variable+' '+sora.variable}><body>{children}<SiteFooter/></body></html>}
