/** Supabase/PostgREST errors are plain objects, not necessarily Error instances. */
export function errorMessage(error: unknown): string {
 if (typeof error === "string" && error.trim()) return error;
 if (error && typeof error === "object") {
  const value = error as {message?: unknown; code?: unknown};
  if (["PGRST202", "PGRST205", "42P01", "42883"].includes(String(value.code))) {
   return "O banco de dados está desatualizado ou a API ainda não reconhece as tabelas e funções. Aplique as migrations pendentes no Supabase e atualize o cache da API.";
  }
  if (typeof value.message === "string" && value.message.trim()) return value.message;
 }
 return "Não foi possível concluir a operação. Tente novamente.";
}
