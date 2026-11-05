import { createBrowserClient } from "@supabase/ssr";
export function supabase() {
 const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
 const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
 if (!url || !key) throw new Error("Configure as variáveis do Supabase.");
 return createBrowserClient(url,key);
}
