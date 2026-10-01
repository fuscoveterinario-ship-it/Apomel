// E-mail do código de acesso do Bee Guard (enviado pelo Resend).

export const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export function normalizeEmail(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const email = raw.trim().toLowerCase();
  return email.length <= 254 && EMAIL_RE.test(email) ? email : null;
}

export function loginEmail(code: string, siteUrl: string) {
  const safe = code.replace(/\D/g, "");
  const subject = `${safe} é o seu código de acesso Bee Guard`;
  const text = `Seu código de acesso ao Bee Guard é: ${safe}\n\n` +
    `Digite esse número na tela de entrada do site. Ele vale por pouco tempo e pode ser usado uma vez.\n` +
    `Se não foi você que pediu, ignore este e-mail.\n\n${siteUrl}`;
  const html = `<!doctype html><html lang="pt-BR"><body style="margin:0;background:#f4f4f4;font-family:Arial,Helvetica,sans-serif;color:#1d1d1d">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f4;padding:24px 12px"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:480px;background:#ffffff;border-radius:12px;overflow:hidden">
<tr><td style="background:#111111;padding:16px 20px;border-bottom:4px solid #f5c400">
<img src="${siteUrl}/icone.png" width="40" height="40" alt="" style="vertical-align:middle;border-radius:8px;background:#fff">
<span style="color:#ffffff;font-size:20px;font-weight:bold;letter-spacing:1px;vertical-align:middle;margin-left:10px">BEEGUARD</span>
</td></tr>
<tr><td style="padding:24px 20px">
<p style="font-size:17px;margin:0 0 12px">Seu código de acesso é:</p>
<p style="font-size:36px;font-weight:bold;letter-spacing:8px;margin:0 0 16px;color:#111111">${safe}</p>
<p style="font-size:15px;line-height:1.5;margin:0 0 12px">Digite esse número na tela de entrada do Bee Guard. Ele vale por pouco tempo e pode ser usado uma vez.</p>
<p style="font-size:13px;line-height:1.5;color:#666666;margin:0">Se não foi você que pediu, ignore este e-mail.</p>
</td></tr></table></td></tr></table></body></html>`;
  return { subject, text, html };
}
