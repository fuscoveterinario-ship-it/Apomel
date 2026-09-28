// Envia WhatsApp/SMS da fila. Agendada a cada minuto (ver docs/INSTALACAO.md)
// e chamada também logo após um evento ou resposta, para o alerta sair na hora.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { dispatchQueue } from "../_shared/dispatcher.ts";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

Deno.serve(async () => {
  try {
    const counts = await dispatchQueue(db, 50);
    return Response.json({ ok: true, ...counts });
  } catch (e) {
    console.error(e);
    return Response.json({ ok: false, error: String(e) }, { status: 500 });
  }
});
