import { createClient, type SupabaseClient } from "@supabase/supabase-js";

/**
 * Supabase-klient som agerar som den inloggade användaren (RLS gäller), eller null om
 * anropet saknar giltig inloggning.
 */
export async function userClient(req: Request): Promise<SupabaseClient | null> {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return null;
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error } = await supabase.auth.getUser(authHeader.replace(/^Bearer /, ""));
  return error || !user ? null : supabase;
}
