// Acesso aos dados pelo Supabase. Toda regra de sigilo é aplicada pelo banco (RLS).
import { createClient } from '@supabase/supabase-js'
import { SUPABASE_URL, SUPABASE_ANON_KEY } from '../config.js'

const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: { persistSession: true, autoRefreshToken: true },
})

function ok({ data, error }) {
  if (error) throw traduzirErro(error)
  return data
}

function traduzirErro(e) {
  const msg = e.message || String(e)
  if (e.code === '23505' && /numero_cnj/.test(msg))
    return new Error('Este número já está cadastrado no escritório por outro advogado. Peça para incluírem você no processo.')
  if (e.code === '23505') return new Error('Já existe um cadastro com esses dados.')
  if (e.code === '23503' && /clientes/.test(msg))
    return new Error('Este cliente tem processos cadastrados. Exclua ou transfira os processos antes.')
  if (e.code === '42501' || /row-level security/.test(msg))
    return new Error('Você não tem acesso a este registro.')
  if (/Invalid login credentials/i.test(msg)) return new Error('E-mail ou senha incorretos.')
  if (/Failed to fetch|NetworkError/i.test(msg)) return new Error('Sem conexão com o servidor. Verifique a internet.')
  return new Error(msg)
}

// ---------- Login ----------
export async function sessaoAtual() {
  const { data } = await sb.auth.getSession()
  return data.session
}
export function aoMudarSessao(cb) {
  const { data } = sb.auth.onAuthStateChange((_e, s) => cb(s))
  return () => data.subscription.unsubscribe()
}
export async function entrar(email, senha) {
  ok(await sb.auth.signInWithPassword({ email, password: senha }))
}
export async function sair() { await sb.auth.signOut() }
export async function recuperarSenha(email) {
  ok(await sb.auth.resetPasswordForEmail(email, { redirectTo: window.location.href.split('#')[0] }))
}
export async function trocarSenha(nova) {
  ok(await sb.auth.updateUser({ password: nova }))
  const id = await uid()
  ok(await sb.from('advogados').update({ trocar_senha: false }).eq('id', id))
}

async function uid() {
  const { data } = await sb.auth.getUser()
  return data.user?.id
}

// ---------- Advogados ----------
export async function meuPerfil() {
  const id = await uid()
  const p = ok(await sb.from('advogados').select('*, advogado_oabs(id,numero,uf,principal), escritorios!advogados_escritorio_id_fkey(nome)').eq('id', id).maybeSingle())
  if (p) {
    p.dono = Boolean((await sb.rpc('sou_dono_plataforma')).data)
    p.espacos = ok(await sb.from('vw_meus_espacos').select('*').order('tipo').order('nome'))
    p.atual = (ok(await sb.rpc('espaco_atual')) || [])[0] || null
    p.observador = Boolean(p.atual?.observador)
  }
  return p
}
export async function trocarEspaco(escritorioId) { ok(await sb.rpc('trocar_espaco', { p_escritorio: escritorioId })) }
export async function salvarPerfil({ nome, oab_numero, oab_uf }) {
  const id = await uid()
  const { data: { user } } = await sb.auth.getUser()
  // O perfil é criado pelo administrador; aqui só se atualiza
  const perfil = ok(await sb.from('advogados')
    .update({ nome, oab_numero, oab_uf, email: user.email }).eq('id', id).select().single())
  // Monitorar as publicações da própria OAB no DJEN
  const existente = ok(await sb.from('monitoramentos').select('id')
    .eq('advogado_id', id).eq('tipo', 'oab').maybeSingle())
  if (existente) ok(await sb.from('monitoramentos').update({ valor: oab_numero, uf: oab_uf, ativo: true }).eq('id', existente.id))
  else ok(await sb.from('monitoramentos').insert({ advogado_id: id, tipo: 'oab', valor: oab_numero, uf: oab_uf }))
  return perfil
}
export async function listarAdvogados() {
  return ok(await sb.from('advogados').select('id,nome,oab_numero,oab_uf,papel,ativo,advogado_oabs(numero,uf,principal)').order('nome'))
}
// OABs (inscrição principal e suplementares). advogadoId vazio = o próprio usuário
export async function listarOabs(advogadoId) {
  let q = sb.from('advogado_oabs').select('id,advogado_id,numero,uf,principal').order('principal', { ascending: false }).order('uf')
  if (advogadoId) q = q.eq('advogado_id', advogadoId)
  return ok(await q)
}
export async function incluirOab(numero, uf, advogadoId = null) { return ok(await sb.rpc('incluir_oab', { p_numero: numero, p_uf: uf, p_advogado: advogadoId })) }
export async function tornarOabPrincipal(id) { ok(await sb.rpc('tornar_oab_principal', { p_id: id })) }
export async function removerOab(id) { ok(await sb.rpc('remover_oab', { p_id: id })) }

// ---------- Clientes ----------
export async function listarClientes() {
  return ok(await sb.from('vw_clientes').select('*').order('nome'))
}
export async function obterCliente(id) {
  return ok(await sb.from('vw_clientes').select('*').eq('id', id).maybeSingle())
}
export async function termosDoCliente(clienteId) {
  const id = await uid()
  return ok(await sb.from('monitoramentos').select('id,valor,ativo')
    .eq('cliente_id', clienteId).eq('advogado_id', id).eq('tipo', 'nome_parte').order('criado_em'))
}
export async function salvarCliente(c, termos) {
  const campos = {
    tipo: c.tipo, nome: c.nome.trim(), nome_fantasia: c.nome_fantasia || null,
    cpf_cnpj: c.cpf_cnpj || null, email: c.email || null, telefone: c.telefone || null,
    observacoes: c.observacoes || null, contato_nome: c.contato_nome || null,
  }
  const salvo = c.id
    ? ok(await sb.from('clientes').update(campos).eq('id', c.id).select().single())
    : ok(await sb.from('clientes').insert(campos).select().single())
  if (termos) await salvarTermos(salvo.id, termos)
  return salvo
}
// termos = lista de nomes a buscar no DJEN para este cliente (só para quem está logado)
async function salvarTermos(clienteId, termos) {
  const id = await uid()
  const atuais = await termosDoCliente(clienteId)
  const limpos = [...new Set(termos.map(t => t.trim().toUpperCase()).filter(Boolean))]
  const remover = atuais.filter(a => !limpos.includes(a.valor)).map(a => a.id)
  const incluir = limpos.filter(t => !atuais.some(a => a.valor === t))
  if (remover.length) ok(await sb.from('monitoramentos').delete().in('id', remover))
  if (incluir.length) ok(await sb.from('monitoramentos').insert(
    incluir.map(valor => ({ advogado_id: id, tipo: 'nome_parte', valor, cliente_id: clienteId }))))
}
export async function excluirCliente(id) {
  ok(await sb.from('clientes').delete().eq('id', id))
}

// ---------- Processos ----------
export async function listarProcessos(filtro = {}) {
  let q = sb.from('vw_processos').select('*')
  if (filtro.cliente_id) q = q.or(`cliente_id.eq.${filtro.cliente_id},partes.cs.[{"cliente_id":"${filtro.cliente_id}"}]`)
  return ok(await q.order('atualizado_em', { ascending: false }))
}
export async function obterProcesso(id) {
  return ok(await sb.from('vw_processos').select('*').eq('id', id).maybeSingle())
}
export async function processoPorNumero(numero) {
  return ok(await sb.from('vw_processos').select('id,numero_cnj').eq('numero_cnj', numero).maybeSingle())
}
export async function salvarProcesso(p, colegas = []) {
  const campos = {
    numero_cnj: p.numero_cnj, cliente_id: p.cliente_id, polo: p.polo,
    parte_contraria: p.parte_contraria || null, tribunal: p.tribunal,
    orgao_julgador: p.orgao_julgador || null, comarca: p.comarca || null, classe: p.classe || null,
    tipo_acao: p.tipo_acao || null, valor_causa: p.valor_causa ?? null, rito: p.rito || null, instancia: p.instancia || '1g',
    situacao: p.situacao || 'ativo', data_distribuicao: p.data_distribuicao || null,
    observacoes: p.observacoes || null,
  }
  const salvo = p.id
    ? ok(await sb.from('processos').update(campos).eq('id', p.id).select().single())
    : ok(await sb.from('processos').insert(campos).select().single())
  for (const advId of colegas) await incluirColega(salvo.id, advId)
  if (p.partes) ok(await sb.rpc('salvar_partes', { p_processo: salvo.id, p_partes: p.partes.map(x => ({ polo: x.polo, nome: x.nome, documento: x.documento || null, cliente_id: x.cliente_id || null })) }))
  return salvo
}
export async function darBaixa(processoId, d, motivo, obs, cancelarPrazos = true) {
  return ok(await sb.rpc('dar_baixa', { p_processo: processoId, p_data: d, p_motivo: motivo, p_obs: obs || null, p_cancelar_prazos: cancelarPrazos }))
}
export async function reativarProcesso(processoId) { ok(await sb.rpc('reativar_processo', { p_processo: processoId })) }
export async function registrarObservacao(processoId, texto) {
  return ok(await sb.from('anotacoes').insert({ processo_id: processoId, tipo: 'observacao', texto: texto.trim(), autor_id: await uid() }).select().single())
}
export async function excluirObservacao(id) { ok(await sb.from('anotacoes').delete().eq('id', id)) }
// Comarcas/foros do tribunal: catálogo do Orbeo (lista oficial + DataJud); se ainda vazio, usa a lista de municípios
export async function listarComarcas(tribunal) {
  const t = (tribunal || '').toUpperCase().replace(/\s+/g, '')
  const siglas = t === 'TJDF' || t === 'TJDFT' ? ['TJDF', 'TJDFT'] : [t]
  const { data } = await sb.from('comarcas').select('nome,tipo').in('tribunal', siglas).order('nome').limit(3000)
  const { comarcasReserva } = await import('./comarcas.js')
  if (data && data.length >= 5) {
    const nomes = data.map(c => c.nome)
    return t === 'TJSP' ? [...nomes.filter(n => n.startsWith('São Paulo - ')), ...nomes.filter(n => !n.startsWith('São Paulo - '))] : nomes
  }
  return comarcasReserva(t)
}
export async function excluirProcesso(id) {
  ok(await sb.from('processos').delete().eq('id', id))
}
export async function incluirColega(processoId, advogadoId) {
  const { error } = await sb.from('processo_advogados').insert({ processo_id: processoId, advogado_id: advogadoId })
  if (error && error.code !== '23505') throw traduzirErro(error)
}
export async function removerAdvogado(processoId, advogadoId) {
  ok(await sb.from('processo_advogados').delete().eq('processo_id', processoId).eq('advogado_id', advogadoId))
}

// ---------- Linha do tempo ----------
export async function linhaDoTempo(processoId) {
  return ok(await sb.from('vw_linha_do_tempo').select('*').eq('processo_id', processoId).neq('origem', 'observacao')
    .order('quando', { ascending: false }))
}
export async function listarObservacoes(processoId) {
  return ok(await sb.from('vw_linha_do_tempo').select('*').eq('processo_id', processoId).eq('origem', 'observacao')
    .order('quando', { ascending: false }))
}

// ---------- Prazos do dia (Início) ----------
// Data de hoje no fuso de São Paulo, como AAAA-MM-DD
export function hojeSP() {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo' }).format(new Date())
}
// Em aberto e: já vencidos, vencendo hoje, ou marcados para elaborar hoje
export async function prazosDoDia() {
  const hoje = hojeSP()
  return ok(await sb.from('vw_prazos')
    .select('id,processo_id,tipo,prazo_fatal,data_elaboracao,data_recebimento,numero_cnj,cliente,polo,tribunal,responsavel_id')
    .eq('status', 'aberto')
    .or(`prazo_fatal.lte.${hoje},data_elaboracao.eq.${hoje}`)
    .order('prazo_fatal'))
}

// ---------- Resumo (Início) ----------
export async function resumo() {
  const eu = await uid()
  const [proc, cli, pub, sug, desc] = await Promise.all([
    sb.from('processos').select('situacao'),
    sb.from('clientes').select('id', { count: 'exact', head: true }),
    sb.from('publicacoes').select('id', { count: 'exact', head: true }).eq('status', 'nova'),
    sb.from('sugestoes').select('tipo').eq('status', 'pendente'),
    sb.from('descoberta_avisos').select('id', { count: 'exact', head: true }).eq('advogado_id', eu).eq('status', 'pendente'),
  ])
  const ps = ok(proc)
  return {
    processos: ps.length,
    ativos: ps.filter(p => p.situacao === 'ativo').length,
    clientes: cli.count || 0,
    publicacoesNovas: pub.count || 0,
    sugestoesPendentes: (sug.data || []).length,
    sugestoesSuspensao: (sug.data || []).filter(s => s.tipo === 'suspensao').length,
    sugestoesAudiencia: (sug.data || []).filter(s => s.tipo === 'audiencia').length,
    processosNovos: desc.count || 0,
  }
}

// ---------- Suspensões de prazo ----------
// Suspensões que tocam o período [inicio, fim] (datas AAAA-MM-DD)
export async function listarSuspensoes(inicio, fim) {
  return ok(await sb.from('suspensoes').select('*')
    .lte('data_inicio', fim).gte('data_fim', inicio).order('data_inicio'))
}
export async function salvarSuspensao(s) {
  const campos = {
    abrangencia: s.abrangencia, tribunal: s.abrangencia === 'nacional' ? null : s.tribunal,
    comarca: ['comarca', 'orgao'].includes(s.abrangencia) ? s.comarca : null,
    orgao: s.abrangencia === 'orgao' ? s.orgao : null,
    data_inicio: s.data_inicio, data_fim: s.data_fim || s.data_inicio, hora_inicio: s.hora_inicio || null,
    tipo: s.tipo, motivo: s.motivo, numero_ato: s.numero_ato || null, link_ato: s.link_ato || null,
    instancia: s.instancia || 'todas',
  }
  if (!s.id && s.tribunais?.length > 1) {
    return ok(await sb.from('suspensoes').insert(s.tribunais.map(t => ({ ...campos, tribunal: t }))).select())
  }
  return s.id
    ? ok(await sb.from('suspensoes').update(campos).eq('id', s.id).select().single())
    : ok(await sb.from('suspensoes').insert(campos).select().single())
}
export async function excluirSuspensao(id) { ok(await sb.from('suspensoes').delete().eq('id', id)) }

export async function sugestoesSuspensao() {
  return ok(await sb.from('sugestoes').select('*').eq('tipo', 'suspensao').eq('status', 'pendente').order('criado_em'))
}
export async function confirmarSugestaoSuspensao(id, ajustes) {
  return ok(await sb.rpc('confirmar_sugestao_suspensao', { p_sugestao: id, p_dados: ajustes || null }))
}
export async function rejeitarSugestao(id) {
  ok(await sb.from('sugestoes').update({ status: 'rejeitada', decidido_por: await uid(), decidido_em: new Date().toISOString() }).eq('id', id))
}
export async function tribunaisEmUso() { return ok(await sb.rpc('tribunais_em_uso')) }

// Prazos em aberto que uma suspensão pode alterar (só os do advogado logado)
export async function prazosAfetados(s) {
  let q = sb.from('vw_prazos').select('id,processo_id,tipo,prazo_fatal,numero_cnj,cliente,tribunal,comarca')
    .eq('status', 'aberto').gte('prazo_fatal', s.data_inicio)
  if (s.abrangencia !== 'nacional') q = q.eq('tribunal', s.tribunal)
  if (['comarca', 'orgao'].includes(s.abrangencia)) q = q.ilike('comarca', s.comarca)
  return ok(await q.order('prazo_fatal'))
}

export async function listarFontes() { return ok(await sb.from('fontes_atos').select('*').order('tribunal')) }
export async function salvarFonte(f) {
  return ok(await sb.from('fontes_atos').upsert({ tribunal: f.tribunal.toUpperCase(), url: f.url || null, ativo: f.ativo ?? true }).select().single())
}

// ---------- Funções no servidor (Edge Functions) ----------
async function invocar(nome, corpo, opcoes = {}) {
  const { data, error } = await sb.functions.invoke(nome, { body: corpo, ...opcoes })
  if (error) {
    let msg = error.message
    try { const c = await error.context.json(); if (c?.erro) msg = c.erro } catch { /* sem corpo */ }
    if (/Failed to send a request/i.test(msg))
      msg = `Não foi possível falar com a função "${nome}" no Supabase. Confira se ela foi publicada com esse nome e se a opção "Enforce JWT verification" está desligada.`
    throw new Error(msg)
  }
  return data
}

// ---------- Administração de usuários ----------
const admin = (acao, dados = {}) => invocar('admin-usuarios', { acao, ...dados })
export const adminListar = async () => (await admin('listar')).usuarios
export const adminCriar = d => admin('criar', d)
export const adminAtivar = (id, ativo) => admin(ativo ? 'reativar' : 'desativar', { id })
export const adminTornarAdmin = (id, valor) => admin('papel', { id, papel: valor ? 'admin' : 'advogado' })
export const adminPapel = (id, papel) => admin('papel', { id, papel })
export const adminVisaoGeral = (id, visao_geral) => admin('visao', { id, visao_geral })
// Escritórios (só o dono da plataforma)
export async function listarEscritorios() { return ok(await sb.rpc('listar_escritorios')) }
export const criarEscritorio = d => admin('escritorio_criar', d)
export const ativarEscritorio = (id, ativo) => admin('escritorio_ativar', { escritorio_id: id, ativo })
export const adminRedefinirSenha = id => admin('redefinir_senha', { id })
export const adminExcluir = id => admin('excluir', { id })
export const adminPreviaSaida = (id, escritorio_id) => admin('previa_saida', { id, escritorio_id })
export const adminRemover = (id, d) => admin('remover', { id, ...d })
// Dono da plataforma: membros e advogados entre escritórios
export const membrosEscritorio = async id => (await admin('membros_listar', { escritorio_id: id })).membros
export const incluirExistente = d => admin('incluir', d)
export const remanejarAdvogado = d => admin('remanejar', d)
export const criarAutonomo = d => admin('autonomo_criar', d)
export const plataformaListar = async () => (await admin('plataforma_listar')).usuarios
export const plataformaAtivar = (id, ativo) => admin('plataforma_ativar', { id, ativo })
export const plataformaExcluir = id => admin('plataforma_excluir', { id })

// ---------- DataJud ----------
// ---------- Processos novos identificados (descoberta diária) ----------
export async function listarDescobertas({ historico = false } = {}) {
  let q = sb.from('vw_descobertas').select('*')
  if (!historico) q = q.eq('meu', true).eq('status', 'pendente')
  return ok(await q.order('notificado_em', { ascending: false }).limit(historico ? 300 : 100))
}
export async function decidirDescoberta(avisoId, status) { ok(await sb.rpc('decidir_descoberta', { p_aviso: avisoId, p_status: status })) }

// ---------- Notificações ----------
export const pushChavePublica = async () => (await invocar('datajud-sync', { acao: 'push_chave' })).publica
export async function salvarInscricaoPush(sub, aparelho) {
  const linha = { endpoint: sub.endpoint, p256dh: sub.keys.p256dh, auth: sub.keys.auth, aparelho }
  const { data: atual } = await sb.from('push_inscricoes').select('id').eq('endpoint', sub.endpoint).maybeSingle()
  if (atual) ok(await sb.from('push_inscricoes').update(linha).eq('id', atual.id))
  else ok(await sb.from('push_inscricoes').insert(linha))
}
export async function removerInscricaoPush(endpoint) { ok(await sb.from('push_inscricoes').delete().eq('endpoint', endpoint)) }
export async function meusAparelhos() { return ok(await sb.from('push_inscricoes').select('id,aparelho,criado_em,ultimo_envio,falhas').order('criado_em')) }
export const pushTeste = () => invocar('datajud-sync', { acao: 'push_teste' })

// Região de São Paulo: o DJEN só aceita conexões vindas do Brasil
export const pesquisarDJEN = filtro => invocar('datajud-sync', { acao: 'pesquisa', ...filtro }, { region: 'sa-east-1' })
export const atualizarDataJud = processoId => invocar('datajud-sync', { acao: 'processo', processo_id: processoId }, { region: 'sa-east-1' })
export async function marcarVistas(processoId) { return ok(await sb.rpc('marcar_movimentacoes_vistas', { p_processo: processoId })) }
export async function saudeConsultas() {
  return ok(await sb.from('sincronizacoes').select('*').order('iniciada_em', { ascending: false }).limit(30))
}

// ---------- Audiências ----------
export async function listarAudiencias(f = {}) {
  let q = sb.from('vw_audiencias').select('*')
  if (f.processo_id) q = q.eq('processo_id', f.processo_id)
  if (f.de) q = q.gte('data_hora', f.de)
  if (f.ate) q = q.lte('data_hora', f.ate)
  if (f.status) q = q.eq('status', f.status)
  return ok(await q.order('data_hora', { ascending: !f.decrescente }).limit(f.limite || 500))
}
export async function salvarAudiencia(a) {
  const campos = {
    processo_id: a.processo_id, tipo: a.tipo, data_hora: a.data_hora, modalidade: a.modalidade,
    local: a.local || null, link: a.link || null, status: a.status || 'agendada',
    resultado: a.resultado || null, observacoes: a.observacoes || null, sugestao_id: a.sugestao_id || null,
  }
  return a.id
    ? ok(await sb.from('audiencias').update(campos).eq('id', a.id).select().single())
    : ok(await sb.from('audiencias').insert(campos).select().single())
}
export async function excluirAudiencia(id) { ok(await sb.from('audiencias').delete().eq('id', id)) }
export async function sugestoesAudiencia() {
  const sug = ok(await sb.from('sugestoes').select('*').eq('tipo', 'audiencia').eq('status', 'pendente').order('criado_em'))
  if (!sug.length) return []
  const procs = ok(await sb.from('vw_processos').select('id,numero_cnj,cliente_nome,polo,tribunal,orgao_julgador').in('id', sug.map(s => s.processo_id)))
  return sug.map(s => ({ ...s, processo: procs.find(p => p.id === s.processo_id) })).filter(s => s.processo)
}
export async function aceitarSugestaoAudiencia(sg, audiencia) {
  const salva = await salvarAudiencia({ ...audiencia, processo_id: sg.processo_id, sugestao_id: sg.id })
  ok(await sb.from('sugestoes').update({ status: 'aceita', decidido_por: await uid(), decidido_em: new Date().toISOString() }).eq('id', sg.id))
  return salva
}

// ---------- Prazos ----------
export async function listarPrazos(f = {}) {
  let q = sb.from('vw_prazos').select('*')
  if (f.processo_id) q = q.eq('processo_id', f.processo_id)
  if (f.status) q = q.eq('status', f.status)
  return ok(await q.order('prazo_fatal', { ascending: true }).limit(f.limite || 1000))
}
export async function salvarPrazo(z) {
  const campos = {
    processo_id: z.processo_id, tipo: z.tipo, data_recebimento: z.data_recebimento,
    origem_contagem: z.origem_contagem || 'intimacao', calculo_auto: z.calculo_auto !== false,
    dias: z.dias ? Number(z.dias) : null, contagem: z.contagem || 'uteis',
    prazo_fatal: z.calculo_auto !== false ? null : z.prazo_fatal,
    data_elaboracao: z.data_elaboracao || null, responsavel_id: z.responsavel_id || null,
    observacoes: z.observacoes || null, status: z.status || 'aberto',
    data_cumprimento: z.status === 'cumprido' ? z.data_cumprimento : null,
    audiencia_id: z.audiencia_id || null,
  }
  if (!z.id && z.publicacao_id) campos.publicacao_id = z.publicacao_id
  return z.id
    ? ok(await sb.from('prazos').update(campos).eq('id', z.id).select().single())
    : ok(await sb.from('prazos').insert(campos).select().single())
}
export async function cumprirPrazo(id, data, obs = null) {
  ok(await sb.rpc('cumprir_prazo', { p_id: id, p_data: data, p_obs: obs }))
}
export async function historicoPrazo(id) {
  return ok(await sb.from('vw_prazo_historico').select('*').eq('prazo_id', id).order('em'))
}
export async function observarPrazo(id, texto) { ok(await sb.rpc('observar_prazo', { p_id: id, p_texto: texto })) }
export async function reabrirPrazo(id) {
  return ok(await sb.from('prazos').update({ status: 'aberto', data_cumprimento: null, cumprido_por: null, cumprimento_obs: null }).eq('id', id).select().single())
}
export async function excluirPrazo(id) { ok(await sb.from('prazos').delete().eq('id', id)) }

// ---------- Notificações pessoais ----------
export const PREFS_PADRAO = { prazos: true, prazos_hora: 7, prazos_dias: 1, prazos_elaborar: true, audiencias: true, aud_vespera_hora: 18,
  aud_horas_antes: 2, publicacoes: true, novos: true, sugestoes: true, sugestoes_hora: 8, escopo: 'meus' }
export async function minhasPreferencias() {
  const p = ok(await sb.from('notif_preferencias').select('*').maybeSingle())
  return { ...PREFS_PADRAO, ...(p || {}) }
}
export async function salvarPreferencias(p) {
  const id = await uid()
  const { advogado_id, atualizado_em, ...resto } = p
  return ok(await sb.from('notif_preferencias').upsert({ ...resto, advogado_id: id, atualizado_em: new Date().toISOString() }).select().single())
}
export async function listarNotificacoes() {
  return ok(await sb.from('notificacoes').select('*').order('criado_em', { ascending: false }).limit(150))
}
export async function contarNaoLidas() {
  const { count, error } = await sb.from('notificacoes').select('id', { count: 'exact', head: true }).is('lida_em', null)
  if (error) return 0
  return count || 0
}
export async function marcarNotificacoesLidas(ids = null) { return ok(await sb.rpc('marcar_notificacoes_lidas', { p_ids: ids })) }
