"use client";
import {useId,useState,type ComponentProps} from 'react';
import {Eye,EyeOff} from 'lucide-react';
export default function PasswordInput({label,...props}:ComponentProps<'input'>&{label:string}){
 const id=useId(),[visible,setVisible]=useState(false);
 return <div className="password-field"><label htmlFor={id}>{label}</label><div className="password-control"><input {...props} id={id} type={visible?'text':'password'}/><button type="button" aria-label={(visible?'Ocultar ':'Mostrar ')+label.toLocaleLowerCase('pt-BR')} aria-pressed={visible} onMouseDown={e=>e.preventDefault()} onClick={()=>setVisible(v=>!v)}>{visible?<EyeOff size={19}/>:<Eye size={19}/>}</button></div></div>
}
