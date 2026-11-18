// Orbeo · Consulta ao DataJud e ao DJEN (Supabase Edge Function)
//
// Modos:
//   { acao: "processo", processo_id }  → botão "Atualizar agora": DataJud + DJEN do processo (precisa de login)
//   { acao: "rodada" }                 → agendamento do DataJud (cabeçalho x-cron-secret)
//   { acao: "rodada_djen" }            → agendamento do DJEN (cabeçalho x-cron-secret)
//   { acao: "pesquisa", nome, inicio?, fim?, tribunal? } → aba "Buscar processos": DJEN pelo nome da parte (precisa de login).
//                                       Sem datas = busca geral.
//   { acao: "push_chave" } / { acao: "push_teste" } / { acao: "rodada_avisos" } → notificações no celular
//   { acao: "rodada_descoberta" } → busca diária de processos NOVOS pelo nome de cada cliente (cabeçalho x-cron-secret)
//
// DataJud: no máximo `datajud_teto_minuto` requisições por minuto (padrão 119; limite 120).
// DJEN: busca só pelo NÚMERO de cada processo cadastrado; no máximo `djen_teto_minuto` por minuto (padrão 19; limite 20).
// O DJEN recusa acessos de fora do Brasil: o app chama esta função na região de São Paulo (sa-east-1).
// A chave pública do DataJud pode mudar: se mudar, cadastre a nova em
// Edge Functions → Secrets → DATAJUD_API_KEY (sem precisar mexer neste código).
import { createClient } from 'npm:@supabase/supabase-js@2'

const CHAVE_PADRAO = 'cDZHYzlZa0JadVREZDJCendQbXY6SkJlTzNjLV9TRENyQk1RdnFKZGRQdw=='
const BASE = 'https://api-publica.datajud.cnj.jus.br'
const DJEN = 'https://comunicaapi.pje.jus.br/api/v1/comunicacao'
const TEMPO_MAXIMO_RODADA_MS = 110_000 // cada chamada agendada trabalha ~2 min e para

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cron-secret, x-region',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const resposta = (corpo: unknown, status = 200) =>
  new Response(JSON.stringify(corpo), { status, headers: { ...CORS, 'Content-Type': 'application/json' } })
const falha = (mensagem: string, status = 400) => resposta({ erro: mensagem }, status)
const dormir = (ms: number) => new Promise(r => setTimeout(r, ms))

// ---------------------------------------------------------------------------
// Funções puras (testáveis)
// ---------------------------------------------------------------------------

/** Sigla do tribunal (TJBA, TRT5, TRE-BA, TJDF, TJM-MG...) → alias do índice no DataJud */
export function aliasDataJud(sigla: string): string | null {
  const s = (sigla || '').toUpperCase().replace(/\s+/g, '')
  if (s === 'STF' || s === 'CNJ' || s === 'CJF') return null // não estão na API pública
  if (s === 'TJDF' || s === 'TJDFT') return 'api_publica_tjdft'
  const tjm = s.match(/^TJM-?(MG|RS|SP)$/)
  if (tjm) return `api_publica_tjm${tjm[1].toLowerCase()}`
  const tre = s.match(/^TRE-?([A-Z]{2})$/)
  if (tre) return `api_publica_tre-${tre[1].toLowerCase()}`
  if (/^(TJ[A-Z]{2}|TRF[1-6]|TRT([1-9]|1\d|2[0-4])|STJ|TST|TSE|STM)$/.test(s)) return `api_publica_${s.toLowerCase()}`
  return null
}

/** Aceita "2023-05-10T10:21:33.000Z", "2023-05-10T10:21:33" e "20230510102133" */
export function lerDataHora(v: unknown): string | null {
  if (!v) return null
  const t = String(v).trim()
  const compacto = t.match(/^(\d{4})(\d{2})(\d{2})(\d{2})?(\d{2})?(\d{2})?$/)
  if (compacto) {
    const [, ano, mes, dia, h = '00', mi = '00', seg = '00'] = compacto
    const dt = new Date(`${ano}-${mes}-${dia}T${h}:${mi}:${seg}-03:00`)
    return isNaN(dt.getTime()) ? null : dt.toISOString()
  }
  const iso = /[zZ]|[+-]\d{2}:?\d{2}$/.test(t) ? t : `${t}-03:00`
  const d = new Date(iso)
  return isNaN(d.getTime()) ? null : d.toISOString()
}

type Mov = { codigo_tpu: number | null; nome: string; complemento: string | null; data_hora: string; orgao: string | null }

/** Junta os movimentos de todos os graus (G1, G2, JE, TR...) e tira repetidos */
export function extrairMovimentos(hits: any[]): Mov[] {
  const vistos = new Set<string>()
  const lista: Mov[] = []
  for (const h of hits) {
    for (const m of h?._source?.movimentos || []) {
      const data_hora = lerDataHora(m.dataHora)
      if (!data_hora || !m.nome) continue
      const compl = (m.complementosTabelados || [])
        .map((c: any) => [c.descricao, c.nome].filter(Boolean).join(': ').replace(/_/g, ' '))
        .filter(Boolean).join(' · ') || null
      const item = {
        codigo_tpu: Number.isFinite(Number(m.codigo)) ? Number(m.codigo) : null,
        nome: String(m.nome).trim(),
        complemento: compl,
        data_hora,
        orgao: m.orgaoJulgador?.nomeOrgao || m.orgaoJulgador?.nome || null,
      }
      const chave = `${item.codigo_tpu}|${item.data_hora}|${item.nome}`
      if (vistos.has(chave)) continue
      vistos.add(chave); lista.push(item)
    }
  }
  return lista.sort((a, b) => a.data_hora.localeCompare(b.data_hora))
}

/** Dados de capa: prefere o 1º grau; senão, o registro mais recente */
export function extrairCapa(hits: any[]) {
  if (!hits.length) return null
  const fontes = hits.map(h => h._source || {})
  const g1 = fontes.find(f => f.grau === 'G1' || f.grau === 'JE') || fontes[0]
  return {
    classe: g1.classe?.nome || null,
    orgao_julgador: g1.orgaoJulgador?.nome || null,
    municipio_ibge: Number(g1.orgaoJulgador?.codigoMunicipioIBGE) || null,
    data_distribuicao: lerDataHora(g1.dataAjuizamento)?.slice(0, 10) || null,
  }
}

/** Andamento que indica audiência marcada (designada/redesignada) */
export function ehAudienciaDesignada(m: { nome: string; complemento: string | null }) {
  const t = `${m.nome} ${m.complemento || ''}`.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase()
  return /audiencia/.test(t) && /(designad|redesignad|marcad|agendad)/.test(t) && !/(cancelad|realizad|nao realizad)/.test(t)
}

/** Tipo de audiência a partir do texto do andamento */
export function tipoAudiencia(texto: string) {
  const t = (texto || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase()
  if (/concilia/.test(t)) return 'conciliacao'
  if (/instru/.test(t)) return 'instrucao'
  if (/\buna\b/.test(t)) return 'una'
  if (/inicial/.test(t)) return 'inicial'
  if (/julgamento/.test(t)) return 'julgamento'
  return 'outra'
}

/** Data mais recente em que o tribunal atualizou o processo na base do DataJud */
export function ultimaAtualizacaoBase(hits: any[]): string | null {
  const datas = hits.map(h => lerDataHora(h?._source?.dataHoraUltimaAtualizacao)).filter(Boolean) as string[]
  return datas.sort().pop() || null
}

// ---------- DJEN (funções puras) ----------
/** "2026-11-12", "2026-11-12T00:00:00" ou "12/11/2026" → "2026-11-12" */
export function lerData(v: unknown): string | null {
  if (!v) return null
  const t = String(v).trim()
  const br = t.match(/^(\d{2})\/(\d{2})\/(\d{4})/)
  if (br) return `${br[3]}-${br[2]}-${br[1]}`
  const iso = t.match(/^(\d{4})-(\d{2})-(\d{2})/)
  return iso ? `${iso[1]}-${iso[2]}-${iso[3]}` : null
}

/** Tira HTML do texto da publicação, mantendo as quebras de parágrafo */
export function textoLimpo(html: unknown): string {
  return String(html || '')
    .replace(/<\s*br\s*\/?>/gi, '\n').replace(/<\/(p|div|li|tr|h\d)>/gi, '\n')
    .replace(/<\/?(b|i|u|em|strong|span|a|font|sup|sub)\b[^>]*>/gi, '')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'")
    .replace(/[ \t]+/g, ' ').replace(/ ([,.;:])/g, '$1').replace(/ *\n */g, '\n').replace(/\n{3,}/g, '\n\n').trim()
}

const soDigitos = (v: unknown) => String(v || '').replace(/\D/g, '')

/** Converte um item da API do DJEN no registro da tabela publicacoes (aceita variações de nome de campo) */
export function itemDJEN(it: any) {
  const numero = soDigitos(it.numero_processo ?? it.numeroProcesso ?? it.numeroprocessocommascara)
  const data = lerData(it.data_disponibilizacao ?? it.dataDisponibilizacao ?? it.datadisponibilizacao)
  const id = Number(it.id)
  if (!numero || !data || !Number.isFinite(id)) return null
  const advs = (it.destinatarioadvogados || it.advogados || [])
    .map((x: any) => x?.advogado || x).filter(Boolean)
    .map((a: any) => ({ nome: a.nome || null, oab: a.numero_oab || a.numeroOab || null, uf: a.uf_oab || a.ufOab || null }))
  const dests = (it.destinatarios || []).map((d: any) => ({ nome: d.nome || null, polo: d.polo || null }))
  return {
    djen_id: id,
    numero_cnj: numero,
    tribunal: it.siglaTribunal || it.sigla_tribunal || null,
    orgao_julgador: it.nomeOrgao || it.nome_orgao || null,
    tipo_comunicacao: it.tipoComunicacao || it.tipo_comunicacao || null,
    tipo_documento: it.tipoDocumento || it.tipo_documento || null,
    data_disponibilizacao: data,
    texto: textoLimpo(it.texto),
    link: it.link || null,
    numero_comunicacao: it.numeroComunicacao != null ? String(it.numeroComunicacao) : null,
    meio: it.meiocompleto || it.meio || null,
    classe: it.nomeClasse || it.nome_classe || null,
    destinatarios: dests.length ? dests : null,
    advogados_intimados: advs.length ? advs : null,
    hash: it.hash || null,
  }
}

const normalizar = (v: unknown) => String(v || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '')
  .toLowerCase().replace(/[^a-z0-9 ]/g, ' ').replace(/\s+/g, ' ').trim()

/** Junta as publicações por processo e indica em que polo aparece o nome pesquisado */
export function agruparPorProcesso(itens: any[], nome: string) {
  const alvo = normalizar(nome)
  const mapa = new Map<string, any>()
  for (const it of itens) {
    const r = itemDJEN(it)
    if (!r) continue
    let g = mapa.get(r.numero_cnj)
    if (!g) {
      g = { numero_cnj: mascaraCNJ(r.numero_cnj), tribunal: r.tribunal, orgao_julgador: r.orgao_julgador, classe: r.classe,
            partes: [] as any[], publicacoes: 0, primeira: r.data_disponibilizacao, ultima: r.data_disponibilizacao,
            ultimo_tipo: null, ultimo_trecho: '', link: r.link, polo_pesquisado: null as string | null, cita_nome: false }
      mapa.set(r.numero_cnj, g)
    }
    g.publicacoes++
    if (r.data_disponibilizacao < g.primeira) g.primeira = r.data_disponibilizacao
    if (r.data_disponibilizacao >= g.ultima) {
      g.ultima = r.data_disponibilizacao; g.ultimo_tipo = r.tipo_documento || r.tipo_comunicacao
      g.ultimo_trecho = r.texto.slice(0, 280); g.link = r.link || g.link
      if (r.orgao_julgador) g.orgao_julgador = r.orgao_julgador
    }
    if (!g.classe && r.classe) g.classe = r.classe
    if (alvo && (normalizar(r.texto).includes(alvo) || (r.destinatarios || []).some((d: any) => normalizar(d.nome).includes(alvo)))) g.cita_nome = true
    for (const d of r.destinatarios || []) {
      if (!d.nome || g.partes.some((x: any) => normalizar(x.nome) === normalizar(d.nome))) continue
      g.partes.push(d)
      if (alvo && normalizar(d.nome).includes(alvo) && !g.polo_pesquisado) {
        const pl = String(d.polo || '').toUpperCase()
        g.polo_pesquisado = pl.startsWith('A') ? 'autor' : pl.startsWith('P') ? 'reu' : null
      }
    }
  }
  return [...mapa.values()].sort((a, b) => b.ultima.localeCompare(a.ultima))
}

/** Número CNJ só com dígitos → com máscara */
export function mascaraCNJ(n: string) {
  const d = soDigitos(n)
  return d.length === 20 ? `${d.slice(0, 7)}-${d.slice(7, 9)}.${d.slice(9, 13)}.${d.slice(13, 14)}.${d.slice(14, 16)}.${d.slice(16)}` : d
}

// ---------------------------------------------------------------------------
// DataJud
// ---------------------------------------------------------------------------
class ErroDataJud extends Error { constructor(m: string, public status = 0, public parar = false) { super(m) } }

/** POST no DataJud com até 3 tentativas quando o CNJ responde 502/503/504 (instabilidade do lado deles) */
async function postDataJud(alias: string, corpo: unknown, tentativas = 3) {
  const chave = Deno.env.get('DATAJUD_API_KEY') || CHAVE_PADRAO
  let r: Response | null = null
  for (let i = 0; i < tentativas; i++) {
    try {
      r = await fetch(`${BASE}/${alias}/_search`, {
        method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `APIKey ${chave}` },
        body: JSON.stringify(corpo), signal: AbortSignal.timeout(40_000),
      })
      if (![502, 503, 504].includes(r.status)) return r
    } catch (_) { r = null } // tempo esgotado ou conexão caiu: tenta de novo
    await dormir(1500 * (i + 1) + Math.random() * 1000)
  }
  if (!r) throw new ErroDataJud('O DataJud não respondeu (tempo esgotado). É instabilidade do CNJ; a consulta é refeita na próxima rodada.', 504)
  return r
}

async function consultarDataJud(alias: string, numero20: string) {
  const r = await postDataJud(alias, { query: { match: { numeroProcesso: numero20 } }, size: 10 })
  if (r.status === 401 || r.status === 403) throw new ErroDataJud('O DataJud recusou a chave de acesso. A chave pública pode ter mudado: veja a chave atual na wiki do DataJud e cadastre em Edge Functions → Secrets → DATAJUD_API_KEY.', r.status, true)
  if (r.status === 429) throw new ErroDataJud('Limite de consultas do DataJud atingido. A rodada continua na próxima execução.', 429, true)
  if (r.status === 404) throw new ErroDataJud('Tribunal não disponível na API pública do DataJud.', 404)
  if ([502, 503, 504].includes(r.status)) throw new ErroDataJud(`O DataJud está instável agora (erro ${r.status}, do lado do CNJ). Tentei 3 vezes; a consulta é refeita sozinha na próxima rodada. Seus dados no Orbeo não foram afetados.`, r.status, true)
  if (!r.ok) throw new ErroDataJud(`O DataJud respondeu com erro ${r.status}.`, r.status, r.status >= 500)
  const j = await r.json()
  return (j?.hits?.hits || []) as any[]
}

const cacheMunicipio = new Map<number, string | null>()
async function nomeMunicipio(codigo: number | null) {
  if (!codigo) return null
  if (cacheMunicipio.has(codigo)) return cacheMunicipio.get(codigo)!
  try {
    const r = await fetch(`https://servicodados.ibge.gov.br/api/v1/localidades/municipios/${codigo}`)
    const nome = r.ok ? ((await r.json())?.nome ?? null) : null
    cacheMunicipio.set(codigo, nome); return nome
  } catch { cacheMunicipio.set(codigo, null); return null }
}

// ---------------------------------------------------------------------------
// Sincronizar um processo
// ---------------------------------------------------------------------------
async function sincronizar(servico: any, p: any) {
  const alias = aliasDataJud(p.tribunal)
  const agora = new Date().toISOString()
  if (!alias) {
    await servico.from('processos').update({ datajud_sync_em: agora }).eq('id', p.id)
    return { novos: 0, total: 0, aviso: `O tribunal ${p.tribunal} não está na API pública do DataJud.` }
  }
  const numero20 = String(p.numero_cnj).replace(/\D/g, '')
  const hits = await consultarDataJud(alias, numero20)
  const primeiraVez = !p.datajud_sync_em

  if (!hits.length) {
    await servico.from('processos').update({ datajud_sync_em: agora }).eq('id', p.id)
    return { novos: 0, total: 0, aviso: 'O processo ainda não aparece no DataJud. Processos novos ou sigilosos podem levar dias para aparecer, ou não aparecer.' }
  }

  const movs = extrairMovimentos(hits)
  let novos = 0
  const inseridos: any[] = []
  for (let i = 0; i < movs.length; i += 200) {
    const lote = movs.slice(i, i + 200).map(m => ({
      ...m, processo_id: p.id,
      // Na primeira consulta, o histórico entra como já visto (não vira "novidade")
      vista_em: primeiraVez ? agora : null,
    }))
    const { data, error } = await servico.from('movimentacoes')
      .upsert(lote, { onConflict: 'processo_id,codigo_tpu,data_hora,nome', ignoreDuplicates: true })
      .select('id,nome,complemento,data_hora')
    if (error) throw new Error(`Erro ao gravar andamentos: ${error.message}`)
    novos += data?.length || 0
    inseridos.push(...(data || []))
  }

  // Completa a capa só onde o cadastro está vazio (nunca sobrescreve o que o advogado digitou)
  const capa = extrairCapa(hits)
  const atualizar: Record<string, unknown> = { datajud_sync_em: agora, datajud_atualizado_em: ultimaAtualizacaoBase(hits) }
  if (capa) {
    if (!p.classe && capa.classe) atualizar.classe = capa.classe
    if (!p.orgao_julgador && capa.orgao_julgador) atualizar.orgao_julgador = capa.orgao_julgador
    if (!p.data_distribuicao && capa.data_distribuicao) atualizar.data_distribuicao = capa.data_distribuicao
    if (!p.municipio_ibge && capa.municipio_ibge) atualizar.municipio_ibge = capa.municipio_ibge
    if (!p.comarca && capa.municipio_ibge) {
      const nome = await nomeMunicipio(capa.municipio_ibge)
      if (nome) atualizar.comarca = nome
    }
  }
  await servico.from('processos').update(atualizar).eq('id', p.id)

  // Audiência designada → sugestão para o advogado informar data e hora.
  // Na 1ª consulta, só olha o último andamento de audiência, se for dos últimos 90 dias.
  let candidatos = inseridos.filter(ehAudienciaDesignada)
  if (primeiraVez) {
    const limite = Date.now() - 90 * 86_400_000
    const ultimoAud = [...inseridos].filter(m => /audi[eê]ncia/i.test(`${m.nome} ${m.complemento || ''}`))
      .sort((a, b) => String(b.data_hora).localeCompare(String(a.data_hora)))[0]
    candidatos = ultimoAud && ehAudienciaDesignada(ultimoAud) && new Date(ultimoAud.data_hora).getTime() > limite ? [ultimoAud] : []
  }
  for (const m of candidatos) {
    await servico.from('sugestoes').insert({
      tipo: 'audiencia', processo_id: p.id, movimentacao_id: m.id,
      dados: { tipo: tipoAudiencia(`${m.nome} ${m.complemento || ''}`), andamento: m.nome, complemento: m.complemento, andamento_em: m.data_hora },
      justificativa: `Andamento no DataJud: ${m.nome}${m.complemento ? ` (${m.complemento})` : ''}. O DataJud não informa a data da audiência: confira no processo e cadastre.`,
    })
  }
  return { novos: primeiraVez ? 0 : novos, total: movs.length, importados: primeiraVez ? novos : 0, audiencias_sugeridas: candidatos.length }
}

// ---------------------------------------------------------------------------
// DJEN
// ---------------------------------------------------------------------------
class ErroDJEN extends Error { constructor(m: string, public status = 0, public parar = false) { super(m) } }

const hojeSP = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo' }).format(new Date())
const menosDias = (iso: string, n: number) => { const d = new Date(`${iso}T12:00:00Z`); d.setUTCDate(d.getUTCDate() - n); return d.toISOString().slice(0, 10) }

/** Uma página da consulta ao DJEN. Devolve os itens e quanto a API diz que ainda resta na janela de limite. */
async function paginaDJEN(numero20: string, inicio: string, fim: string, pagina: number) {
  const q = new URLSearchParams({
    numeroProcesso: numero20, dataDisponibilizacaoInicio: inicio, dataDisponibilizacaoFim: fim,
    pagina: String(pagina), itensPorPagina: '100',
  })
  let r: Response
  try { r = await fetch(`${DJEN}?${q}`, { headers: { Accept: 'application/json' } }) }
  catch { throw new ErroDJEN('Não foi possível conectar ao DJEN agora. Tentaremos de novo na próxima consulta.', 0, true) }
  if (r.status === 429) throw new ErroDJEN('Limite de consultas do DJEN atingido. Continua na próxima consulta.', 429, true)
  if (r.status === 403 || r.status === 451) throw new ErroDJEN('O DJEN recusou o acesso deste servidor (ele só aceita conexões do Brasil). Avise o suporte do Orbeo.', r.status, true)
  if (!r.ok) throw new ErroDJEN(`O DJEN respondeu com erro ${r.status}.`, r.status, r.status >= 500)
  const j = await r.json().catch(() => ({}))
  const itens = (j?.items || j?.data || j?.comunicacoes || []) as any[]
  const restante = Number(r.headers.get('x-ratelimit-remaining'))
  return { itens, total: Number(j?.count ?? itens.length), restante: Number.isFinite(restante) ? restante : null }
}

const INICIO_DJEN = '2023-01-01'   // antes disso não há publicações no DJEN
const MAX_PAGINAS_PESQUISA = 10    // até 1.000 publicações por busca (~35 s respeitando 19/min)

class PrecisaPeriodo extends Error {}

/** Lê páginas de uma janela (com ou sem datas) até acabar ou até o teto de páginas */
async function lerJanela(nome: string, tribunal: string | null, inicio: string | null, fim: string | null, paginasRestantes: number) {
  const itens: any[] = []
  let pagina = 1, total = 0, usadas = 0, acabou = false
  while (usadas < paginasRestantes) {
    const q = new URLSearchParams({ nomeParte: nome, pagina: String(pagina), itensPorPagina: '100' })
    if (inicio) q.set('dataDisponibilizacaoInicio', inicio)
    if (fim) q.set('dataDisponibilizacaoFim', fim)
    if (tribunal) q.set('siglaTribunal', tribunal)
    let r: Response
    try { r = await fetch(`${DJEN}?${q}`, { headers: { Accept: 'application/json' } }) }
    catch { throw new ErroDJEN('Não foi possível conectar ao DJEN agora. Tente de novo em instantes.', 0, true) }
    usadas++
    if (r.status === 429) throw new ErroDJEN('Limite de consultas do DJEN atingido. Espere um minuto e tente de novo.', 429, true)
    if (r.status === 403 || r.status === 451) throw new ErroDJEN('O DJEN recusou o acesso deste servidor (ele só aceita conexões do Brasil). Avise o suporte do Orbeo.', r.status, true)
    // Sem datas, o DJEN pode exigir um período: aí a busca geral é feita em janelas de 1 ano
    if ((r.status === 400 || r.status === 422) && !inicio) throw new PrecisaPeriodo()
    if (!r.ok) throw new ErroDJEN(`O DJEN respondeu com erro ${r.status}.`, r.status)
    const j = await r.json().catch(() => ({}))
    const lote = (j?.items || j?.data || j?.comunicacoes || []) as any[]
    total = Number(j?.count ?? total)
    itens.push(...lote)
    if (lote.length < 100 || (total && itens.length >= total)) { acabou = true; break }
    pagina++
    const resta = Number(r.headers.get('x-ratelimit-remaining'))
    await dormir(Number.isFinite(resta) && resta <= 1 ? 60_000 : 3_200)
  }
  return { itens, total: Math.max(total, itens.length), usadas, completa: acabou }
}

/**
 * Busca pelo nome da parte. Sem período = busca geral (todo o DJEN).
 * Se o DJEN exigir datas, ou o período for maior que 1 ano, busca em janelas de 1 ano, das mais recentes para as antigas.
 */
export async function pesquisarNome(nome: string, inicio: string | null, fim: string | null, tribunal: string | null) {
  const hoje = hojeSP()
  const ate = fim || hoje
  const desde = inicio || INICIO_DJEN
  const span = (new Date(ate).getTime() - new Date(desde).getTime()) / 86_400_000
  if (!inicio && !fim) {
    try {
      const r = await lerJanela(nome, tribunal, null, null, MAX_PAGINAS_PESQUISA)
      return { itens: r.itens, total: r.total, truncado: !r.completa, coberto_desde: null as string | null }
    } catch (e) { if (!(e instanceof PrecisaPeriodo)) throw e }
  } else if (span <= 366) {
    const r = await lerJanela(nome, tribunal, desde, ate, MAX_PAGINAS_PESQUISA)
    return { itens: r.itens, total: r.total, truncado: !r.completa, coberto_desde: desde }
  }
  // Janelas de 1 ano, da mais recente para a mais antiga
  const itens: any[] = []
  let total = 0, paginas = MAX_PAGINAS_PESQUISA, fimJ = ate, truncado = false, coberto = ate
  while (fimJ > desde && paginas > 0) {
    const iniJ = menosDias(fimJ, 365) < desde ? desde : menosDias(fimJ, 365)
    const r = await lerJanela(nome, tribunal, iniJ, fimJ, paginas)
    itens.push(...r.itens); total += r.total; paginas -= r.usadas
    if (!r.completa) { truncado = true; coberto = iniJ; break }
    coberto = iniJ
    fimJ = menosDias(iniJ, 1)
    if (paginas > 0) await dormir(3_200)
  }
  if (fimJ > desde && paginas <= 0) truncado = true
  return { itens, total, truncado, coberto_desde: coberto }
}

async function sincronizarDJEN(servico: any, p: any, pausaMs: number) {
  const numero20 = soDigitos(p.numero_cnj)
  const fim = hojeSP()
  const primeiraVez = !p.djen_sync_em
  const diasPrimeira = Number(await lerConfig(servico, 'djen_dias_primeira_busca', 90))
  // Retoma 3 dias antes da última consulta (publicações podem entrar com atraso no índice)
  const inicio = primeiraVez ? menosDias(fim, diasPrimeira)
    : menosDias(new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo' }).format(new Date(p.djen_sync_em)), 3)

  let pagina = 1, requisicoes = 0
  const registros: any[] = []
  while (true) {
    const r = await paginaDJEN(numero20, inicio, fim, pagina); requisicoes++
    for (const it of r.itens) {
      const reg = itemDJEN(it)
      if (reg && reg.numero_cnj === numero20) registros.push(reg)
    }
    if (r.itens.length < 100 || pagina >= 10) break
    pagina++
    await dormir(r.restante !== null && r.restante <= 1 ? 60_000 : pausaMs)
  }

  // Grava sem duplicar (id do DJEN é único). Na 1ª consulta, publicações com mais de 15 dias entram como lidas.
  const corte = menosDias(fim, 15)
  let novas = 0
  for (const reg of registros) {
    const { data: pub } = await servico.rpc('proximo_dia_util', {
      d: reg.data_disponibilizacao, trib: p.tribunal, com: p.comarca, org: p.orgao_julgador, inst: p.instancia || '1g', esc: p.escritorio_id,
    })
    const linha = {
      ...reg, numero_cnj: p.numero_cnj,
      processo_id: p.id, data_publicacao: pub || null,
      status: primeiraVez && reg.data_disponibilizacao < corte ? 'lida' : 'nova',
    }
    const { data, error } = await servico.from('publicacoes').upsert(linha, { onConflict: 'djen_id,processo_id', ignoreDuplicates: true }).select('id')
    if (error) throw new Error(`Erro ao gravar publicações: ${error.message}`)
    if (data?.length && linha.status === 'nova') novas++
  }
  await servico.from('processos').update({ djen_sync_em: new Date().toISOString() }).eq('id', p.id)
  return { novas, total: registros.length, requisicoes }
}

async function lerConfig(servico: any, chave: string, padrao: any) {
  const { data } = await servico.from('configuracoes').select('valor').eq('chave', chave).maybeSingle()
  return data?.valor ?? padrao
}

// Início do dia de hoje em Brasília, em UTC
function inicioDoDiaSP() {
  const hoje = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo' }).format(new Date())
  return new Date(`${hoje}T00:00:00-03:00`).toISOString()
}

// ---------------------------------------------------------------------------
// Notificações no celular (Web Push, RFC 8030/8291/8292) só com WebCrypto
// ---------------------------------------------------------------------------
const b64u = (buf: ArrayBuffer | Uint8Array) => {
  const b = buf instanceof Uint8Array ? buf : new Uint8Array(buf)
  let s = ''; for (const x of b) s += String.fromCharCode(x)
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}
const deB64u = (s: string) => {
  const t = s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4)
  return Uint8Array.from(atob(t), c => c.charCodeAt(0))
}
const juntar = (...partes: Uint8Array[]) => {
  const out = new Uint8Array(partes.reduce((n, p) => n + p.length, 0)); let i = 0
  for (const p of partes) { out.set(p, i); i += p.length }
  return out
}
const txt = (s: string) => new TextEncoder().encode(s)

async function hkdf(salt: Uint8Array, ikm: Uint8Array, info: Uint8Array, bytes: number) {
  const k = await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits'])
  return new Uint8Array(await crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt, info }, k, bytes * 8))
}

/** Gera o par de chaves VAPID (P-256). Devolve a pública (base64url, 65 bytes) e a privada em JWK. */
export async function gerarChavesVapid() {
  const par = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']) as CryptoKeyPair
  const publica = b64u(await crypto.subtle.exportKey('raw', par.publicKey))
  const privada_jwk = await crypto.subtle.exportKey('jwk', par.privateKey)
  return { publica, privada_jwk }
}

/** Cifra a mensagem para o aparelho (aes128gcm, RFC 8291) */
export async function cifrarPush(mensagem: Uint8Array, p256dh: string, authSecret: string) {
  const uaPublica = deB64u(p256dh)
  const auth = deB64u(authSecret)
  const efemera = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']) as CryptoKeyPair
  const asPublica = new Uint8Array(await crypto.subtle.exportKey('raw', efemera.publicKey))
  const uaChave = await crypto.subtle.importKey('raw', uaPublica, { name: 'ECDH', namedCurve: 'P-256' }, false, [])
  const segredo = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: uaChave }, efemera.privateKey, 256))
  const ikm = await hkdf(auth, segredo, juntar(txt('WebPush: info\0'), uaPublica, asPublica), 32)
  const salt = crypto.getRandomValues(new Uint8Array(16))
  const cek = await hkdf(salt, ikm, txt('Content-Encoding: aes128gcm\0'), 16)
  const nonce = await hkdf(salt, ikm, txt('Content-Encoding: nonce\0'), 12)
  const chave = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['encrypt'])
  const cifrado = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, chave, juntar(mensagem, new Uint8Array([2]))))
  const rs = new Uint8Array([0, 0, 16, 0]) // 4096
  return juntar(salt, rs, new Uint8Array([asPublica.length]), asPublica, cifrado)
}

/** Token VAPID (JWT ES256) para o serviço de push do aparelho */
export async function tokenVapid(endpoint: string, privada_jwk: JsonWebKey, contato: string) {
  const aud = new URL(endpoint).origin
  const cab = b64u(txt(JSON.stringify({ typ: 'JWT', alg: 'ES256' })))
  const corpo = b64u(txt(JSON.stringify({ aud, exp: Math.floor(Date.now() / 1000) + 12 * 3600, sub: contato })))
  const chave = await crypto.subtle.importKey('jwk', privada_jwk, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign'])
  const assinatura = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, chave, txt(`${cab}.${corpo}`))
  return `${cab}.${corpo}.${b64u(assinatura)}`
}

async function chavesVapid(servico: any) {
  const { data } = await servico.from('push_chaves').select('publica,privada_jwk').eq('id', 1).maybeSingle()
  if (data) return data
  const novas = await gerarChavesVapid()
  const { error } = await servico.from('push_chaves').insert({ id: 1, ...novas })
  if (error) { // outra chamada criou ao mesmo tempo
    const { data: d2 } = await servico.from('push_chaves').select('publica,privada_jwk').eq('id', 1).single()
    return d2
  }
  return novas
}

type Aviso = { titulo: string; texto: string; url?: string; tag?: string }

/** Envia um aviso para todos os aparelhos do advogado. Apaga inscrições que o aparelho cancelou. */
async function enviarParaAdvogado(servico: any, advogadoId: string, aviso: Aviso) {
  const { data: inscricoes } = await servico.from('push_inscricoes').select('*').eq('advogado_id', advogadoId)
  if (!inscricoes?.length) return 0
  const { publica, privada_jwk } = await chavesVapid(servico)
  const contato = Deno.env.get('SUPABASE_URL') || 'https://orbeo.app'
  const mensagem = txt(JSON.stringify({ title: aviso.titulo, body: aviso.texto, url: aviso.url || '#/', tag: aviso.tag }))
  let enviados = 0
  for (const i of inscricoes) {
    try {
      const corpo = await cifrarPush(mensagem, i.p256dh, i.auth)
      const jwt = await tokenVapid(i.endpoint, privada_jwk, contato)
      const r = await fetch(i.endpoint, {
        method: 'POST',
        headers: { Authorization: `vapid t=${jwt}, k=${publica}`, 'Content-Encoding': 'aes128gcm', 'Content-Type': 'application/octet-stream', TTL: '43200', Urgency: 'high' },
        body: corpo,
      })
      if (r.status === 404 || r.status === 410) { await servico.from('push_inscricoes').delete().eq('id', i.id); continue }
      if (!r.ok) { await servico.from('push_inscricoes').update({ falhas: (i.falhas || 0) + 1 }).eq('id', i.id); continue }
      enviados++
      await servico.from('push_inscricoes').update({ ultimo_envio: new Date().toISOString(), falhas: 0 }).eq('id', i.id)
    } catch { await servico.from('push_inscricoes').update({ falhas: (i.falhas || 0) + 1 }).eq('id', i.id) }
  }
  return enviados
}

/** Registra o aviso no sino do Orbeo e envia aos aparelhos — só uma vez por chave e advogado.
 *  Fica registrado mesmo sem aparelho cadastrado, com o motivo de não ter chegado ao celular. */
async function avisarUmaVez(servico: any, advogadoId: string, chave: string, tipo: string, aviso: Aviso) {
  const { data: nova, error } = await servico.from('notificacoes')
    .insert({ advogado_id: advogadoId, chave, tipo, titulo: aviso.titulo, texto: aviso.texto, url: aviso.url || '#/' })
    .select('id').maybeSingle()
  if (error || !nova) return 0 // já avisado
  let n = 0, motivo: string | null = null
  try {
    n = await enviarParaAdvogado(servico, advogadoId, aviso)
    if (!n) {
      const { count } = await servico.from('push_inscricoes').select('id', { count: 'exact', head: true }).eq('advogado_id', advogadoId)
      motivo = count ? 'O aparelho não aceitou o envio. Desative e ative as notificações nele.' : 'Nenhum aparelho com notificações ativas.'
    }
  } catch (e) { motivo = 'Falha no envio: ' + (e as Error).message }
  await servico.from('notificacoes').update({ push_aparelhos: n, push_motivo: motivo }).eq('id', nova.id)
  return 1
}

type Prefs = { prazos: boolean; prazos_hora: number; prazos_dias: number; prazos_elaborar: boolean; audiencias: boolean; aud_vespera_hora: number | null;
  aud_horas_antes: number; publicacoes: boolean; novos: boolean; sugestoes: boolean; sugestoes_hora: number; escopo: 'meus' | 'escritorio' }
const PREFS_PADRAO: Prefs = { prazos: true, prazos_hora: 7, prazos_dias: 1, prazos_elaborar: true, audiencias: true, aud_vespera_hora: 18,
  aud_horas_antes: 2, publicacoes: true, novos: true, sugestoes: true, sugestoes_hora: 8, escopo: 'meus' }

/** Quem recebe avisos: todos os usuários ativos, com as preferências de cada um e os processos que cada um acompanha */
async function destinatarios(servico: any) {
  const { data: membros } = await servico.from('escritorio_membros').select('advogado_id,escritorio_id,visao_geral,advogados!inner(ativo)').eq('ativo', true)
  const ativos = (membros || []).filter((m: any) => m.advogados?.ativo !== false)
  const advogados = [...new Set(ativos.map((m: any) => m.advogado_id))] as string[]
  const { data: prefs } = await servico.from('notif_preferencias').select('*').in('advogado_id', advogados.length ? advogados : ['00000000-0000-0000-0000-000000000000'])
  const prefsDe = new Map<string, Prefs>(advogados.map(a => [a, { ...PREFS_PADRAO, ...((prefs || []).find((p: any) => p.advogado_id === a) || {}) }]))
  const procsDe = new Map<string, Set<string>>(advogados.map(a => [a, new Set<string>()]))
  const { data: vinc } = await servico.from('processo_advogados').select('processo_id,advogado_id,processos!inner(escritorio_id,situacao)').in('advogado_id', advogados.length ? advogados : ['00000000-0000-0000-0000-000000000000'])
  const membroDe = new Set(ativos.map((m: any) => `${m.advogado_id}|${m.escritorio_id}`))
  for (const v of vinc || []) if (membroDe.has(`${v.advogado_id}|${v.processos?.escritorio_id}`) && ['ativo', 'suspenso'].includes(v.processos?.situacao))
    procsDe.get(v.advogado_id)?.add(v.processo_id)
  // "Todos os processos do escritório": só para quem tem visão geral naquele escritório
  const escsGerais = new Map<string, string[]>()
  for (const m of ativos) if (m.visao_geral && prefsDe.get(m.advogado_id)?.escopo === 'escritorio')
    escsGerais.set(m.advogado_id, [...(escsGerais.get(m.advogado_id) || []), m.escritorio_id])
  const todosEscs = [...new Set([...escsGerais.values()].flat())]
  if (todosEscs.length) {
    const { data: procs } = await servico.from('processos').select('id,escritorio_id').in('escritorio_id', todosEscs).in('situacao', ['ativo', 'suspenso'])
    for (const [a, escs] of escsGerais) for (const p of procs || []) if (escs.includes(p.escritorio_id)) procsDe.get(a)!.add(p.id)
  }
  return { advogados, prefsDe, procsDe, escsGerais }
}

const dataBR = (iso: string) => iso.split('-').reverse().slice(0, 2).join('/')
const horaSP = (iso: string) => new Intl.DateTimeFormat('pt-BR', { timeZone: 'America/Sao_Paulo', hour: '2-digit', minute: '2-digit' }).format(new Date(iso))
const plural = (n: number, um: string, varios: string) => `${n} ${n === 1 ? um : varios}`

// ---------------------------------------------------------------------------
// Descoberta diária de processos novos (DJEN pelo nome de cada cliente)
// ---------------------------------------------------------------------------
async function rodadaDescoberta(servico: any) {
  const inicio = Date.now()
  const hoje = hojeSP()
  const diasPrimeira = Number(await lerConfig(servico, 'descoberta_dias_primeira_busca', 30))
  const teto = Math.max(1, Number(await lerConfig(servico, 'djen_teto_minuto', 19)))
  const pausa = Math.ceil(60_000 / teto)

  // Clientes com advogado vinculado; nomes de busca = os cadastrados no cliente, ou a razão social se for PJ sem nenhum
  // Só clientes com nomes monitorados (a opção "Monitorar publicações no DJEN pelo nome" no cadastro)
  const { data: termos } = await servico.from('monitoramentos').select('cliente_id,valor').eq('tipo', 'nome_parte').eq('ativo', true).not('cliente_id', 'is', null)
  const ids = [...new Set((termos || []).map((t: any) => t.cliente_id))] as string[]
  if (!ids.length) return { buscas: 0, novos: 0 }
  const { data: clientes } = await servico.from('clientes').select('id,tipo,nome,escritorio_id,copiado_de').in('id', ids)
  // Recebe o aviso quem atende o cliente E é membro ativo do escritório dele
  const { data: membrosAtivos } = await servico.from('escritorio_membros').select('advogado_id,escritorio_id').eq('ativo', true)
  const membro = new Set((membrosAtivos || []).map((m: any) => `${m.advogado_id}|${m.escritorio_id}`))
  const escCli = new Map((clientes || []).map((c: any) => [c.id, c.escritorio_id]))
  const { data: vinc } = await servico.from('cliente_advogados').select('cliente_id,advogado_id').in('cliente_id', ids)
  const advsDe = new Map<string, string[]>()
  for (const v of vinc || []) if (membro.has(`${v.advogado_id}|${escCli.get(v.cliente_id)}`))
    advsDe.set(v.cliente_id, [...(advsDe.get(v.cliente_id) || []), v.advogado_id])
  // Quem tem visão geral e escolheu acompanhar o escritório todo também recebe
  const ctxDest = await destinatarios(servico)
  for (const c of clientes || []) for (const [a, escs] of ctxDest.escsGerais)
    if (escs.includes(c.escritorio_id) && !(advsDe.get(c.id) || []).includes(a)) advsDe.set(c.id, [...(advsDe.get(c.id) || []), a])
  const escDe = new Map((clientes || []).map((c: any) => [c.id, c.escritorio_id]))
  const origemDe = new Map((clientes || []).filter((c: any) => c.copiado_de).map((c: any) => [c.id, c.copiado_de]))
  const pares: { cliente_id: string; termo: string }[] = []
  for (const c of clientes || []) {
    if (!(advsDe.get(c.id) || []).length) continue // ninguém para avisar
    const meus = [...new Set((termos || []).filter((t: any) => t.cliente_id === c.id).map((t: any) => String(t.valor).trim().toUpperCase()))]
    for (const termo of meus) if (termo.length >= 4) pares.push({ cliente_id: c.id, termo })
  }
  const { data: feitas } = await servico.from('descoberta_buscas').select('*')
  const ultima = new Map((feitas || []).map((b: any) => [`${b.cliente_id}|${b.termo}`, b.ultima_busca]))
  const inicioDia = inicioDoDiaSP()
  const fila = pares.filter(p => { const u = ultima.get(`${p.cliente_id}|${p.termo}`); return !u || u < inicioDia })
    .sort((a, b) => String(ultima.get(`${a.cliente_id}|${a.termo}`) || '').localeCompare(String(ultima.get(`${b.cliente_id}|${b.termo}`) || '')))

  let buscas = 0, novos = 0, erro = ''
  for (const p of fila) {
    if (Date.now() - inicio > TEMPO_MAXIMO_RODADA_MS) break
    const u = ultima.get(`${p.cliente_id}|${p.termo}`) as string | undefined
    const desde = u ? menosDias(new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo' }).format(new Date(u)), 2) : menosDias(hoje, diasPrimeira)
    try {
      const r = await lerJanela(p.termo, null, desde, hoje, 5); buscas += r.usadas
      const grupos = agruparPorProcesso(r.itens, p.termo).filter(g => g.cita_nome)
      if (grupos.length) {
        // Só o que ainda NÃO está no escritório do cliente
        const { data: existentes } = await servico.from('processos').select('numero_cnj').eq('escritorio_id', escDe.get(p.cliente_id)).in('numero_cnj', grupos.map(g => g.numero_cnj))
        const ja = new Set((existentes || []).map((e: any) => e.numero_cnj))
        // Cliente copiado de outro escritório (saída de advogado): processos que ficaram lá não são "novos"
        const origem = origemDe.get(p.cliente_id)
        if (origem) {
          const { data: daOrigem } = await servico.from('processos').select('numero_cnj').eq('cliente_id', origem).in('numero_cnj', grupos.map(g => g.numero_cnj))
          for (const e of daOrigem || []) ja.add(e.numero_cnj)
        }
        for (const g of grupos.filter(g => !ja.has(g.numero_cnj))) {
          const { data: d } = await servico.from('descobertas').upsert({
            cliente_id: p.cliente_id, numero_cnj: g.numero_cnj, tribunal: g.tribunal, orgao_julgador: g.orgao_julgador, classe: g.classe,
            partes: g.partes, polo_cliente: g.polo_pesquisado, publicacoes: g.publicacoes, primeira: g.primeira, ultima: g.ultima,
            ultimo_tipo: g.ultimo_tipo, trecho: g.ultimo_trecho, link: g.link, termo: p.termo, atualizado_em: new Date().toISOString(),
          }, { onConflict: 'cliente_id,numero_cnj' }).select('id').single()
          if (!d) continue
          const linhas = (advsDe.get(p.cliente_id) || []).map(a => ({ descoberta_id: d.id, advogado_id: a }))
          if (!linhas.length) continue
          const { data: criados } = await servico.from('descoberta_avisos').upsert(linhas, { onConflict: 'descoberta_id,advogado_id', ignoreDuplicates: true }).select('id')
          novos += criados?.length || 0
        }
      }
      await servico.from('descoberta_buscas').upsert({ cliente_id: p.cliente_id, termo: p.termo, ultima_busca: new Date().toISOString(), ultimo_erro: null })
    } catch (e) {
      erro = (e as Error).message
      await servico.from('descoberta_buscas').upsert({ cliente_id: p.cliente_id, termo: p.termo, ultima_busca: u || null, ultimo_erro: erro })
      if (e instanceof ErroDJEN && e.parar) break
    }
    await dormir(pausa)
  }
  await servico.from('sincronizacoes').insert({ fonte: 'djen', finalizada_em: new Date().toISOString(), status: erro ? 'parcial' : 'ok', requisicoes: buscas, novidades: novos,
    mensagem: erro ? `Descoberta de processos novos. Último erro: ${erro}` : `Descoberta de processos novos: ${novos} aviso(s) novo(s).` })
  // Avisa na hora, sem esperar a próxima rodada de avisos
  const avisados = novos ? await avisarDescobertas(servico) : 0
  return { buscas, novos, avisados, restantes: Math.max(0, fila.length - buscas) }
}

const TRIBUNAIS_COMARCAS = [
  ...['AC','AL','AP','AM','BA','CE','DFT','ES','GO','MA','MT','MS','MG','PA','PB','PR','PE','PI','RJ','RN','RS','RO','RR','SC','SP','SE','TO'].map(u => 'TJ' + u),
  ...Array.from({ length: 24 }, (_, i) => `TRT${i + 1}`), ...Array.from({ length: 6 }, (_, i) => `TRF${i + 1}`),
]
/** Catálogo de comarcas/subseções: municípios-sede das varas de cada tribunal, segundo o DataJud (1x por mês) */
async function rodadaComarcas(servico: any) {
  const inicio = Date.now()
  const { data: feitos } = await servico.from('comarcas_sync').select('tribunal,em,erro')
  const recente = new Set((feitos || []).filter((f: any) => !f.erro && f.em && Date.now() - new Date(f.em).getTime() < 20 * 86400_000).map((f: any) => f.tribunal))
  const resultado: Record<string, number | string> = {}
  for (const t of TRIBUNAIS_COMARCAS.filter(t => !recente.has(t))) {
    if (Date.now() - inicio > TEMPO_MAXIMO_RODADA_MS) break
    try {
      // Agregar o índice inteiro estoura o tempo do CNJ (504) nos tribunais grandes: olha só o que andou nos últimos 90 dias,
      // o que já cobre todas as varas em funcionamento; se ainda assim demorar, tenta com 30 dias.
      let r: Response | null = null
      for (const dias of [90, 30]) {
        r = await postDataJud(aliasDataJud(t)!, {
          size: 0, track_total_hits: false, timeout: '25s',
          query: { range: { dataHoraUltimaAtualizacao: { gte: `now-${dias}d` } } },
          aggs: { m: { terms: { field: 'orgaoJulgador.codigoMunicipioIBGE', size: 3000 } } },
        }, 2)
        if (r.ok) break
      }
      if (!r || !r.ok) throw new Error(`DataJud respondeu ${r?.status} (instabilidade do CNJ; tenta de novo na próxima rodada)`)
      const j = await r.json()
      const codigos = (j?.aggregations?.m?.buckets || []).map((b: any) => Number(b.key)).filter((n: number) => n > 1000000)
      if (!codigos.length) throw new Error('DataJud não trouxe municípios')
      const { data: n } = await servico.rpc('gravar_comarcas_datajud', { p_tribunal: t, p_codigos: codigos })
      await servico.from('comarcas_sync').upsert({ tribunal: t, em: new Date().toISOString(), total: codigos.length, erro: null })
      resultado[t] = n ?? codigos.length
    } catch (e) {
      await servico.from('comarcas_sync').upsert({ tribunal: t, em: new Date().toISOString(), total: null, erro: (e as Error).message })
      resultado[t] = (e as Error).message
    }
    await dormir(1200)
  }
  return { tribunais: resultado }
}

/** Processos novos (descobertas) ainda não avisados: vai direto ao fim da busca diária e também em cada rodada */
async function avisarDescobertas(servico: any, ctx?: Awaited<ReturnType<typeof destinatarios>>) {
  const { advogados, prefsDe } = ctx || await destinatarios(servico)
  const quem = advogados.filter(a => prefsDe.get(a)!.novos)
  if (!quem.length) return 0
  const { data: membrosAtivos } = await servico.from('escritorio_membros').select('advogado_id,escritorio_id').eq('ativo', true)
  const membro = new Set((membrosAtivos || []).map((m: any) => `${m.advogado_id}|${m.escritorio_id}`))
  const { data: descsTodas } = await servico.from('descoberta_avisos').select('id,advogado_id,descoberta_id,descobertas(numero_cnj,tribunal,clientes(nome,nome_fantasia,escritorio_id))')
    .eq('status', 'pendente').in('advogado_id', quem).gte('notificado_em', new Date(Date.now() - 7 * 86400_000).toISOString())
  const descs = (descsTodas || []).filter((d: any) => membro.has(`${d.advogado_id}|${d.descobertas?.clientes?.escritorio_id}`))
  let enviados = 0
  for (const a of quem) {
    const meus = (descs || []).filter((x: any) => x.advogado_id === a)
    if (!meus.length) continue
    const ineditos: any[] = []
    for (const d of meus) { const { error } = await servico.from('push_enviados').insert({ advogado_id: a, chave: `desc:${d.id}` }); if (!error) ineditos.push(d) }
    if (!ineditos.length) continue
    const um = ineditos[0].descobertas
    const cli = um?.clientes?.nome_fantasia || um?.clientes?.nome || 'cliente'
    const aviso = ineditos.length === 1
      ? { titulo: `Processo novo · ${cli}`, texto: `${um?.numero_cnj} · ${um?.tribunal || ''}. Toque para ver e decidir se cadastra.`, url: `#/novos?id=${ineditos[0].descoberta_id}`, tag: 'novos' }
      : { titulo: 'Processos novos identificados', texto: `${ineditos.length} processos dos seus clientes ainda não estão no Orbeo.`, url: '#/novos', tag: 'novos' }
    enviados += await avisarUmaVez(servico, a, `novos:${ineditos[0].id}`, 'novos', aviso)
  }
  return enviados
}

/** Rodada de avisos (agendada a cada 15 min). Respeita as preferências de cada usuário. */
async function rodadaAvisos(servico: any) {
  const agora = new Date()
  const hoje = hojeSP()
  const hora = Number(new Intl.DateTimeFormat('en-US', { timeZone: 'America/Sao_Paulo', hour: 'numeric', hourCycle: 'h23' }).format(agora))
  const ctx = await destinatarios(servico)
  const { advogados, prefsDe, procsDe } = ctx
  if (!advogados.length) return { enviados: 0, advogados: 0 }
  const meu = (a: string, processoId: string) => procsDe.get(a)?.has(processoId)
  let enviados = 0

  // 1) Prazos: resumo diário no horário escolhido, com a janela de dias escolhida
  const quemPrazos = advogados.filter(a => prefsDe.get(a)!.prazos && hora >= prefsDe.get(a)!.prazos_hora)
  if (quemPrazos.length) {
    const maxDias = Math.max(...quemPrazos.map(a => prefsDe.get(a)!.prazos_dias))
    const { data: przs } = await servico.from('prazos').select('id,processo_id,prazo_fatal,data_elaboracao,tipo,responsavel_id').eq('status', 'aberto')
      .or(`and(prazo_fatal.gte.${hoje},prazo_fatal.lte.${menosDias(hoje, -maxDias)}),data_elaboracao.eq.${hoje}`)
    for (const a of quemPrazos) {
      const p = prefsDe.get(a)!, limite = menosDias(hoje, -p.prazos_dias)
      const meus = (przs || []).filter((z: any) => meu(a, z.processo_id) || z.responsavel_id === a)
      const vencem = meus.filter((z: any) => z.prazo_fatal >= hoje && z.prazo_fatal <= limite)
      const elaborar = p.prazos_elaborar ? meus.filter((z: any) => z.data_elaboracao === hoje && !vencem.includes(z)) : []
      if (!vencem.length && !elaborar.length) continue
      const h = vencem.filter((z: any) => z.prazo_fatal === hoje).length, depois = vencem.length - h
      const quando = p.prazos_dias === 1 ? 'amanhã' : `nos próximos ${p.prazos_dias} dias`
      const partes = [h && `${plural(h, 'prazo vence', 'prazos vencem')} hoje`, depois && `${plural(depois, 'prazo vence', 'prazos vencem')} ${quando}`,
        elaborar.length && `${plural(elaborar.length, 'prazo marcado', 'prazos marcados')} para elaborar hoje`].filter(Boolean)
      enviados += await avisarUmaVez(servico, a, `prazos:${hoje}`, 'prazos', { titulo: 'Prazos', texto: partes.join(', ') + '.', url: '#/prazos', tag: 'prazos' })
    }
  }

  // 2) Audiências: véspera e algumas horas antes, nos horários escolhidos
  const { data: auds } = await servico.from('audiencias').select('id,processo_id,data_hora,tipo,processos(numero_cnj,clientes(nome))')
    .eq('status', 'agendada').gte('data_hora', agora.toISOString()).lte('data_hora', new Date(agora.getTime() + 48 * 3600_000).toISOString())
  const amanha = menosDias(hoje, -1)
  for (const au of auds || []) {
    const dia = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo' }).format(new Date(au.data_hora))
    const quem = au.processos?.clientes?.nome || 'Processo'
    const faltaMin = (new Date(au.data_hora).getTime() - agora.getTime()) / 60_000
    for (const a of advogados) {
      const p = prefsDe.get(a)!
      if (!p.audiencias || !meu(a, au.processo_id)) continue
      if (p.aud_vespera_hora != null && dia === amanha && hora >= p.aud_vespera_hora)
        enviados += await avisarUmaVez(servico, a, `aud-vespera:${au.id}`, 'audiencia', { titulo: 'Audiência amanhã', texto: `${quem} · ${horaSP(au.data_hora)} · ${au.processos?.numero_cnj || ''}`, url: `#/processos/${au.processo_id}`, tag: `aud-${au.id}` })
      if (p.aud_horas_antes > 0 && faltaMin <= p.aud_horas_antes * 60 + 7)
        enviados += await avisarUmaVez(servico, a, `aud-antes:${au.id}`, 'audiencia', { titulo: `Audiência às ${horaSP(au.data_hora)}`, texto: `${quem} · ${au.processos?.numero_cnj || ''}`, url: `#/processos/${au.processo_id}`, tag: `aud-${au.id}` })
    }
  }

  // 3) Publicações novas no DJEN (das últimas 48 h, ainda não lidas) — um aviso por lote
  const { data: pubs } = await servico.from('publicacoes').select('id,processo_id,tipo_documento,tipo_comunicacao,processos(clientes(nome))')
    .eq('status', 'nova').not('processo_id', 'is', null).gte('criado_em', new Date(agora.getTime() - 48 * 3600_000).toISOString())
  for (const a of advogados.filter(a => prefsDe.get(a)!.publicacoes)) {
    const meus = (pubs || []).filter((p: any) => meu(a, p.processo_id))
    const ineditas: any[] = []
    for (const p of meus) { const { error } = await servico.from('push_enviados').insert({ advogado_id: a, chave: `pub:${p.id}` }); if (!error) ineditas.push(p) }
    if (!ineditas.length) continue
    const um = ineditas[0]
    const aviso = ineditas.length === 1
      ? { titulo: 'Publicação nova no DJEN', texto: `${um.processos?.clientes?.nome || 'Processo'} · ${um.tipo_documento || um.tipo_comunicacao || 'Publicação'}`, url: `#/processos/${um.processo_id}`, tag: 'djen' }
      : { titulo: 'Publicações novas no DJEN', texto: `${ineditas.length} publicações em ${new Set(ineditas.map(p => p.processo_id)).size} processo(s).`, url: '#/processos?novidades=1', tag: 'djen' }
    enviados += await avisarUmaVez(servico, a, `pubs:${ineditas.map(p => p.id).sort()[0]}`, 'publicacao', aviso)
  }

  // 4) Processos novos de clientes
  enviados += await avisarDescobertas(servico, ctx)

  // 5) Sugestões pendentes do escritório (uma vez por dia, no horário escolhido)
  const { data: sugs } = await servico.from('sugestoes').select('id,tipo,processo_id,escritorio_id').eq('status', 'pendente')
  if (sugs?.length) {
    const { data: membros } = await servico.from('escritorio_membros').select('advogado_id,escritorio_id').eq('ativo', true).in('advogado_id', advogados)
    for (const a of advogados) {
      const p = prefsDe.get(a)!
      if (!p.sugestoes || hora < p.sugestoes_hora) continue
      const escs = new Set((membros || []).filter((m: any) => m.advogado_id === a).map((m: any) => m.escritorio_id))
      const n = sugs.filter((s: any) => (s.tipo === 'suspensao' && (!s.escritorio_id || escs.has(s.escritorio_id))) || (s.processo_id && meu(a, s.processo_id))).length
      if (n) enviados += await avisarUmaVez(servico, a, `sugestoes:${hoje}`, 'sugestoes', { titulo: 'Sugestões para confirmar', texto: `${plural(n, 'sugestão aguarda', 'sugestões aguardam')} a confirmação do escritório.`, url: '#/suspensoes', tag: 'sugestoes' })
    }
  }
  return { enviados, advogados: advogados.length }
}

// ---------------------------------------------------------------------------
// Servidor
// ---------------------------------------------------------------------------
async function tratar(req: Request) {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  if (req.method !== 'POST') return falha('Método não permitido.', 405)

  const servico = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })
  let corpo: Record<string, any>
  try { corpo = await req.json() } catch { return falha('Pedido inválido.') }

  // ---------- Botão "Atualizar agora" ----------
  if (corpo.acao === 'processo') {
    const token = (req.headers.get('Authorization') || '').replace('Bearer ', '')
    const { data: { user } } = await servico.auth.getUser(token)
    if (!user) return falha('Sessão inválida. Entre de novo.', 401)
    // Mesmas regras do banco: vinculado ao processo, visão geral no escritório ou responsável por um prazo dele
    const { data: p } = await servico.from('processos').select('*').eq('id', corpo.processo_id).maybeSingle()
    const { data: me } = await servico.from('advogados').select('escritorio_id,visao_geral,ativo').eq('id', user.id).maybeSingle()
    let pode = Boolean(p && me?.ativo && me.escritorio_id === p.escritorio_id)
    if (pode && !me!.visao_geral) {
      const { data: v } = await servico.from('processo_advogados').select('processo_id').eq('processo_id', p.id).eq('advogado_id', user.id).maybeSingle()
      const { data: z } = v ? { data: null } : await servico.from('prazos').select('id').eq('processo_id', p.id).eq('responsavel_id', user.id).limit(1).maybeSingle()
      pode = Boolean(v || z)
    }
    if (!pode) return falha('Processo não encontrado ou sem acesso.', 404)

    const intervalo = Number(await lerConfig(servico, 'atualizar_agora_intervalo_min', 10))
    const recente = (iso: string | null) => iso && Date.now() - new Date(iso).getTime() < intervalo * 60_000
    if (recente(p.datajud_sync_em) && recente(p.djen_sync_em)) {
      const ultimo = Math.max(new Date(p.datajud_sync_em).getTime(), new Date(p.djen_sync_em).getTime())
      const faltam = Math.ceil((intervalo * 60_000 - (Date.now() - ultimo)) / 60_000)
      return resposta({ novos: 0, aviso: `Consultado há pouco. Tente de novo em ${faltam} min.` })
    }
    // As duas consultas são independentes: se uma falhar, a outra continua valendo.
    const saida: Record<string, unknown> = {}
    if (!recente(p.datajud_sync_em)) {
      try { Object.assign(saida, await sincronizar(servico, p)) }
      catch (e) { saida.erro_datajud = (e as Error).message }
    }
    if (!recente(p.djen_sync_em)) {
      try { const d = await sincronizarDJEN(servico, p, 3200); saida.publicacoes_novas = d.novas; saida.publicacoes_total = d.total }
      catch (e) { saida.erro_djen = (e as Error).message }
    }
    if (saida.erro_datajud && saida.erro_djen) return falha(`DataJud: ${saida.erro_datajud} DJEN: ${saida.erro_djen}`, 502)
    return resposta(saida)
  }

  // ---------- Rodada agendada ----------
  if (corpo.acao === 'rodada') {
    const { data: ok } = await servico.rpc('cron_segredo_confere', { p: req.headers.get('x-cron-secret') || '' })
    if (!ok) return falha('Não autorizado.', 401)

    const inicio = Date.now()
    const teto = Math.max(1, Number(await lerConfig(servico, 'datajud_teto_minuto', 119)))
    const pausa = Math.ceil(60_000 / teto)                // 119/min → ~505 ms entre chamadas
    const diaArquivados = Number(await lerConfig(servico, 'datajud_arquivados_dia_semana', 0))
    const hojeDiaSemana = new Date(new Date().toLocaleString('en-US', { timeZone: 'America/Sao_Paulo' })).getDay()
    const situacoes = hojeDiaSemana === diaArquivados ? ['ativo', 'suspenso', 'arquivado', 'encerrado'] : ['ativo', 'suspenso']

    const { data: reg } = await servico.from('sincronizacoes').insert({ fonte: 'datajud' }).select('id').single()
    const { data: fila } = await servico.from('processos').select('*')
      .in('situacao', situacoes)
      .or(`datajud_sync_em.is.null,datajud_sync_em.lt.${inicioDoDiaSP()}`)
      .order('datajud_sync_em', { ascending: true, nullsFirst: true })
      .limit(300)

    let requisicoes = 0, novidades = 0, erros = 0, status = 'ok', mensagem = ''
    for (const p of fila || []) {
      if (Date.now() - inicio > TEMPO_MAXIMO_RODADA_MS) { status = 'parcial'; mensagem = 'Tempo da rodada esgotado; continua na próxima execução.'; break }
      try {
        const r = await sincronizar(servico, p)
        requisicoes++; novidades += r.novos || 0
      } catch (e) {
        requisicoes++; erros++
        if (e instanceof ErroDataJud && e.parar) { status = 'parcial'; mensagem = e.message; break }
        mensagem = `Último erro: ${(e as Error).message}`
      }
      await dormir(pausa)
    }
    const restantes = Math.max(0, (fila?.length || 0) - requisicoes)
    if (erros && status === 'ok') status = 'parcial'
    await servico.from('sincronizacoes').update({
      finalizada_em: new Date().toISOString(), status, requisicoes, novidades,
      cursor: { restantes_no_lote: restantes, erros },
      mensagem: mensagem || (requisicoes ? `${requisicoes} processo(s) consultado(s).` : 'Nada a consultar: todos já foram consultados hoje.'),
    }).eq('id', reg?.id)
    return resposta({ status, requisicoes, novidades, restantes })
  }

  // ---------- Notificações ----------
  if (corpo.acao === 'push_chave') {
    const { publica } = await chavesVapid(servico)
    return resposta({ publica })
  }
  if (corpo.acao === 'push_teste') {
    const token = (req.headers.get('Authorization') || '').replace('Bearer ', '')
    const { data: { user } } = await servico.auth.getUser(token)
    if (!user) return falha('Sessão inválida. Entre de novo.', 401)
    const aviso = { titulo: 'Orbeo', texto: 'Notificações ativadas. É assim que os avisos vão chegar.', url: '#/notificacoes', tag: 'teste' }
    const n = await enviarParaAdvogado(servico, user.id, aviso)
    await servico.from('notificacoes').insert({ advogado_id: user.id, chave: `teste:${Date.now()}`, tipo: 'teste', titulo: 'Aviso de teste', texto: aviso.texto, url: aviso.url,
      push_aparelhos: n, push_motivo: n ? null : 'Nenhum aparelho recebeu.' })
    if (!n) return falha('Nenhum aparelho recebeu. Desative e ative de novo as notificações neste aparelho.')
    return resposta({ enviados: n })
  }
  if (corpo.acao === 'rodada_avisos') {
    const { data: ok } = await servico.rpc('cron_segredo_confere', { p: req.headers.get('x-cron-secret') || '' })
    if (!ok) return falha('Não autorizado.', 401)
    return resposta(await rodadaAvisos(servico))
  }

  if (corpo.acao === 'rodada_comarcas') {
    const { data: ok } = await servico.rpc('cron_segredo_confere', { p: req.headers.get('x-cron-secret') || '' })
    if (!ok) return falha('Não autorizado.', 401)
    return resposta(await rodadaComarcas(servico))
  }

  if (corpo.acao === 'rodada_descoberta') {
    const { data: ok } = await servico.rpc('cron_segredo_confere', { p: req.headers.get('x-cron-secret') || '' })
    if (!ok) return falha('Não autorizado.', 401)
    return resposta(await rodadaDescoberta(servico))
  }

  // ---------- Aba "Buscar processos": DJEN pelo nome da parte ----------
  if (corpo.acao === 'pesquisa') {
    const token = (req.headers.get('Authorization') || '').replace('Bearer ', '')
    const { data: { user } } = await servico.auth.getUser(token)
    if (!user) return falha('Sessão inválida. Entre de novo.', 401)
    const nome = String(corpo.nome || '').trim().replace(/\s+/g, ' ')
    if (nome.length < 4) return falha('Digite pelo menos 4 letras do nome.')
    // Período é opcional: sem datas, a busca é geral
    const inicio = lerData(corpo.inicio), fim = lerData(corpo.fim)
    if (inicio && fim && inicio > fim) return falha('A data inicial é depois da final.')
    const tribunal = corpo.tribunal ? String(corpo.tribunal).toUpperCase().trim() : null
    try {
      const r = await pesquisarNome(nome, inicio, fim, tribunal)
      const processos = agruparPorProcesso(r.itens, nome)
      // Marca os que já estão no escritório: com link se o advogado enxerga; sem link se for de um colega (sigilo)
      const numeros = processos.map(p => p.numero_cnj)
      const { data: me } = await servico.from('advogados').select('escritorio_id,visao_geral').eq('id', user.id).maybeSingle()
      const doEscritorio = new Map<string, string>(), meus = new Set<string>()
      for (let i = 0; i < numeros.length; i += 200) {
        const { data } = await servico.from('processos').select('id,numero_cnj,processo_advogados(advogado_id)')
          .eq('escritorio_id', me?.escritorio_id).in('numero_cnj', numeros.slice(i, i + 200))
        for (const p of data || []) {
          doEscritorio.set(p.numero_cnj, p.id)
          if (me?.visao_geral || (p.processo_advogados || []).some((x: any) => x.advogado_id === user.id)) meus.add(p.numero_cnj)
        }
      }
      for (const p of processos) {
        p.processo_id = meus.has(p.numero_cnj) ? doEscritorio.get(p.numero_cnj) : null
        p.no_escritorio = doEscritorio.has(p.numero_cnj)
      }
      return resposta({ inicio, fim, publicacoes: r.itens.length, total: r.total, truncado: r.truncado, coberto_desde: r.coberto_desde, processos })
    } catch (e) { return falha((e as Error).message, e instanceof ErroDJEN && e.status === 429 ? 429 : 502) }
  }

  // ---------- Rodada agendada do DJEN ----------
  if (corpo.acao === 'rodada_djen') {
    const { data: ok } = await servico.rpc('cron_segredo_confere', { p: req.headers.get('x-cron-secret') || '' })
    if (!ok) return falha('Não autorizado.', 401)
    const inicio = Date.now()
    const teto = Math.max(1, Number(await lerConfig(servico, 'djen_teto_minuto', 19)))
    const pausa = Math.ceil(60_000 / teto)                 // 19/min → ~3,2 s entre chamadas
    const { data: reg } = await servico.from('sincronizacoes').insert({ fonte: 'djen' }).select('id').single()
    const { data: fila } = await servico.from('processos').select('*')
      .in('situacao', ['ativo', 'suspenso'])
      .or(`djen_sync_em.is.null,djen_sync_em.lt.${inicioDoDiaSP()}`)
      .order('djen_sync_em', { ascending: true, nullsFirst: true })
      .limit(100)
    let requisicoes = 0, consultados = 0, novidades = 0, erros = 0, status = 'ok', mensagem = ''
    for (const p of fila || []) {
      if (Date.now() - inicio > TEMPO_MAXIMO_RODADA_MS) { status = 'parcial'; mensagem = 'Tempo da rodada esgotado; continua na próxima execução.'; break }
      try {
        const r = await sincronizarDJEN(servico, p, pausa)
        requisicoes += r.requisicoes; consultados++; novidades += r.novas
      } catch (e) {
        requisicoes++; erros++
        if (e instanceof ErroDJEN && e.parar) { status = 'parcial'; mensagem = e.message; break }
        mensagem = `Último erro: ${(e as Error).message}`
      }
      await dormir(pausa)
    }
    if (erros && status === 'ok') status = 'parcial'
    await servico.from('sincronizacoes').update({
      finalizada_em: new Date().toISOString(), status, requisicoes, novidades,
      cursor: { restantes_no_lote: Math.max(0, (fila?.length || 0) - consultados), erros },
      mensagem: mensagem || (consultados ? `${consultados} processo(s) consultado(s) no DJEN.` : 'Nada a consultar: todos já foram consultados hoje.'),
    }).eq('id', reg?.id)
    return resposta({ status, requisicoes, novidades, consultados })
  }

  return falha('Ação desconhecida.')
}

// No Supabase (Deno) inicia o servidor; em testes locais só exporta as funções.
// @ts-ignore: Deno existe no ambiente do Supabase
if (typeof Deno !== 'undefined' && Deno.serve) Deno.serve(tratar)
