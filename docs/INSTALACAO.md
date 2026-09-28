# Guia de instalação — Colmeia Segura

Ordem sugerida: **1 a 6** (plataforma) já podem ser feitos antes de a placa chegar.
Com a plataforma no ar, dá para testar tudo com o **simulador** ou com um **celular** (passo 7).

---

## 1. Criar o projeto no Supabase

1. Crie uma conta em <https://supabase.com> e um projeto novo (o plano gratuito serve para o piloto).
2. Em **SQL Editor**, rode os arquivos de `supabase/migrations/` **nesta ordem**:
   `..._schema.sql`, `..._logic.sql`, `..._cron.sql`.
   (Quem usa o Supabase CLI pode fazer `supabase link` e `supabase db push`.)
3. Ainda no SQL Editor, informe o endereço do site (passo 5):
   ```sql
   update public.settings set value = 'https://SEU-SITE' where key = 'site_url';
   ```
   Os links das mensagens de alerta usam esse endereço.

## 2. Login do apicultor (código por e-mail)

Em **Authentication → Providers → Email**: deixe o e-mail ativado.
Em **Authentication → Email Templates → Magic Link**, inclua o código no texto, por exemplo:
`Seu código de acesso: {{ .Token }}` (o link também funciona).
Em **Authentication → URL Configuration**, coloque o endereço do site em *Site URL* e em *Redirect URLs*.

## 3. Publicar as funções

Com o [Supabase CLI](https://supabase.com/docs/guides/cli) instalado, na pasta do projeto:

```bash
supabase functions deploy ingest --no-verify-jwt   # a placa se autentica pela assinatura
supabase functions deploy dispatch
```

## 4. WhatsApp e SMS

Sem configurar nada, as mensagens ficam como **"simulado"** na tabela `notifications`:
dá para testar o fluxo inteiro sem gastar nada.

**SMS** (escolha um):
```bash
supabase secrets set SMS_PROVIDER=zenvia ZENVIA_TOKEN=... ZENVIA_FROM=...
# ou
supabase secrets set SMS_PROVIDER=twilio TWILIO_SID=... TWILIO_TOKEN=... TWILIO_FROM=+1...
```

**WhatsApp** (API oficial da Meta — exige CNPJ e verificação da empresa):
```bash
supabase secrets set WHATSAPP_TOKEN=... WHATSAPP_PHONE_ID=...
```
Cadastre estes modelos na Meta (categoria *Utilidade*, idioma *Português (BR)*), com os
parâmetros **na ordem indicada**:

| Modelo | Parâmetros | Texto sugerido |
|---|---|---|
| `alerta_movimento` | caixa, apiário, link | ALERTA COLMEIA SEGURA: a {{1}} foi movimentada no {{2}}. Foi você fazendo manutenção? Responda em até 5 minutos: {{3}} |
| `alerta_escalado` | caixa, apiário, link | ALERTA COLMEIA SEGURA: a {{1}} ({{2}}) foi movimentada e ninguém confirmou em 5 minutos. POSSÍVEL ROUBO. Mapa: {{3}} |
| `roubo_confirmado` | caixa, apiário, link | ALERTA COLMEIA SEGURA: ROUBO CONFIRMADO da {{1}} ({{2}}). Mapa: {{3}} |
| `offline` | caixa, apiário, hora, link | AVISO: o rastreador da {{1}} ({{2}}) está sem comunicação desde {{3}}. Verifique: {{4}} |
| `bateria_baixa` | caixa, apiário, link | AVISO: bateria baixa no rastreador da {{1}} ({{2}}). Recarregue: {{3}} |

**Envio a cada minuto** (para o escalonamento de 5 min sair na hora certa). No SQL Editor:
```sql
create extension if not exists pg_net;
select cron.schedule('colmeia-envio', '* * * * *', $$
  select net.http_post(
    url     := 'https://SEU-PROJETO.supabase.co/functions/v1/dispatch',
    headers := jsonb_build_object('Authorization', 'Bearer SUA-CHAVE-ANON',
                                  'Content-Type', 'application/json'),
    body    := '{}'::jsonb)
$$);
```

## 5. Publicar o site

1. Edite `web/config.js` com o endereço do projeto e a chave **anon**
   (Supabase → *Project Settings → API*).
2. Publique a pasta `web/` em qualquer hospedagem de site estático **com HTTPS**
   (GitHub Pages, Netlify, Cloudflare Pages…).

## 6. Cadastrar um rastreador

```bash
node tools/novo-rastreador.mjs CS-0001 https://SEU-SITE
```
O comando mostra:
1. um `select public.provision_device(...)` → rode no SQL Editor;
2. `DEVICE_ID` e `DEVICE_SECRET` → vão no `firmware/include/config.h`;
3. o **link do QR Code técnico** → gere o QR Code (qualquer gerador) e cole no rastreador.

## 7. Testar sem a placa

**Simulador (computador):**
```bash
API_URL=https://SEU-PROJETO.supabase.co/functions/v1/ingest \
DEVICE_ID=CS-SIMULADO DEVICE_SECRET=... node tools/simulador.mjs movimento -25.43 -49.27
```

**Celular como rastreador de teste:** abra `https://SEU-SITE/celular-teste.html` num celular
(Android ou iPhone), informe o código e o segredo, deixe a tela ligada e mexa no celular.
Ele usa o sensor de movimento e o GPS do próprio celular e segue as mesmas regras da placa.

> Use **um código só para testes** (ex.: `CS-SIMULADO`, `CS-CELULAR`). A placa, o simulador
> e o celular contam as mensagens de formas diferentes; misturar no mesmo código faz a
> plataforma ignorar mensagens como se fossem repetidas.

## 8. Gravar o firmware na placa

1. Instale o **VS Code** e a extensão **PlatformIO**.
2. Abra a pasta `firmware/`.
3. Copie `include/config.example.h` para `include/config.h` e preencha (passo 6 e APN do chip).
4. Ligue a placa no USB e clique em **Upload** (seta →) na barra do PlatformIO.
5. Abra o **Serial Monitor** (tomada) para ver as mensagens da placa.

Primeiro teste de bancada (tudo em cima da mesa, com o chip e as antenas):
- o monitor deve mostrar `rede OK`, `envio de 1 evento(s): HTTP 200` e depois `GPS ...`
  (o GPS precisa de céu aberto: deixe perto de uma janela);
- faça a ativação pelo QR Code e confira o **teste de comunicação** na tela;
- incline a placa: deve aparecer `movimento` e chegar a mensagem de alerta.

Ligação do acelerômetro: `docs/ligacao-lilygo.png`.
