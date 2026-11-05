import { createBrowserClient } from "@supabase/ssr";
export function supabase() {
 const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
 const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
 if (!url || !key) throw new Error("Configure as variáveis do Supabase.");
 // Keep the existing Supabase storage key and refresh-token lifecycle.
 return createBrowserClient(url,key,{cookieOptions:{path:'/',sameSite:'lax',maxAge:60*60*24*400}});
}
