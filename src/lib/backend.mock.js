// Backend de DEMONSTRAÇÃO (só no modo "mock"): dados fictícios na memória do navegador.
// Imita as regras de sigilo do banco para os testes de tela.
import { digitoCNJ } from './cnj.js'

const EU = 'u-wilquer', COLEGA = 'u-colega'
const atraso = (ms = 120) => new Promise(r => setTimeout(r, ms))
const novoId = () => Math.random().toString(36).slice(2, 10)
const agora = () => new Date().toISOString()

function cnj(seq, ano, j, tr, orgao) {
  const base = String(seq).padStart(7, '0') + '00' + ano + j + tr + orgao
  const dv = digitoCNJ(base)
  return `${base.slice(0, 7)}-${dv}.${ano}.${j}.${tr}.${orgao}`
}

function semente() {
  const advogados = [
    { id: EU, nome: 'Wilquer Bosque', oab_numero: '00000', oab_uf: 'BA', email: 'wilquer@exemplo.com', admin: true, ativo: true, trocar_senha: false, ultimo_acesso: new Date().toISOString() },
    { id: COLEGA, nome: 'Colega do Escritório', oab_numero: '11111', oab_uf: 'BA', email: 'colega@exemplo.com', admin: false, ativo: true, trocar_senha: false, ultimo_acesso: new Date(Date.now() - 86400000 * 2).toISOString() },
  ]
  const clientes = [
    { id: 'c1', tipo: 'PJ', nome: 'Marques Turismo Ltda', nome_fantasia: 'Marques Turismo', cpf_cnpj: '11.222.333/0001-81', email: 'juridico@marques.exemplo', telefone: '(71) 3333-0000' },
    { id: 'c2', tipo: 'PJ', nome: 'Bahia Tech Notebooks Ltda', nome_fantasia: 'Bahia Tech', cpf_cnpj: '', email: '', telefone: '' },
    { id: 'c3', tipo: 'PJ', nome: 'Turminha da Marina Ltda', nome_fantasia: 'Turminha da Marina', cpf_cnpj: '', email: '', telefone: '' },
    { id: 'c4', tipo: 'PF', nome: 'Maria das Graças Souza', nome_fantasia: null, cpf_cnpj: '529.982.247-25', email: '', telefone: '(71) 99999-0000' },
    { id: 'c9', tipo: 'PF', nome: 'Cliente Sigiloso da Colega', cpf_cnpj: '' },
  ].map(c => ({ observacoes: null, criado_por: c.id === 'c9' ? COLEGA : EU, criado_em: agora(), atualizado_em: agora(), ...c }))
  const cliente_advogados = [
    ['c1', EU], ['c2', EU], ['c3', EU], ['c4', EU], ['c9', COLEGA], ['c1', COLEGA],
  ].map(([cliente_id, advogado_id]) => ({ cliente_id, advogado_id }))
  const P = (id, seq, j, tr, org, cliente_id, polo, contraria, orgao, tipo_acao, valor, situacao = 'ativo') => ({
    id, numero_cnj: cnj(seq, '2026', j, tr, org), cliente_id, polo, parte_contraria: contraria, tribunal: '',
    orgao_julgador: orgao, classe: polo === 'reu' ? 'Procedimento do Juizado Especial Cível' : 'Procedimento Comum Cível',
    tipo_acao, valor_causa: valor, situacao, data_distribuicao: '2026-0' + (1 + (seq % 9)) + '-1' + (seq % 9),
    comarca: org === '0080' ? 'Feira de Santana' : 'Salvador', observacoes: null, criado_por: EU, criado_em: agora(), atualizado_em: agora(), datajud_sync_em: null,
  })
  const processos = [
    P('p1', 8001234, '8', '05', '0001', 'c1', 'reu', 'João Pereira da Silva', '5ª Vara do Sistema dos Juizados Especiais do Consumidor de Salvador', 'Consumidor', 12000),
    P('p2', 8004321, '8', '05', '0001', 'c1', 'reu', 'Ana Beatriz Lima', '12ª Vara do Sistema dos Juizados Especiais do Consumidor de Salvador', 'Consumidor', 8500),
    P('p3', 8007777, '8', '05', '0080', 'c1', 'reu', 'Carlos Henrique Santos', '1ª Vara do Juizado Especial Cível de Feira de Santana', 'Consumidor', 15000),
    P('p4', 315, '5', '05', '0004', 'c2', 'reu', 'Pedro Alves Nunes', '4ª Vara do Trabalho de Salvador', 'Trabalhista', 42000),
    P('p5', 8009999, '8', '05', '0001', 'c3', 'autor', 'Construtora Exemplo Ltda', '3ª Vara Cível de Salvador', 'Cível', 60000),
    P('p6', 8005555, '8', '05', '0001', 'c4', 'autor', 'Banco Exemplo S.A.', '7ª Vara de Relações de Consumo de Salvador', 'Consumidor', 20000, 'arquivado'),
    { ...P('p9', 8000001, '8', '05', '0001', 'c9', 'autor', 'Parte X', 'Vara X', 'Cível', 1000), criado_por: COLEGA },
  ]
  processos.forEach(p => { p.tribunal = p.numero_cnj.includes('.5.05.') ? 'TRT5' : 'TJBA' })
  const processo_advogados = [
    ['p1', EU], ['p2', EU], ['p3', EU], ['p4', EU], ['p5', EU], ['p6', EU], ['p3', COLEGA], ['p9', COLEGA],
  ].map(([processo_id, advogado_id]) => ({ processo_id, advogado_id }))
  const dia = n => { const d = new Date(); d.setDate(d.getDate() + n); return d.toLocaleDateString('en-CA') }
  const prazos = [
    { id: 'z1', processo_id: 'p1', tipo: 'Contestação', data_recebimento: dia(-14), data_elaboracao: dia(-1), prazo_fatal: dia(0), status: 'aberto', responsavel_id: EU },
    { id: 'z2', processo_id: 'p4', tipo: 'Manifestação sobre laudo pericial', data_recebimento: dia(-5), data_elaboracao: dia(0), prazo_fatal: dia(3), status: 'aberto', responsavel_id: EU },
    { id: 'z3', processo_id: 'p2', tipo: 'Réplica', data_recebimento: dia(-16), data_elaboracao: dia(-3), prazo_fatal: dia(-1), status: 'aberto', responsavel_id: EU },
    { id: 'z4', processo_id: 'p3', tipo: 'Recurso Inominado', data_recebimento: dia(-2), data_elaboracao: dia(5), prazo_fatal: dia(8), status: 'aberto', responsavel_id: COLEGA },
    { id: 'z5', processo_id: 'p9', tipo: 'Prazo sigiloso da colega', data_recebimento: dia(-2), data_elaboracao: dia(0), prazo_fatal: dia(0), status: 'aberto', responsavel_id: COLEGA },
  ]
  const monitoramentos = [
    { id: 'm1', advogado_id: EU, tipo: 'nome_parte', valor: 'MARQUES TURISMO', cliente_id: 'c1', ativo: true, criado_em: agora() },
  ]
  return { advogados, clientes, cliente_advogados, processos, processo_advogados, monitoramentos, prazos, sessao: null }
}

let db
try { db = JSON.parse(localStorage.getItem('mockdb5')) } catch { db = null }
if (!db) db = semente()
const gravar = () => { try { localStorage.setItem('mockdb5', JSON.stringify(db)) } catch { /* sem storage */ } }

const ouvintes = new Set()
const me = () => db.sessao?.user?.id
const podeVerProcesso = id => db.processo_advogados.some(x => x.processo_id === id && x.advogado_id === me())
const podeVerCliente = id => db.cliente_advogados.some(x => x.cliente_id === id && x.advogado_id === me())

function vwProcesso(p) {
  const c = db.clientes.find(c => c.id === p.cliente_id)
  return {
    ...p, cliente_nome: c?.nome, cliente_tipo: c?.tipo,
    advogados: db.processo_advogados.filter(x => x.processo_id === p.id)
      .map(x => db.advogados.find(a => a.id === x.advogado_id)).map(a => ({ id: a.id, nome: a.nome })),
    prazos_abertos: db.prazos.filter(z => z.processo_id === p.id && z.status === 'aberto').length,
    proximo_prazo: db.prazos.filter(z => z.processo_id === p.id && z.status === 'aberto').map(z => z.prazo_fatal).sort()[0] || null, novidades: p.id === 'p1' ? 2 : 0,
  }
}
function vwCliente(c) {
  const ps = db.processos.filter(p => p.cliente_id === c.id && podeVerProcesso(p.id))
  return { ...c, qtd_processos: ps.length, qtd_ativos: ps.filter(p => p.situacao === 'ativo').length,
    monitorado: db.monitoramentos.some(m => m.cliente_id === c.id && m.advogado_id === me() && m.ativo) }
}

export async function sessaoAtual() { await atraso(30); return db.sessao }
export function aoMudarSessao(cb) { ouvintes.add(cb); return () => ouvintes.delete(cb) }
export async function entrar(email, senha) {
  await atraso(300)
  if (!email || !senha) throw new Error('E-mail ou senha incorretos.')
  const achado = db.advogados.find(a => a.email === email)
  const id = achado ? achado.id : email.startsWith('colega') ? COLEGA : EU
  db.sessao = { user: { id, email } }; gravar(); ouvintes.forEach(f => f(db.sessao))
}
export async function sair() { db.sessao = null; gravar(); ouvintes.forEach(f => f(null)) }
export async function recuperarSenha() { await atraso() }
export async function trocarSenha() { await atraso(); const a = db.advogados.find(a => a.id === me()); if (a) a.trocar_senha = false; gravar() }

export async function meuPerfil() { await atraso(); const a = db.advogados.find(a => a.id === me()); return a ? { ...a } : null }
export async function salvarPerfil(p) {
  await atraso()
  const i = db.advogados.findIndex(a => a.id === me())
  const novo = { ...(db.advogados[i] || {}), ...p, id: me(), email: db.sessao.user.email }
  if (i >= 0) db.advogados[i] = novo; else db.advogados.push(novo)
  gravar(); return novo
}
export async function listarAdvogados() { await atraso(); return [...db.advogados].sort((a, b) => a.nome.localeCompare(b.nome)) }

export async function listarClientes() {
  await atraso(); return db.clientes.filter(c => podeVerCliente(c.id)).map(vwCliente).sort((a, b) => a.nome.localeCompare(b.nome))
}
export async function obterCliente(id) { await atraso(); return podeVerCliente(id) ? vwCliente(db.clientes.find(c => c.id === id)) : null }
export async function termosDoCliente(cid) {
  await atraso(); return db.monitoramentos.filter(m => m.cliente_id === cid && m.advogado_id === me() && m.tipo === 'nome_parte')
}
export async function salvarCliente(c, termos) {
  await atraso(250)
  let salvo
  if (c.id) {
    const i = db.clientes.findIndex(x => x.id === c.id)
    salvo = db.clientes[i] = { ...db.clientes[i], ...c, atualizado_em: agora() }
  } else {
    salvo = { ...c, id: novoId(), criado_por: me(), criado_em: agora(), atualizado_em: agora() }
    db.clientes.push(salvo); db.cliente_advogados.push({ cliente_id: salvo.id, advogado_id: me() })
  }
  if (termos) {
    db.monitoramentos = db.monitoramentos.filter(m => !(m.cliente_id === salvo.id && m.advogado_id === me()))
    ;[...new Set(termos.map(t => t.trim().toUpperCase()).filter(Boolean))].forEach(valor =>
      db.monitoramentos.push({ id: novoId(), advogado_id: me(), tipo: 'nome_parte', valor, cliente_id: salvo.id, ativo: true }))
  }
  gravar(); return salvo
}
export async function excluirCliente(id) {
  await atraso()
  if (db.processos.some(p => p.cliente_id === id)) throw new Error('Este cliente tem processos cadastrados. Exclua ou transfira os processos antes.')
  db.clientes = db.clientes.filter(c => c.id !== id); gravar()
}

export async function listarProcessos(f = {}) {
  await atraso()
  return db.processos.filter(p => podeVerProcesso(p.id) && (!f.cliente_id || p.cliente_id === f.cliente_id))
    .map(vwProcesso).sort((a, b) => b.atualizado_em.localeCompare(a.atualizado_em))
}
export async function obterProcesso(id) { await atraso(); return podeVerProcesso(id) ? vwProcesso(db.processos.find(p => p.id === id)) : null }
export async function processoPorNumero(n) {
  await atraso(60); const p = db.processos.find(p => p.numero_cnj === n && podeVerProcesso(p.id)); return p ? { id: p.id, numero_cnj: p.numero_cnj } : null
}
export async function salvarProcesso(p, colegas = []) {
  await atraso(250)
  let salvo
  if (p.id) {
    const i = db.processos.findIndex(x => x.id === p.id)
    salvo = db.processos[i] = { ...db.processos[i], ...p, atualizado_em: agora() }
  } else {
    if (db.processos.some(x => x.numero_cnj === p.numero_cnj))
      throw new Error('Este número já está cadastrado no escritório por outro advogado. Peça para incluírem você no processo.')
    salvo = { ...p, id: novoId(), criado_por: me(), criado_em: agora(), atualizado_em: agora() }
    db.processos.push(salvo); db.processo_advogados.push({ processo_id: salvo.id, advogado_id: me() })
  }
  for (const a of colegas) await incluirColega(salvo.id, a)
  gravar(); return salvo
}
export async function excluirProcesso(id) { await atraso(); db.processos = db.processos.filter(p => p.id !== id); gravar() }
export async function incluirColega(pid, aid) {
  if (!db.processo_advogados.some(x => x.processo_id === pid && x.advogado_id === aid)) {
    db.processo_advogados.push({ processo_id: pid, advogado_id: aid })
    const cid = db.processos.find(p => p.id === pid).cliente_id
    if (!db.cliente_advogados.some(x => x.cliente_id === cid && x.advogado_id === aid)) db.cliente_advogados.push({ cliente_id: cid, advogado_id: aid })
  }
  gravar()
}
export async function removerAdvogado(pid, aid) {
  await atraso(); db.processo_advogados = db.processo_advogados.filter(x => !(x.processo_id === pid && x.advogado_id === aid)); gravar()
}

export async function linhaDoTempo(pid) {
  await atraso()
  if (pid !== 'p1') return []
  return [
    { origem: 'publicacao', item_id: 'x1', quando: '2026-11-10T00:00:00-03:00', titulo: 'Intimação · Despacho', detalhe: 'Intime-se a parte ré para, no prazo de 15 (quinze) dias, apresentar contestação...', nova: true, anotacoes: [] },
    { origem: 'movimentacao', item_id: 'x2', quando: '2026-11-07T14:12:00-03:00', titulo: 'Expedição de documento', detalhe: 'Intimação', nova: true, anotacoes: [] },
    { origem: 'movimentacao', item_id: 'x3', quando: '2026-10-20T09:30:00-03:00', titulo: 'Distribuição', detalhe: 'Sorteio', nova: false,
      anotacoes: [{ tipo: 'observacao', texto: 'Cliente informou que houve tentativa de acordo pelo WhatsApp.', em: '2026-10-21T10:00:00-03:00' }] },
  ]
}

export function hojeSP() { return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo' }).format(new Date()) }
export async function prazosDoDia() {
  await atraso()
  const hoje = hojeSP()
  return db.prazos.filter(z => z.status === 'aberto' && podeVerProcesso(z.processo_id) && (z.prazo_fatal <= hoje || z.data_elaboracao === hoje))
    .map(z => { const p = db.processos.find(p => p.id === z.processo_id); const c = db.clientes.find(c => c.id === p.cliente_id)
      return { ...z, numero_cnj: p.numero_cnj, cliente: c.nome, polo: p.polo, tribunal: p.tribunal } })
    .sort((a, b) => a.prazo_fatal.localeCompare(b.prazo_fatal))
}

export async function resumo() {
  await atraso()
  const ps = db.processos.filter(p => podeVerProcesso(p.id))
  return { processos: ps.length, ativos: ps.filter(p => p.situacao === 'ativo').length,
    clientes: db.clientes.filter(c => podeVerCliente(c.id)).length, publicacoesNovas: 1, sugestoesPendentes: db.sugestoes.filter(s => s.status === 'pendente').length }
}

// ---------- Suspensões (demonstração) ----------
function semearSuspensoes() {
  const ano = new Date().getFullYear()
  const r = (d, m) => ({ id: 's' + d + m, abrangencia: 'nacional', tribunal: null, comarca: null, orgao: null, data_inicio: d, data_fim: d, hora_inicio: null, tipo: 'feriado', motivo: m, numero_ato: 'Lei 662/1949', link_ato: null, fonte: 'regra' })
  const mes = String(new Date().getMonth() + 1).padStart(2, '0')
  const dmes = d => `${ano}-${mes}-${String(d).padStart(2, '0')}`
  const daqui = n => { const x = new Date(); x.setDate(x.getDate() + n); return x.toLocaleDateString('en-CA') }
  db.suspensoes = [
    r(`${ano}-11-02`, 'Finados'), r(`${ano}-11-15`, 'Proclamação da República'),
    { ...r(`${ano}-11-20`, 'Dia Nacional de Zumbi e da Consciência Negra'), numero_ato: 'Lei 14.759/2023' }, r(`${ano}-12-25`, 'Natal'),
    { ...r(`${ano}-12-20`, 'Suspensão de prazos de fim de ano'), data_fim: `${ano + 1}-01-20`, tipo: 'recesso', numero_ato: 'CPC, art. 220' },
    { id: 'sm1', abrangencia: 'tribunal', tribunal: 'TJBA', comarca: null, orgao: null, data_inicio: dmes(9), data_fim: dmes(10), hora_inicio: null, tipo: 'indisponibilidade', motivo: 'Indisponibilidade do PJe para atualização de versão', numero_ato: 'Ato Normativo Conjunto nº 24/2026', link_ato: 'https://www.tjba.jus.br/', fonte: 'manual' },
    { id: 'sm2', abrangencia: 'comarca', tribunal: 'TJBA', comarca: 'Feira de Santana', orgao: null, data_inicio: dmes(17), data_fim: dmes(17), hora_inicio: '11:00', tipo: 'ato', motivo: 'Suspensão do expediente a partir das 11h', numero_ato: 'Decreto Judiciário nº 1.640/2026', link_ato: null, fonte: 'sugestao' },
    { id: 'sm3', abrangencia: 'tribunal', tribunal: 'TJSP', comarca: null, orgao: null, data_inicio: dmes(24), data_fim: dmes(24), hora_inicio: null, tipo: 'indisponibilidade', motivo: 'Indisponibilidade do e-SAJ', numero_ato: 'Comunicado CG nº 512/2026', link_ato: null, fonte: 'manual' },
  ]
  db.sugestoes = [
    { id: 'sg1', tipo: 'suspensao', status: 'pendente', criado_em: agora(),
      justificativa: 'DECRETO JUDICIÁRIO Nº 1.702, DE 12 DE NOVEMBRO DE 2026. Suspende o expediente forense e os prazos processuais na Comarca de Feira de Santana, em razão de feriado municipal...',
      dados: { abrangencia: 'comarca', tribunal: 'TJBA', comarca: 'Feira de Santana', data_inicio: daqui(5), data_fim: daqui(5), tipo: 'feriado', motivo: 'Feriado municipal em Feira de Santana', numero_ato: 'Decreto Judiciário nº 1.702/2026', link_ato: 'https://www.tjba.jus.br/' } },
    { id: 'sg2', tipo: 'suspensao', status: 'pendente', criado_em: agora(),
      justificativa: 'ATO GP Nº 41/2026. Ficam suspensos os prazos processuais no âmbito do Tribunal Regional do Trabalho da 5ª Região nos dias 3 e 4 de dezembro de 2026, em razão da migração do PJe...',
      dados: { abrangencia: 'tribunal', tribunal: 'TRT5', data_inicio: `${ano}-12-03`, data_fim: `${ano}-12-04`, tipo: 'indisponibilidade', motivo: 'Migração do PJe', numero_ato: 'Ato GP nº 41/2026', link_ato: 'https://www.trt5.jus.br/' } },
  ]
  db.fontes = [
    { tribunal: 'TJBA', url: 'https://www.tjba.jus.br/', ativo: true, ultimo_sucesso: agora(), ultimo_erro: null },
    { tribunal: 'TRT5', url: 'https://www.trt5.jus.br/', ativo: true, ultimo_sucesso: agora(), ultimo_erro: null },
    { tribunal: 'TJSP', url: null, ativo: true, ultimo_sucesso: null, ultimo_erro: null },
  ]
}
if (!db.suspensoes) { semearSuspensoes(); gravar() }

export async function listarSuspensoes(ini, fim) {
  await atraso(); return db.suspensoes.filter(s => s.data_inicio <= fim && s.data_fim >= ini).sort((a, b) => a.data_inicio.localeCompare(b.data_inicio))
}
export async function salvarSuspensao(s) {
  await atraso(200)
  const limpo = { ...s, data_fim: s.data_fim || s.data_inicio, tribunal: s.abrangencia === 'nacional' ? null : s.tribunal,
    comarca: ['comarca', 'orgao'].includes(s.abrangencia) ? s.comarca : null, orgao: s.abrangencia === 'orgao' ? s.orgao : null }
  if (s.id) { const i = db.suspensoes.findIndex(x => x.id === s.id); db.suspensoes[i] = { ...db.suspensoes[i], ...limpo } }
  else db.suspensoes.push({ ...limpo, id: novoId(), fonte: 'manual' })
  gravar(); return limpo
}
export async function excluirSuspensao(id) { await atraso(); db.suspensoes = db.suspensoes.filter(s => s.id !== id || s.fonte === 'regra'); gravar() }
export async function sugestoesSuspensao() { await atraso(); return db.sugestoes.filter(s => s.status === 'pendente') }
export async function confirmarSugestaoSuspensao(id, ajustes) {
  await atraso(200)
  const sg = db.sugestoes.find(s => s.id === id); const d = { ...sg.dados, ...(ajustes || {}) }
  db.suspensoes.push({ ...d, id: novoId(), data_fim: d.data_fim || d.data_inicio, hora_inicio: d.hora_inicio || null, fonte: 'sugestao' })
  sg.status = ajustes ? 'ajustada' : 'aceita'; gravar()
}
export async function rejeitarSugestao(id) { await atraso(); db.sugestoes.find(s => s.id === id).status = 'rejeitada'; gravar() }
export async function tribunaisEmUso() {
  await atraso(); return [...new Set(db.processos.filter(p => p.situacao === 'ativo').map(p => p.tribunal))].map(t => ({ tribunal: t, comarca: null }))
}
export async function prazosAfetados(s) {
  await atraso()
  return db.prazos.filter(z => z.status === 'aberto' && podeVerProcesso(z.processo_id) && z.prazo_fatal >= s.data_inicio)
    .map(z => { const p = db.processos.find(p => p.id === z.processo_id); return { ...z, numero_cnj: p.numero_cnj, tribunal: p.tribunal, comarca: p.comarca || null, cliente: db.clientes.find(c => c.id === p.cliente_id).nome } })
    .filter(z => s.abrangencia === 'nacional' || (z.tribunal === s.tribunal && (!['comarca', 'orgao'].includes(s.abrangencia) || (z.comarca || '').toLowerCase() === (s.comarca || '').toLowerCase())))
}
export async function listarFontes() { await atraso(); return db.fontes }
export async function salvarFonte(f) {
  await atraso(); const i = db.fontes.findIndex(x => x.tribunal === f.tribunal)
  if (i >= 0) db.fontes[i] = { ...db.fontes[i], ...f }; else db.fontes.push({ ...f, ativo: true }); gravar(); return f
}

// ---------- Administração (demonstração) ----------
const senhaDemo = () => Math.random().toString(36).slice(2, 8) + 'Xy9' + Math.random().toString(36).slice(2, 5)
export async function adminListar() {
  await atraso(); return db.advogados.map(a => ({ ...a, sem_perfil: false })).sort((a, b) => a.nome.localeCompare(b.nome))
}
export async function adminCriar(d) {
  await atraso(300)
  if (db.advogados.some(a => a.email === d.email)) throw new Error('Já existe um usuário com este e-mail.')
  const id = novoId(); const senha = senhaDemo()
  db.advogados.push({ id, nome: d.nome, email: d.email, oab_numero: d.oab_numero, oab_uf: d.oab_uf, admin: Boolean(d.admin), ativo: true, trocar_senha: true, ultimo_acesso: null })
  gravar(); return { id, senha_temporaria: senha }
}
export async function adminAtivar(id, ativo) {
  await atraso(); if (id === me()) throw new Error('Você não pode desativar o seu próprio acesso.')
  db.advogados.find(a => a.id === id).ativo = ativo; gravar()
}
export async function adminTornarAdmin(id, valor) {
  await atraso(); if (!valor && db.advogados.filter(a => a.admin && a.ativo).length <= 1) throw new Error('É preciso manter pelo menos um administrador ativo.')
  db.advogados.find(a => a.id === id).admin = valor; gravar()
}
export async function adminRedefinirSenha(id) { await atraso(); db.advogados.find(a => a.id === id).trocar_senha = true; gravar(); return { senha_temporaria: senhaDemo() } }
export async function adminExcluir(id) {
  await atraso(); if (id === me()) throw new Error('Você não pode excluir o seu próprio usuário.')
  const proc = db.processo_advogados.filter(x => x.advogado_id === id && !db.processo_advogados.some(o => o.processo_id === x.processo_id && o.advogado_id !== id)).length
  const cli = db.cliente_advogados.filter(x => x.advogado_id === id && !db.cliente_advogados.some(o => o.cliente_id === x.cliente_id && o.advogado_id !== id)).length
  if (proc || cli) throw new Error(`Não é possível excluir: há ${proc} processo(s) e ${cli} cliente(s) que só este advogado enxerga. Por sigilo, o sistema não transfere esses dados. Desative o acesso ou peça para ele incluir outro advogado antes.`)
  db.advogados = db.advogados.filter(a => a.id !== id); gravar()
}
