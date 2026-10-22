import { createClient, type SupabaseClient } from "@supabase/supabase-js";

export interface UserContext {
  supabase: SupabaseClient;
  userId: string;
}

/**
 * Supabase-klient som agerar som den inloggade användaren (RLS gäller), eller null om
 * anropet saknar giltig inloggning.
 */
export async function userClient(req: Request): Promise<UserContext | null> {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return null;
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error } = await supabase.auth.getUser(authHeader.replace(/^Bearer /, ""));
  return error || !user ? null : { supabase, userId: user.id };
}

/**
 * Klient med service role (förbi RLS) för schemalagda jobb. Alla frågor måste därför
 * filtrera på user_id själva – det gör funktionerna i context.ts och planner.ts.
 */
export function serviceClient(): SupabaseClient {
  return createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}
