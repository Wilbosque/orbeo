// Orbeo · Consulta ao DataJud (Supabase Edge Function)
//
// Dois modos:
//   { acao: "processo", processo_id }  → botão "Atualizar agora" (precisa de login e acesso ao processo)
//   { acao: "rodada" }                 → agendamento diário (precisa do cabeçalho x-cron-secret)
//
// Respeita o limite do CNJ: no máximo `datajud_teto_minuto` requisições por minuto (padrão 119).
// A chave pública do DataJud pode mudar: se mudar, cadastre a nova em
// Edge Functions → Secrets → DATAJUD_API_KEY (sem precisar mexer neste código).
import { createClient } from 'npm:@supabase/supabase-js@2'

const CHAVE_PADRAO = 'cDZHYzlZa0JadVREZDJCendQbXY6SkJlTzNjLV9TRENyQk1RdnFKZGRQdw=='
const BASE = 'https://api-publica.datajud.cnj.jus.br'
const TEMPO_MAXIMO_RODADA_MS = 110_000 // cada chamada agendada trabalha ~2 min e para

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cron-secret',
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
  const atualizar: Record<string, unknown> = { datajud_sync_em: agora }
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
    if (p.datajud_sync_em && Date.now() - new Date(p.datajud_sync_em).getTime() < intervalo * 60_000) {
      const faltam = Math.ceil((intervalo * 60_000 - (Date.now() - new Date(p.datajud_sync_em).getTime())) / 60_000)
      return resposta({ novos: 0, aviso: `Consultado há pouco. Tente de novo em ${faltam} min. (O DataJud atualiza uma vez por dia.)` })
    }
    try { return resposta(await sincronizar(servico, p)) }
    catch (e) { return falha((e as Error).message, e instanceof ErroDataJud && e.status === 429 ? 429 : 502) }
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

  return falha('Ação desconhecida.')
}

// No Supabase (Deno) inicia o servidor; em testes locais só exporta as funções.
// @ts-ignore: Deno existe no ambiente do Supabase
if (typeof Deno !== 'undefined' && Deno.serve) Deno.serve(tratar)
