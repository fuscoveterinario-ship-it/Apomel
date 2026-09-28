// Envia as mensagens que estão na fila (tabela colmeia_notifications).
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { type Notification, send } from "./providers.ts";

export async function dispatchQueue(db: SupabaseClient, limit = 20): Promise<Record<string, number>> {
  const { data, error } = await db.rpc("colmeia_claim_notifications", { p_limit: limit });
  if (error) throw new Error(`fila: ${error.message}`);
  const counts: Record<string, number> = {};
  const env = (k: string) => Deno.env.get(k);
  await Promise.all((data as Notification[]).map(async (n) => {
    const r = await send(n, env);
    counts[r.status] = (counts[r.status] ?? 0) + 1;
    const { error: e } = await db.rpc("colmeia_finish_notification", {
      p_id: n.id,
      p_status: r.status,
      p_error: r.error ?? null,
    });
    if (e) console.error("colmeia_finish_notification", n.id, e.message);
  }));
  return counts;
}
