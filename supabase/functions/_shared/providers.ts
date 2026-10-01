// Envio de WhatsApp e SMS.
// Sem credenciais configuradas, as mensagens ficam como "simulado" (aparecem no
// painel, mas não saem), o que permite testar tudo antes de contratar os serviços.

export interface Notification {
  id: number;
  to_phone: string;
  channel: "whatsapp" | "sms";
  template: string;
  body: string;
  params: Record<string, string>;
}

export type SendResult = { status: "enviado" | "simulado" | "falhou"; error?: string };

type Env = (name: string) => string | undefined;

// Ordem dos parâmetros de cada modelo aprovado no WhatsApp ({{1}}, {{2}}, ...).
export const WHATSAPP_TEMPLATE_PARAMS: Record<string, string[]> = {
  alerta_movimento: ["caixa", "apiario", "link"],
  alerta_escalado: ["caixa", "apiario", "link"],
  roubo_confirmado: ["caixa", "apiario", "link"],
  offline: ["caixa", "apiario", "hora", "link"],
  bateria_baixa: ["caixa", "apiario", "link"],
  colheita: ["caixa", "apiario", "kg", "link"],
  peso_baixo: ["caixa", "apiario", "kg", "link"],
  enxame: ["caixa", "apiario", "kg", "hora", "link"],
  ataque_apiario: ["apiario", "caixas", "link"],
};

const digits = (phone: string) => phone.replace(/\D/g, "");

export function whatsappRequest(n: Notification, env: Env): Request | null {
  const token = env("WHATSAPP_TOKEN");
  const phoneId = env("WHATSAPP_PHONE_ID");
  if (!token || !phoneId) return null;
  const names = WHATSAPP_TEMPLATE_PARAMS[n.template] ?? ["caixa", "apiario", "link"];
  const body = {
    messaging_product: "whatsapp",
    to: digits(n.to_phone),
    type: "template",
    template: {
      name: n.template,
      language: { code: env("WHATSAPP_LANG") ?? "pt_BR" },
      components: [{
        type: "body",
        parameters: names.map((k) => ({ type: "text", text: String(n.params[k] ?? "") })),
      }],
    },
  };
  return new Request(`https://graph.facebook.com/v21.0/${phoneId}/messages`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

export function smsRequest(n: Notification, env: Env): Request | null {
  const provider = (env("SMS_PROVIDER") ?? "simulado").toLowerCase();
  // SMS tem limite de tamanho; a mensagem é curta, mas garantimos 300 caracteres.
  const text = n.body.length > 300 ? n.body.slice(0, 297) + "..." : n.body;

  if (provider === "zenvia") {
    const token = env("ZENVIA_TOKEN");
    if (!token) return null;
    return new Request("https://api.zenvia.com/v2/channels/sms/messages", {
      method: "POST",
      headers: { "X-API-TOKEN": token, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: env("ZENVIA_FROM") ?? "beeguard",
        to: digits(n.to_phone),
        contents: [{ type: "text", text }],
      }),
    });
  }

  if (provider === "twilio") {
    const sid = env("TWILIO_SID");
    const auth = env("TWILIO_TOKEN");
    const from = env("TWILIO_FROM");
    if (!sid || !auth || !from) return null;
    return new Request(`https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`, {
      method: "POST",
      headers: {
        Authorization: "Basic " + btoa(`${sid}:${auth}`),
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: new URLSearchParams({ To: n.to_phone, From: from, Body: text }).toString(),
    });
  }

  return null;
}

export async function send(n: Notification, env: Env, doFetch: typeof fetch = fetch): Promise<SendResult> {
  const req = n.channel === "whatsapp" ? whatsappRequest(n, env) : smsRequest(n, env);
  if (!req) return { status: "simulado" };
  try {
    const res = await doFetch(req);
    if (res.ok) return { status: "enviado" };
    return { status: "falhou", error: `HTTP ${res.status}: ${(await res.text()).slice(0, 300)}` };
  } catch (e) {
    return { status: "falhou", error: String(e).slice(0, 300) };
  }
}
