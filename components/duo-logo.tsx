// Símbolo do Duo: dois círculos que se cruzam no que é dos dois.
export default function DuoLogo({size=32,tile=true}:{size?:number;tile?:boolean}){
 return <svg className="duo-logo" width={size} height={size} viewBox="0 0 52 52" aria-hidden="true" focusable="false">
  {tile&&<rect width="52" height="52" rx="16" fill="var(--brand-deep)"/>}
  <circle cx="21" cy="26" r="11" fill="none" stroke={tile?'#f4f3ff':'var(--accent)'} strokeWidth="4"/>
  <circle cx="31" cy="26" r="11" fill="none" stroke="var(--coral)" strokeWidth="4"/>
 </svg>;
}
