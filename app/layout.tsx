import "./globals.css";
import SiteFooter from '@/components/site-footer';
export const metadata={title:"Finanças Compartilhadas",description:"Seu dinheiro, seus planos, juntos. Controle financeiro compartilhado."};
export default function Layout({children}:{children:React.ReactNode}){return <html lang="pt-BR"><body>{children}<SiteFooter/></body></html>}
