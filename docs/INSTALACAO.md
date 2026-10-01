# Guia de instalação — Bee Guard

## Instalação atual (já feita)

O Bee Guard está instalado **dentro do projeto Supabase "Rastreia Moura"**
(`vmzmthtsxiwwjtpupclv`, região São Paulo), **separado** dos outros sistemas:

- tudo o que é do Bee Guard tem o prefixo interno `colmeia_` (nome técnico, não aparece para o apicultor) (tabelas, funções, agendamentos);
- funções do servidor: `colmeia-ingest` (recebe os rastreadores) e `colmeia-dispatch` (envia WhatsApp/SMS);
- agendamentos (pg_cron): `colmeia-escalonamento` e `colmeia-envio`, a cada minuto;
- nenhuma tabela, função ou permissão dos outros sistemas (mel_, lat_, aprotunas_…) foi alterada.

O login usa os mesmos usuários do projeto. **Não altere o "Site URL" nem os modelos de e-mail**
do Authentication (os outros sistemas usam): apenas **adicione** o endereço do site do Colmeia em
*Authentication → URL Configuration → Redirect URLs*. O login funciona clicando no link do e-mail.

Endereço do site: **https://beeguard.com.br** (domínio registrado na HostGator; `site_url` já
atualizado). Falta: publicar o site no Netlify e apontar o domínio (passo 5) e contratar WhatsApp/SMS (passo 4). Até lá as mensagens ficam como "simulado".

---

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
   update public.colmeia_settings set value = 'https://SEU-SITE' where key = 'site_url';
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
supabase functions deploy colmeia-ingest --no-verify-jwt   # a placa se autentica pela assinatura
supabase functions deploy colmeia-dispatch
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
| `alerta_movimento` | caixa, apiário, link | ALERTA BEE GUARD: a {{1}} foi movimentada no {{2}}. Foi você fazendo manutenção? Responda em até 5 minutos: {{3}} |
| `alerta_escalado` | caixa, apiário, link | ALERTA BEE GUARD: a {{1}} ({{2}}) foi movimentada e ninguém confirmou em 5 minutos. POSSÍVEL ROUBO. Mapa: {{3}} |
| `roubo_confirmado` | caixa, apiário, link | ALERTA BEE GUARD: ROUBO CONFIRMADO da {{1}} ({{2}}). Mapa: {{3}} |
| `offline` | caixa, apiário, hora, link | AVISO: o rastreador da {{1}} ({{2}}) está sem comunicação desde {{3}}. Verifique: {{4}} |
| `bateria_baixa` | caixa, apiário, link | AVISO: bateria baixa no rastreador da {{1}} ({{2}}). Recarregue: {{3}} |
| `colheita` | caixa, apiário, kg, link | BEE GUARD: a {{1}} ({{2}}) ganhou {{3}} kg desde que a melgueira foi colocada. Pode estar na hora da colheita. Veja: {{4}} |
| `peso_baixo` | caixa, apiário, kg, link | AVISO: a {{1}} ({{2}}) está com {{3}} kg, abaixo do limite. Pode faltar alimento. Veja: {{4}} |
| `enxame` | caixa, apiário, kg, hora, link | AVISO: a {{1}} ({{2}}) perdeu {{3}} kg de repente perto das {{4}}. Pode ter enxameado. Veja: {{5}} |

**Envio a cada minuto** (para o escalonamento de 5 min sair na hora certa). No SQL Editor:
```sql
create extension if not exists pg_net;
select cron.schedule('colmeia-envio', '* * * * *', $$
  select net.http_post(
    url     := 'https://SEU-PROJETO.supabase.co/functions/v1/colmeia-dispatch',
    headers := jsonb_build_object('Authorization', 'Bearer SUA-CHAVE-ANON',
                                  'Content-Type', 'application/json'),
    body    := '{}'::jsonb)
$$);
```

## 5. Publicar o site

O repositório `bee-guard` é privado, então o site é publicado pelo **Netlify** (grátis),
que lê o repositório privado:

1. Crie uma conta em <https://app.netlify.com> entrando com o GitHub.
2. *Add new site → Import an existing project → GitHub* → escolha `bee-guard`.
3. Não precisa mudar nada: o arquivo `netlify.toml` já diz para publicar a pasta `web/`.
4. Anote o endereço gerado (ex.: `https://bee-guard.netlify.app`) e use nos passos 1.3 e 2.

Sem o repositório ainda: em *Add new site → Deploy manually*, arraste a pasta `web/`.

**Domínio beeguard.com.br (HostGator):**
1. No Netlify: *Domain management → Add a domain* → `beeguard.com.br` → *Set up Netlify DNS*.
   O Netlify mostra 4 servidores DNS (ex.: `dns1.p0X.nsone.net`).
2. Na HostGator: *Domínios → beeguard.com.br → Configurar domínio → Servidores DNS* → troque
   pelos 4 do Netlify. Leva de algumas horas até 1 dia para valer; o HTTPS é automático.
3. No Supabase (*Authentication → URL Configuration*): **adicione** em *Redirect URLs*
   `https://beeguard.com.br/**`. Não mude o *Site URL* (é dos outros sistemas).

(Alternativa equivalente: Cloudflare Pages, com *Build output directory* = `web`.)
O `web/config.js` já aponta para o projeto Supabase.

## 6. Cadastrar um rastreador

```bash
node tools/novo-rastreador.mjs CS-0001 https://SEU-SITE
```
O comando mostra:
1. um `select public.colmeia_provision_device(...)` → rode no SQL Editor;
2. `DEVICE_ID` e `DEVICE_SECRET` → vão no `firmware/include/config.h`;
3. o **link do QR Code técnico** → gere o QR Code (qualquer gerador) e cole no rastreador.

## 7. Testar sem a placa

**Simulador (computador):**
```bash
API_URL=https://SEU-PROJETO.supabase.co/functions/v1/colmeia-ingest \
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
4. Escolha a placa na barra do PlatformIO: **t-sim7080g-s3** (protótipo, Cat-M/NB-IoT) ou
   **t-a7670** (produção, 4G + 2G). Ligue a placa no USB e clique em **Upload** (seta →).
5. Abra o **Serial Monitor** (tomada) para ver as mensagens da placa.

Primeiro teste de bancada (tudo em cima da mesa, com o chip e as antenas):
- o monitor deve mostrar `rede OK`, `envio de 1 evento(s): HTTP 200` e depois `GPS ...`
  (o GPS precisa de céu aberto: deixe perto de uma janela);
- faça a ativação pelo QR Code e confira o **teste de comunicação** na tela;
- incline a placa: deve aparecer `movimento` e chegar a mensagem de alerta.

Ligação do acelerômetro: `docs/ligacao-lilygo.png` (T-A7670SA) e `docs/ligacao-sim7080.png` (T-SIM7080G-S3).
Balança: passo 9 e `docs/ligacao-balanca.png`.
O monitor mostra `rede encontrada: ...` com o tipo de rede (ex.: LTE CAT-M1 ou LTE NB-IOT): use isso no teste de cada apiário.

## 9. Balança (colmeia sentinela)

Uma colmeia com balança por apiário já mostra como o apiário inteiro está. A placa pesa a
cada 3 horas sem ligar o modem (gasta quase nada) e manda as pesagens junto com a mensagem do dia.

**Material:** kit com 4 células de carga de 50 kg + módulo HX711; duas placas firmes do
tamanho do fundo da colmeia (ex.: compensado naval 18 mm); um conector à prova d'água de
4 pinos (ex.: **GX12 de 4 pinos**) e uma caixinha para o HX711.

**Montagem das células** (`docs/ligacao-balanca.png`):
- uma célula em cada canto, entre a placa de baixo e a de cima;
- a **borda** de cada célula apoia na placa de baixo, com arruelas, deixando ~2 mm de folga
  embaixo do meio; o **meio** (onde tem o calombo) recebe a placa de cima;
- ligue os fios em anel: **branco com branco** e **preto com preto** entre cantos vizinhos;
- os fios **vermelhos**: canto 1 → **E+**, canto 3 (diagonal) → **E−**, canto 2 → **A+**,
  canto 4 → **A−** do HX711 (se o peso sair negativo, não tem problema: a calibração corrige).

**HX711 → placa** (4 fios, passando pelo conector GX12, para poder tirar a colmeia):

| HX711 | T-SIM7080G-S3 (protótipo) | T-A7670SA |
|---|---|---|
| VCC | 3V3 | 3V3 |
| GND | GND | GND |
| DT (DOUT) | GPIO 16 | GPIO 18 |
| SCK | GPIO 17 | GPIO 19 |

(Os pinos da T-SIM7080G-S3 serão confirmados com a foto da placa, como o INT do acelerômetro.)

No `firmware/include/config.h` desta caixa: `#define SCALE_ENABLED 1`.

**Calibração** (no painel, botão *Ajustes da balança*):
1. Balança vazia → aperte **RST** na placa → espere 2 min → **Balança vazia: zerar**.
2. Ponha um peso conhecido (galão de 5 L de água = 5 kg) → **RST** → espere 2 min → informe o
   peso → **Calibrar**.
3. Tire o peso e coloque a colmeia.

**Avisos:**
- *Colheita*: ao colocar a melgueira, toque em **Coloquei a melgueira agora**; o peso de
  referência é a pesagem seguinte. Quando a colmeia ganhar o peso combinado (padrão 15 kg,
  ajustável), chega o aviso.
- *Falta de alimento*: informe um peso mínimo (opcional); abaixo dele, aviso 1 vez por semana.
- *Possível enxameação*: queda de 1,5 a 5 kg entre duas pesagens durante o dia, sem
  manutenção nem alerta de movimento no período.
- *Roubo*: no alerta de movimento aparece o peso antes e na hora; perto de zero = caixa tirada
  da balança.

Proteja o HX711 e as células da chuva. Calor e frio mudam um pouco a leitura (algumas centenas
de gramas): por isso os avisos usam duas pesagens seguidas.

## 10. E-mail de acesso do Bee Guard (código de 6 números)

O login usa a função `colmeia-login`, que manda um e-mail **do Bee Guard**, em português, com
um código de 6 números (pelo serviço **Resend**). Os modelos de e-mail do Supabase, usados
pelos outros sistemas do projeto, não são alterados. Enquanto o Resend não estiver
configurado, o site usa o e-mail padrão do Supabase (link "Sign in").

1. Crie a conta em <https://resend.com> e adicione o domínio `beeguard.com.br`.
2. Copie os registros DNS que o Resend mostrar para o **Netlify** (o DNS do domínio está lá):
   *Domain management → beeguard.com.br → DNS settings → Add new record*. Clique em *Verify* no Resend.
3. No Resend, crie uma *API key* (permissão *Sending access*).
4. No Supabase: *Edge Functions → Secrets* → `RESEND_API_KEY` = a chave.
   Opcional: `LOGIN_EMAIL_FROM` (padrão `Bee Guard <acesso@beeguard.com.br>`).

Limites: 3 códigos por e-mail a cada 15 minutos e 200 por hora no total.
