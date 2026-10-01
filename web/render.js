// Desenho das partes do painel, usado pelo painel do apicultor (painel.html) e pela
// página de visualização compartilhada (ver.html, sem login, localização só aproximada).
import { ago, esc, fmtDate } from "./app.js";

export const kg = (v) => v === null || v === undefined ? "—" : `${Number(v).toLocaleString("pt-BR", { maximumFractionDigits: 1 })} kg`;

// Gráfico simples do peso dos últimos 14 dias.
export function grafico(pts) {
  if (pts.length < 2) return '<p class="msg">O gráfico aparece depois de algumas pesagens.</p>';
  const t0 = new Date(pts[0].measured_at).getTime(), t1 = new Date(pts[pts.length - 1].measured_at).getTime();
  const vs = pts.map((p) => Number(p.kg)), lo = Math.min(...vs), hi = Math.max(...vs), span = Math.max(hi - lo, 1);
  const xy = pts.map((p, i) => `${(((new Date(p.measured_at).getTime() - t0) / Math.max(t1 - t0, 1)) * 300).toFixed(1)},${(56 - ((vs[i] - lo) / span) * 52).toFixed(1)}`);
  return `<svg class="peso-graf" viewBox="0 0 300 60" preserveAspectRatio="none" role="img" aria-label="Peso dos últimos 14 dias">
      <polyline points="${xy.join(" ")}" /></svg>
    <div class="peso-eixo"><span>${fmtDate(pts[0].measured_at)}</span><span>mín. ${kg(lo)} · máx. ${kg(hi)}</span></div>`;
}

// ---------------------------------------------------------------------------
// Produção de mel por apiário
// ---------------------------------------------------------------------------
export const MESES = ["jan", "fev", "mar", "abr", "mai", "jun", "jul", "ago", "set", "out", "nov", "dez"];
export const fmtKg = (v) => `${Number(v).toLocaleString("pt-BR", { maximumFractionDigits: 1 })} kg`;

// Barras com o mel colhido em cada um dos últimos 12 meses.
export function graficoMeses(hs) {
  const hoje = new Date();
  const meses = [];
  for (let i = 11; i >= 0; i--) {
    const d = new Date(hoje.getFullYear(), hoje.getMonth() - i, 1);
    meses.push({ y: d.getFullYear(), m: d.getMonth(), kg: 0 });
  }
  for (const h of hs) {
    const [y, m] = h.harvested_on.split("-").map(Number);
    const b = meses.find((x) => x.y === y && x.m === m - 1);
    if (b) b.kg += Number(h.kg);
  }
  const max = Math.max(...meses.map((x) => x.kg), 1);
  const bw = 300 / 12;
  return `<svg class="prod-graf" viewBox="0 0 300 96" role="img" aria-label="Mel colhido por mês nos últimos 12 meses">
    ${meses.map((x, i) => {
      const h = (x.kg / max) * 60;
      const cx = i * bw + bw / 2;
      return `<rect x="${(i * bw + 4).toFixed(1)}" y="${(76 - h).toFixed(1)}" width="${(bw - 8).toFixed(1)}" height="${Math.max(h, 0.5).toFixed(1)}" rx="2"><title>${MESES[x.m]}/${x.y}: ${fmtKg(x.kg)}</title></rect>
        ${x.kg ? `<text class="val" x="${cx.toFixed(1)}" y="${(72 - h).toFixed(1)}">${Math.round(x.kg)}</text>` : ""}
        <text x="${cx.toFixed(1)}" y="90">${MESES[x.m]}</text>`;
    }).join("")}</svg><p class="msg legenda">kg de mel colhidos por mês</p>`;
}

export function producao(apiarios, devs, hs, { abertos = new Set(), readonly = false, hives = [] } = {}) {
  const ano = new Date().getFullYear();
  const nomeCaixa = Object.fromEntries(devs.map((d) => [d.id, d.hive_label || d.id]));
  const nomeColmeia = Object.fromEntries(hives.map((h) => [h.id, h.label]));
  const SEM = "Apiário (sem colmeia definida)";
  const onde = (h) => (h.hive_id && nomeColmeia[h.hive_id]) || (h.device_id && nomeCaixa[h.device_id]) || SEM;
  const hoje = new Date().toLocaleDateString("sv-SE");  // AAAA-MM-DD no fuso do aparelho
  return apiarios.map((a) => {
    const lista = hs.filter((h) => h.apiary_id === a.id);
    const doAno = lista.filter((h) => h.harvested_on.startsWith(String(ano)));
    const total = doAno.reduce((t, h) => t + Number(h.kg), 0);
    const porCaixa = {};
    for (const h of doAno) porCaixa[onde(h)] = (porCaixa[onde(h)] || 0) + Number(h.kg);
    const colmeias = hives.filter((h) => h.apiary_id === a.id);
    const aid = esc(a.id);
    return `<article class="card producao">
      <h2>Produção de mel <small>${esc(a.name)}</small></h2>
      <div class="grid">
        <div><span>Colhido em ${ano}</span><b>${fmtKg(total)}</b></div>
        <div><span>Colheitas em ${ano}</span><b>${doAno.length}</b></div>
      </div>
      ${lista.length ? graficoMeses(lista) : '<p class="msg">Nenhuma colheita registrada ainda.</p>'}
      ${Object.keys(porCaixa).length ? `<h3>Por colmeia em ${ano}</h3><ul class="prod-caixas">${Object.entries(porCaixa)
        .sort((x, y) => y[1] - x[1]).map(([k, v]) => `<li><span>${esc(k)}</span><b>${fmtKg(v)}</b></li>`).join("")}</ul>` : ""}
      ${lista.length ? `<h3>Últimas colheitas</h3><ul class="prod-lista">${lista.slice(0, 8).map((h) => `<li>
          <div><b>${fmtKg(h.kg)}</b> · ${esc(new Date(h.harvested_on + "T12:00:00").toLocaleDateString("pt-BR"))}<br>
            <small>${esc(onde(h))}${
              h.source === "balanca" ? " · estimado pela balança" : ""}${h.note ? " · " + esc(h.note) : ""}</small></div>
          ${readonly ? "" : `<button class="mini secundario" data-delcol="${esc(h.id)}">Apagar</button>`}</li>`).join("")}</ul>` : ""}
      ${readonly ? "" : `<details data-bal="prod-${aid}" ${abertos.has("prod-" + a.id) ? "open" : ""}>
        <summary>Registrar colheita</summary>
        <label>Colmeia<select id="col-cx-${aid}"><option value="">Apiário todo (sem colmeia definida)</option>${
          colmeias.map((h) => `<option value="${esc(h.id)}">${esc(h.label)}</option>`).join("")}</select></label>
        <label>Data da colheita<input type="date" id="col-dt-${aid}" value="${hoje}"></label>
        <label>Mel colhido (kg)<input type="number" id="col-kg-${aid}" min="0.1" step="0.1" inputmode="decimal"></label>
        <label>Observação (opcional)<input id="col-obs-${aid}" maxlength="200" placeholder="Ex.: florada de eucalipto"></label>
        <button data-addcol="${aid}">Salvar colheita</button>
      </details>
      <button class="secundario" data-share="${aid}">Gerar link para compartilhar (só visualização)</button>`}
    </article>`;
  }).join("");
}

export function balanca(d, pts, { abertos = new Set(), readonly = false } = {}) {
  if (d.last_scale_raw === null && d.scale_factor === null) {
    return `<p class="msg sem-balanca">Sem balança nesta caixa: só proteção antifurto.
      O peso do apiário é acompanhado pela colmeia sentinela (a caixa com balança).</p>`;
  }
  const calibrada = d.scale_factor !== null;
  let ganho = "—";
  if (d.harvest_base_kg !== null && d.last_weight_kg !== null) {
    ganho = `${(d.last_weight_kg - d.harvest_base_kg >= 0 ? "+" : "")}${kg(d.last_weight_kg - d.harvest_base_kg)} de ${kg(d.harvest_gain_kg)}`;
  } else if (d.harvest_base_at) {
    ganho = "aguardando a próxima pesagem";
  }
  const id = esc(d.id);
  return `<div class="balanca">
      <h3>Balança</h3>
      ${calibrada ? `<div class="grid">
        <div><span>Peso agora</span><b>${kg(d.last_weight_kg)}</b></div>
        <div><span>Ganho desde a melgueira</span><b>${esc(ganho)}</b></div>
      </div>${grafico(pts)}` : `<p class="aviso-txt">Balança ainda não calibrada.${readonly ? "" : " Abra os ajustes abaixo."}</p>`}
      ${readonly ? "" : `<details data-bal="${id}" ${abertos.has(d.id) || !calibrada ? "open" : ""}>
        <summary>Ajustes da balança</summary>
        <p class="msg">Última pesagem recebida: ${ago(d.last_scale_raw_at)}.</p>
        <h4>Calibrar</h4>
        <ol class="passos">
          <li>Tire tudo de cima da balança, aperte o botão <b>RST</b> da placa e espere 2 minutos.
            <button class="secundario" data-zero="${id}">1. Balança vazia: zerar</button></li>
          <li>Coloque um peso conhecido (um galão de 5 litros de água pesa <b>5 kg</b>), aperte <b>RST</b> e espere 2 minutos.
            <label>Peso colocado (kg)<input type="number" min="1" max="200" step="0.1" value="5" data-pesokg="${id}"></label>
            <button class="secundario" data-calib="${id}">2. Calibrar</button></li>
          <li>Tire o peso e coloque a colmeia na balança.</li>
        </ol>
        <h4>Colheita e alimento</h4>
        <label>Avisar a colheita quando ganhar (kg)<input type="number" min="1" max="100" step="0.5" value="${esc(d.harvest_gain_kg)}" data-ganho="${id}"></label>
        <label>Avisar falta de alimento abaixo de (kg, opcional)<input type="number" min="1" max="200" step="0.5" value="${esc(d.hunger_kg ?? "")}" data-fome="${id}"></label>
        <button class="secundario" data-salvar="${id}">Salvar</button>
        <button data-melgueira="${id}">Coloquei a melgueira agora</button>
        <p class="msg">Depois de colocar a melgueira, o peso de referência é a próxima pesagem (até 3 horas).</p>
      </details>`}
    </div>`;
}

export function statusDe(d, alertas) {
  const aberto = alertas.find((a) => a.device_id === d.id && ["pendente", "escalado", "roubo_confirmado"].includes(a.status));
  if (d.mode === "roubo") return ['alerta', "RASTREAMENTO INTENSIVO"];
  if (aberto?.kind === "movimento") return ["alerta", "movimento — aguardando resposta"];
  if (aberto?.kind === "offline") return ["aviso", "sem comunicação"];
  if (d.maintenance_until && new Date(d.maintenance_until) > new Date()) return ["aviso", `manutenção até ${fmtDate(d.maintenance_until)}`];
  return ["ok", "protegida"];
}

