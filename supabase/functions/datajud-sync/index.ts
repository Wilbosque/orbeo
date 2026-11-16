// Orbeo · Consulta ao DataJud e ao DJEN (Supabase Edge Function)
//
// Modos:
//   { acao: "processo", processo_id }  → botão "Atualizar agora": DataJud + DJEN do processo (precisa de login)
//   { acao: "rodada" }                 → agendamento do DataJud (cabeçalho x-cron-secret)
//   { acao: "rodada_djen" }            → agendamento do DJEN (cabeçalho x-cron-secret)
//   { acao: "pesquisa", nome, inicio?, fim?, tribunal? } → aba "Buscar processos": DJEN pelo nome da parte (precisa de login).
//                                       Sem datas = busca geral.
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
            ultimo_tipo: null, ultimo_trecho: '', link: r.link, polo_pesquisado: null as string | null }
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

async function consultarDataJud(alias: string, numero20: string) {
  const chave = Deno.env.get('DATAJUD_API_KEY') || CHAVE_PADRAO
  const r = await fetch(`${BASE}/${alias}/_search`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `APIKey ${chave}` },
    body: JSON.stringify({ query: { match: { numeroProcesso: numero20 } }, size: 10 }),
  })
  if (r.status === 401 || r.status === 403) throw new ErroDataJud('O DataJud recusou a chave de acesso. A chave pública pode ter mudado: veja a chave atual na wiki do DataJud e cadastre em Edge Functions → Secrets → DATAJUD_API_KEY.', r.status, true)
  if (r.status === 429) throw new ErroDataJud('Limite de consultas do DataJud atingido. A rodada continua na próxima execução.', 429, true)
  if (r.status === 404) throw new ErroDataJud('Tribunal não disponível na API pública do DataJud.', 404)
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
      d: reg.data_disponibilizacao, trib: p.tribunal, com: p.comarca, org: p.orgao_julgador, inst: p.instancia || '1g',
    })
    const linha = {
      ...reg, numero_cnj: p.numero_cnj,
      processo_id: p.id, data_publicacao: pub || null,
      status: primeiraVez && reg.data_disponibilizacao < corte ? 'lida' : 'nova',
    }
    const { data, error } = await servico.from('publicacoes').upsert(linha, { onConflict: 'djen_id', ignoreDuplicates: true }).select('id')
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
    const { data: acesso } = await servico.from('processo_advogados').select('processo_id')
      .eq('processo_id', corpo.processo_id).eq('advogado_id', user.id).maybeSingle()
    if (!acesso) return falha('Processo não encontrado ou sem acesso.', 404)
    const { data: p } = await servico.from('processos').select('*').eq('id', corpo.processo_id).single()

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
      // Marca os que o próprio advogado já tem no Orbeo (só os dele: o sigilo continua valendo)
      const numeros = processos.map(p => p.numero_cnj)
      const meus = new Map<string, string>()
      for (let i = 0; i < numeros.length; i += 200) {
        const { data } = await servico.from('processos').select('id,numero_cnj,processo_advogados!inner(advogado_id)')
          .in('numero_cnj', numeros.slice(i, i + 200)).eq('processo_advogados.advogado_id', user.id)
        for (const p of data || []) meus.set(p.numero_cnj, p.id)
      }
      for (const p of processos) p.processo_id = meus.get(p.numero_cnj) || null
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
