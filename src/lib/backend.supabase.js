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
  return ok(await sb.from('advogados').select('*').eq('id', id).maybeSingle())
}
export async function salvarPerfil({ nome, oab_numero, oab_uf }) {
  const id = await uid()
  const { data: { user } } = await sb.auth.getUser()
  const perfil = ok(await sb.from('advogados')
    .upsert({ id, nome, oab_numero, oab_uf, email: user.email }).select().single())
  // Monitorar as publicações da própria OAB no DJEN
  const existente = ok(await sb.from('monitoramentos').select('id')
    .eq('advogado_id', id).eq('tipo', 'oab').maybeSingle())
  if (existente) ok(await sb.from('monitoramentos').update({ valor: oab_numero, uf: oab_uf, ativo: true }).eq('id', existente.id))
  else ok(await sb.from('monitoramentos').insert({ advogado_id: id, tipo: 'oab', valor: oab_numero, uf: oab_uf }))
  return perfil
}
export async function listarAdvogados() {
  return ok(await sb.from('advogados').select('id,nome,oab_numero,oab_uf').order('nome'))
}

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
    observacoes: c.observacoes || null,
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
  if (filtro.cliente_id) q = q.eq('cliente_id', filtro.cliente_id)
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
    tipo_acao: p.tipo_acao || null, valor_causa: p.valor_causa ?? null,
    situacao: p.situacao || 'ativo', data_distribuicao: p.data_distribuicao || null,
    observacoes: p.observacoes || null,
  }
  const salvo = p.id
    ? ok(await sb.from('processos').update(campos).eq('id', p.id).select().single())
    : ok(await sb.from('processos').insert(campos).select().single())
  for (const advId of colegas) await incluirColega(salvo.id, advId)
  return salvo
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
  return ok(await sb.from('vw_linha_do_tempo').select('*').eq('processo_id', processoId)
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
  const [proc, cli, pub, sug] = await Promise.all([
    sb.from('processos').select('situacao'),
    sb.from('clientes').select('id', { count: 'exact', head: true }),
    sb.from('publicacoes').select('id', { count: 'exact', head: true }).eq('status', 'nova'),
    sb.from('sugestoes').select('id', { count: 'exact', head: true }).eq('status', 'pendente'),
  ])
  const ps = ok(proc)
  return {
    processos: ps.length,
    ativos: ps.filter(p => p.situacao === 'ativo').length,
    clientes: cli.count || 0,
    publicacoesNovas: pub.count || 0,
    sugestoesPendentes: sug.count || 0,
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
async function invocar(nome, corpo) {
  const { data, error } = await sb.functions.invoke(nome, { body: corpo })
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
export const adminTornarAdmin = (id, valor) => admin('admin', { id, admin: valor })
export const adminRedefinirSenha = id => admin('redefinir_senha', { id })
export const adminExcluir = id => admin('excluir', { id })

// ---------- DataJud ----------
export const atualizarDataJud = processoId => invocar('datajud-sync', { acao: 'processo', processo_id: processoId })
export async function marcarVistas(processoId) { return ok(await sb.rpc('marcar_movimentacoes_vistas', { p_processo: processoId })) }
export async function saudeConsultas() {
  return ok(await sb.from('sincronizacoes').select('*').order('iniciada_em', { ascending: false }).limit(30))
}
