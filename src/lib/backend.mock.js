// Backend de DEMONSTRAÇÃO (só no modo "mock"): dados fictícios na memória do navegador.
// Imita as regras de sigilo do banco para os testes de tela.
import { digitoCNJ } from './cnj.js'
import { ESTADUAIS, TJBA_LINK, TJBA_MUNICIPAIS } from './calendarioLocal.js'
import { calcularPrazo as _calc, inferirRito } from './prazo.js'

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
  processos.forEach(p => { p.tribunal = p.numero_cnj.includes('.5.05.') ? 'TRT5' : 'TJBA'; p.rito = inferirRito(p.tribunal, p.classe, p.orgao_julgador) })
  const processo_advogados = [
    ['p1', EU], ['p2', EU], ['p3', EU], ['p4', EU], ['p5', EU], ['p6', EU], ['p3', COLEGA], ['p9', COLEGA],
  ].map(([processo_id, advogado_id]) => ({ processo_id, advogado_id }))
  const dia = n => { const d = new Date(); d.setDate(d.getDate() + n); return d.toLocaleDateString('en-CA') }
  const prazos = [
    { id: 'z0', processo_id: 'p1', tipo: 'Manifestação sobre documentos', data_recebimento: dia(-20), data_elaboracao: dia(-12), prazo_fatal: dia(-10), status: 'cumprido', data_cumprimento: dia(-11), responsavel_id: EU, calculo_auto: false },
    { id: 'z1', processo_id: 'p1', tipo: 'Contestação', data_recebimento: dia(-14), data_elaboracao: dia(-1), prazo_fatal: dia(0), status: 'aberto', responsavel_id: EU, calculo_auto: false },
    { id: 'z2', processo_id: 'p4', tipo: 'Manifestação sobre laudo pericial', data_recebimento: dia(-5), data_elaboracao: dia(0), prazo_fatal: dia(3), status: 'aberto', responsavel_id: EU, calculo_auto: false },
    { id: 'z3', processo_id: 'p2', tipo: 'Réplica', data_recebimento: dia(-16), data_elaboracao: dia(-3), prazo_fatal: dia(-1), status: 'aberto', responsavel_id: EU, calculo_auto: false },
    { id: 'z4', processo_id: 'p3', tipo: 'Recurso Inominado', data_recebimento: dia(-2), data_elaboracao: dia(5), prazo_fatal: dia(8), status: 'aberto', responsavel_id: COLEGA, calculo_auto: false },
    { id: 'z5', processo_id: 'p9', tipo: 'Prazo sigiloso da colega', data_recebimento: dia(-2), data_elaboracao: dia(0), prazo_fatal: dia(0), status: 'aberto', responsavel_id: COLEGA, calculo_auto: false },
  ]
  const monitoramentos = [
    { id: 'm1', advogado_id: EU, tipo: 'nome_parte', valor: 'MARQUES TURISMO', cliente_id: 'c1', ativo: true, criado_em: agora() },
  ]
  return { advogados, clientes, cliente_advogados, processos, processo_advogados, monitoramentos, prazos, sessao: null }
}

let db
try { db = JSON.parse(localStorage.getItem('mockdb10')) } catch { db = null }
if (!db) db = semente()
const gravar = () => { try { localStorage.setItem('mockdb10', JSON.stringify(db)) } catch { /* sem storage */ } }

const ouvintes = new Set()
const me = () => db.sessao?.user?.id
const visaoGeral = () => Boolean(db.advogados.find(a => a.id === me())?.visao_geral)
const podeVerProcesso = id => visaoGeral() || db.processo_advogados.some(x => x.processo_id === id && x.advogado_id === me())
  || (db.prazos || []).some(z => z.processo_id === id && z.responsavel_id === me())
const podeVerCliente = id => visaoGeral() || db.cliente_advogados.some(x => x.cliente_id === id && x.advogado_id === me())
  || db.processos.some(p => p.cliente_id === id && podeVerProcesso(p.id))

function vwProcesso(p) {
  const c = db.clientes.find(c => c.id === p.cliente_id)
  return {
    ...p, cliente_nome: c?.nome, cliente_tipo: c?.tipo,
    advogados: db.processo_advogados.filter(x => x.processo_id === p.id)
      .map(x => db.advogados.find(a => a.id === x.advogado_id)).map(a => ({ id: a.id, nome: a.nome })),
    prazos_abertos: db.prazos.filter(z => z.processo_id === p.id && z.status === 'aberto').length,
    proximo_prazo: db.prazos.filter(z => z.processo_id === p.id && z.status === 'aberto').map(z => z.prazo_fatal).sort()[0] || null, novidades: p.id === 'p1' && !p._visto ? 2 : 0,
    proxima_audiencia: (db.audiencias || []).filter(a => a.processo_id === p.id && a.status === 'agendada' && a.data_hora >= new Date(Date.now() - 6 * 3600000).toISOString()).map(a => a.data_hora).sort()[0] || null,
    partes: p.partes || [
      { polo: p.polo === 'autor' ? 'ativo' : 'passivo', nome: c?.nome, cliente_id: c?.id },
      ...(p.parte_contraria ? [{ polo: p.polo === 'autor' ? 'passivo' : 'ativo', nome: p.parte_contraria }] : []),
    ],
    baixa_por_nome: p.baixa_por ? db.advogados.find(a => a.id === p.baixa_por)?.nome : null,
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

const oabsDe = id => (db.oabs || []).filter(o => o.advogado_id === id).sort((a, b) => Number(b.principal) - Number(a.principal) || a.uf.localeCompare(b.uf))
function semearOabs() {
  db.oabs = db.advogados.map(a => ({ id: 'o-' + a.id, advogado_id: a.id, numero: a.oab_numero, uf: a.oab_uf, principal: true }))
  db.oabs.push({ id: 'o-se', advogado_id: EU, numero: '12345', uf: 'SE', principal: false })
}
function semearEquipe() {
  if (db.advogados.some(a => a.papel)) return
  db.advogados.forEach(a => { a.papel = a.admin ? 'admin' : 'advogado'; a.visao_geral = false })
  db.advogados.push({ id: 'estag1', nome: 'Ana Estagiária', oab_numero: '12345E', oab_uf: 'BA', email: 'ana@exemplo.com', admin: false, papel: 'estagiario', visao_geral: false, ativo: true, trocar_senha: false, ultimo_acesso: null })
  db.escritorios = [{ id: 'e1', nome: 'Escritório principal', tipo: 'escritorio', ativo: true, criado_em: new Date().toISOString(), usuarios: 3, processos: 6 }]
  gravar()
}
export async function meuPerfil() {
  await atraso(); if (!db.oabs) { semearOabs(); gravar() } semearEquipe()
  const a = db.advogados.find(a => a.id === me())
  return a ? { ...a, advogado_oabs: oabsDe(a.id), escritorios: { nome: db._espaco || 'Escritório principal' }, dono: a.id === EU && !db._semDono,
    atual: { nome: db._espaco || 'Escritório principal', tipo: (db._espaco || '').includes('autônomo') ? 'autonomo' : 'escritorio', papel: db._espaco === 'Paulo Mendes (autônomo)' ? 'observador' : a.papel, observador: db._espaco === 'Paulo Mendes (autônomo)' },
    observador: db._espaco === 'Paulo Mendes (autônomo)',
    espacos: a.id === EU ? [{ id: 'e1', nome: 'Escritório principal', tipo: 'escritorio', papel: 'admin', em_uso: (db._espaco || 'Escritório principal') === 'Escritório principal' },
      { id: 'ea', nome: 'Wilquer Bosque (autônomo)', tipo: 'autonomo', papel: 'admin', em_uso: db._espaco === 'Wilquer Bosque (autônomo)' }] : [{ id: 'e1', nome: 'Escritório principal', tipo: 'escritorio', papel: a.papel, em_uso: true }] } : null
}
export async function trocarEspaco(id) { await atraso(); db._espaco = id === 'ea' ? 'Wilquer Bosque (autônomo)' : id === 'e1' ? 'Escritório principal' : 'Paulo Mendes (autônomo)'; gravar() }
export async function plataformaListar() {
  await atraso(); semearEquipe()
  if (!db._autonomos) { db._autonomos = [{ id: 'aut1', nome: 'Paulo Mendes', email: 'paulo@adv.br', oab_numero: '77777', oab_uf: 'BA', ativo: true, ultimo_acesso: null, autonomo: true,
    espacos: [{ id: 'eaut1', nome: 'Paulo Mendes (autônomo)', tipo: 'autonomo', papel: 'admin', ativo: true, processos: 3 }] }]; gravar() }
  return [...db.advogados.map(a => ({ ...a, autonomo: false, espacos: [{ id: 'e1', nome: 'Escritório principal', tipo: 'escritorio', papel: a.papel, ativo: true, processos: 6 }] })), ...db._autonomos]
}
export async function plataformaAtivar(id, ativo) { await atraso(); const a = (db._autonomos || []).find(x => x.id === id); if (a) a.ativo = ativo; gravar() }
export async function plataformaExcluir(id) { await atraso(); db._autonomos = (db._autonomos || []).filter(x => x.id !== id); gravar() }
export async function adminPreviaSaida(id) {
  await atraso(); const meus = db.processo_advogados.filter(x => x.advogado_id === id).map(x => x.processo_id)
  return { prazos_abertos: db.prazos.filter(z => z.responsavel_id === id && z.status === 'aberto').length, outros_espacos: [],
    processos: db.processos.filter(p => meus.includes(p.id)).map(p => ({ id: p.id, numero_cnj: p.numero_cnj, cliente: db.clientes.find(c => c.id === p.cliente_id)?.nome,
      exclusivo: !db.processo_advogados.some(x => x.processo_id === p.id && x.advogado_id !== id) })) }
}
export async function adminRemover(id, d) {
  await atraso(400)
  if (d.destino === 'excluir_login') db.advogados = db.advogados.filter(a => a.id !== id); else db.advogados.find(a => a.id === id).ativo = false
  if (d.sucessor_id) db.processo_advogados.filter(x => x.advogado_id === id).forEach(x => db.processo_advogados.push({ processo_id: x.processo_id, advogado_id: d.sucessor_id }))
  db.processo_advogados = db.processo_advogados.filter(x => x.advogado_id !== id); gravar(); return { ok: true, login: d.destino === 'excluir_login' ? 'excluido' : 'mantido' }
}
export async function membrosEscritorio() { await atraso(); semearEquipe(); return db.advogados.map(a => ({ ...a })) }
export async function incluirExistente() { await atraso(300) }
export async function remanejarAdvogado() { await atraso(400) }
export async function criarAutonomo() { await atraso(400); return { senha_temporaria: senhaDemo() } }
export async function listarOabs(id) { await atraso(); return id ? oabsDe(id) : db.oabs || [] }
export async function incluirOab(numero, uf, adv) {
  await atraso(200); const id = adv || me(); const n = String(numero).replace(/\D/g, ''); uf = uf.toUpperCase()
  if (!n) throw new Error('Número de OAB inválido.')
  if (db.oabs.some(o => o.numero === n && o.uf === uf)) throw new Error(`A OAB ${n}/${uf} já está cadastrada.`)
  if (db.oabs.some(o => o.advogado_id === id && o.uf === uf)) throw new Error(`Já existe uma OAB de ${uf} neste cadastro.`)
  const o = { id: novoId(), advogado_id: id, numero: n, uf, principal: false }; db.oabs.push(o); gravar(); return o
}
export async function tornarOabPrincipal(oid) {
  await atraso(200); const o = db.oabs.find(x => x.id === oid)
  db.oabs.forEach(x => { if (x.advogado_id === o.advogado_id) x.principal = x.id === oid })
  const a = db.advogados.find(x => x.id === o.advogado_id); a.oab_numero = o.numero; a.oab_uf = o.uf; gravar()
}
export async function removerOab(oid) {
  await atraso(200); const o = db.oabs.find(x => x.id === oid)
  if (o.principal) throw new Error('Esta é a OAB principal. Torne outra OAB principal antes de remover esta.')
  db.oabs = db.oabs.filter(x => x.id !== oid); gravar()
}
export async function salvarPerfil(p) {
  await atraso()
  const i = db.advogados.findIndex(a => a.id === me())
  const novo = { ...(db.advogados[i] || {}), ...p, id: me(), email: db.sessao.user.email }
  if (i >= 0) db.advogados[i] = novo; else db.advogados.push(novo)
  gravar(); return novo
}
export async function listarAdvogados() { await atraso(); semearEquipe(); return [...db.advogados].map(a => ({ ...a, advogado_oabs: oabsDe(a.id) })).sort((a, b) => a.nome.localeCompare(b.nome)) }

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
  return db.processos.filter(p => podeVerProcesso(p.id) && (!f.cliente_id || p.cliente_id === f.cliente_id || (p.partes || []).some(x => x.cliente_id === f.cliente_id)))
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
    salvo = db.processos[i] = { ...db.processos[i], ...p, rito: p.rito || inferirRito(p.tribunal, p.classe, p.orgao_julgador), atualizado_em: agora() }
  } else {
    if (db.processos.some(x => x.numero_cnj === p.numero_cnj))
      throw new Error('Este número já está cadastrado no escritório por outro advogado. Peça para incluírem você no processo.')
    salvo = { ...p, rito: p.rito || inferirRito(p.tribunal, p.classe, p.orgao_julgador), id: novoId(), criado_por: me(), criado_em: agora(), atualizado_em: agora() }
    db.processos.push(salvo); db.processo_advogados.push({ processo_id: salvo.id, advogado_id: me() })
  }
  for (const a of colegas) await incluirColega(salvo.id, a)
  if (p.partes) {
    const c = db.clientes.find(x => x.id === salvo.cliente_id)
    const meu = salvo.polo === 'autor' ? 'ativo' : 'passivo'
    let partes = p.partes.filter(x => x.nome?.trim()).map(x => ({ polo: x.polo, nome: x.nome.trim(), documento: x.documento || null, cliente_id: x.cliente_id || null }))
    if (!partes.some(x => x.cliente_id === salvo.cliente_id)) partes = [{ polo: meu, nome: c?.nome, cliente_id: c?.id }, ...partes]
    salvo.partes = partes
    salvo.parte_contraria = partes.filter(x => x.polo !== meu).map(x => x.nome).join(', ') || null
  }
  gravar(); gerarCalendarioMock(); return salvo
}
export async function darBaixa(pid, d, motivo, obs, cancelar = true) {
  await atraso(200)
  const p = db.processos.find(x => x.id === pid)
  Object.assign(p, { situacao: 'baixado', baixa_data: d, baixa_motivo: motivo, baixa_por: me(), atualizado_em: agora() })
  let n = 0
  if (cancelar) for (const z of db.prazos) if (z.processo_id === pid && z.status === 'aberto') { z.status = 'cancelado'; n++ }
  if (cancelar) for (const a of db.audiencias || []) if (a.processo_id === pid && a.status === "agendada" && a.data_hora > agora()) a.status = "cancelada"
  db.observacoes = [...(db.observacoes || []), { id: novoId(), processo_id: pid, texto: `Baixa do processo em ${d.split('-').reverse().join('/')} · ${motivo}${obs ? '\n' + obs : ''}`, autor_id: me(), criado_em: agora() }]
  gravar(); return n
}
export async function reativarProcesso(pid) {
  await atraso(150)
  Object.assign(db.processos.find(x => x.id === pid), { situacao: 'ativo', baixa_data: null, baixa_motivo: null, baixa_por: null })
  db.observacoes = [...(db.observacoes || []), { id: novoId(), processo_id: pid, texto: 'Processo reativado.', autor_id: me(), criado_em: agora() }]
  gravar()
}
export async function registrarObservacao(pid, texto) {
  await atraso(150)
  const o = { id: novoId(), processo_id: pid, texto: texto.trim(), autor_id: me(), criado_em: agora() }
  db.observacoes = [...(db.observacoes || []), o]; gravar(); return o
}
export async function excluirObservacao(id) { db.observacoes = (db.observacoes || []).filter(o => o.id !== id); gravar() }
export async function listarComarcas(tribunal) { const { comarcasReserva } = await import('./comarcas.js'); return comarcasReserva(tribunal) }
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
  const obs = (db.observacoes || []).filter(o => o.processo_id === pid).map(o => ({ origem: 'observacao', item_id: o.id, quando: o.criado_em, titulo: 'Observação',
    detalhe: o.texto, nova: false, anotacoes: [], extra: { autor_id: o.autor_id, autor_nome: db.advogados.find(a => a.id === o.autor_id)?.nome } }))
  if (pid !== 'p1') return obs.sort((a, b) => b.quando.localeCompare(a.quando))
  return [...obs, 
    { origem: 'publicacao', item_id: 'x1', quando: '2026-11-10T12:00:00-03:00', titulo: 'Despacho', nova: !db._pubLida,
      detalhe: 'PODER JUDICIÁRIO DO ESTADO DA BAHIA\n5ª VARA DO SISTEMA DOS JUIZADOS ESPECIAIS DO CONSUMIDOR\n\nDESPACHO\n\nVistos etc. Considerando a juntada da petição de ID 4512, intime-se a parte ré para, no prazo de 5 (cinco) dias, manifestar-se sobre os documentos apresentados pela parte autora, sob pena de preclusão. Após, voltem-me conclusos para sentença. Salvador, 07 de novembro de 2026. Juiz de Direito.',
      extra: { tipo_comunicacao: 'Intimação', orgao: '5ª VSJE do Consumidor', link: 'https://comunica.pje.jus.br/', disponibilizacao: '2026-11-10', status: db._pubPrazo ? 'prazo_criado' : 'nova' }, anotacoes: [] },
    { origem: 'movimentacao', item_id: 'x2', quando: '2026-11-07T14:12:00-03:00', titulo: 'Expedição de documento', detalhe: 'Intimação', nova: true, anotacoes: [] },
    { origem: 'movimentacao', item_id: 'x3', quando: '2026-10-20T09:30:00-03:00', titulo: 'Distribuição', detalhe: 'Sorteio', nova: false,
      anotacoes: [] },
  ].sort((a, b) => b.quando.localeCompare(a.quando))
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
    clientes: db.clientes.filter(c => podeVerCliente(c.id)).length, publicacoesNovas: 1, sugestoesPendentes: db.sugestoes.filter(s => s.status === 'pendente').length,
    sugestoesSuspensao: db.sugestoes.filter(s => s.status === 'pendente' && s.tipo === 'suspensao').length,
    sugestoesAudiencia: db.sugestoes.filter(s => s.status === 'pendente' && s.tipo === 'audiencia' && podeVerProcesso(s.processo_id)).length,
    processosNovos: semearDescobertas().filter(d => d.meu && d.status === 'pendente').length }
}

// ---------- Suspensões (demonstração) ----------
function carnavalCorpus(ano) {
  const a = ano % 19, b = Math.floor(ano / 100), c = ano % 100, d = Math.floor(b / 4), e = b % 4, f = Math.floor((b + 8) / 25), g = Math.floor((b - f + 1) / 3)
  const h = (19 * a + b - d - g + 15) % 30, i = Math.floor(c / 4), k = c % 4, l = (32 + 2 * e + 2 * i - h - k) % 7, m = Math.floor((a + 11 * h + 22 * l) / 451)
  const mes = Math.floor((h + l - 7 * m + 114) / 31), dia = ((h + l - 7 * m + 114) % 31) + 1
  const pascoa = new Date(ano, mes - 1, dia, 12), off = n => { const x = new Date(pascoa); x.setDate(x.getDate() + n); return x.toLocaleDateString('en-CA') }
  const pf = (d, m) => ({ id: 'pf' + d, abrangencia: 'nacional', tribunal: null, comarca: null, orgao: null, data_inicio: d, data_fim: d, hora_inicio: null, tipo: 'ponto_facultativo', motivo: m, numero_ato: 'Calendário forense', link_ato: null, fonte: 'regra', instancia: 'todas' })
  return [pf(off(-48), 'Carnaval (segunda-feira)'), pf(off(-47), 'Carnaval (terça-feira)'), pf(off(60), 'Corpus Christi')]
}
function semearSuspensoes() {
  const ano = new Date().getFullYear()
  const r = (d, m) => ({ id: 's' + d + m, abrangencia: 'nacional', tribunal: null, comarca: null, orgao: null, data_inicio: d, data_fim: d, hora_inicio: null, tipo: 'feriado', motivo: m, numero_ato: 'Lei 662/1949', link_ato: null, fonte: 'regra' })
  const mes = String(new Date().getMonth() + 1).padStart(2, '0')
  const dmes = d => `${ano}-${mes}-${String(d).padStart(2, '0')}`
  const daqui = n => { const x = new Date(); x.setDate(x.getDate() + n); return x.toLocaleDateString('en-CA') }
  db.suspensoes = [
    ...carnavalCorpus(ano), r(`${ano}-11-02`, 'Finados'), r(`${ano}-11-15`, 'Proclamação da República'),
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

// Calendário local (feriados estaduais e municipais) → sugestões, como a rotina diária do Supabase
const semAcento = t => (t || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().replace(/[^a-z0-9]/g, '')
function pascoaDe(ano) {
  const a = ano % 19, b = Math.floor(ano / 100), c = ano % 100, d = Math.floor(b / 4), e = b % 4, f = Math.floor((b + 8) / 25), g = Math.floor((b - f + 1) / 3)
  const h = (19 * a + b - d - g + 15) % 30, i = Math.floor(c / 4), k = c % 4, l = (32 + 2 * e + 2 * i - h - k) % 7, m = Math.floor((a + 11 * h + 22 * l) / 451)
  return new Date(ano, Math.floor((h + l - 7 * m + 114) / 31) - 1, ((h + l - 7 * m + 114) % 31) + 1, 12)
}
function gerarCalendarioMock() {
  const hoje = hojeSP(), lim = new Date(); lim.setDate(lim.getDate() + 370); const limite = lim.toLocaleDateString('en-CA')
  const uso = new Map()
  for (const p of db.processos || []) if (['ativo', 'suspenso'].includes(p.situacao) && p.tribunal) uso.set(p.tribunal + '|' + semAcento(p.comarca), p)
  const itens = [...ESTADUAIS, ...Object.entries(TJBA_MUNICIPAIS).flatMap(([com, ds]) => ds.map(([mes, dia]) => ({ uf: 'BA', comarca: com, mes, dia, motivo: 'Feriado municipal de ' + com, base_legal: 'TJBA · Decreto Judiciário nº 09/2026 (feriados municipais das comarcas)', link: TJBA_LINK, tribunais: ['TJBA'], instancia: '1g' })))]
  const anos = [new Date().getFullYear(), new Date().getFullYear() + 1]
  db.sugestoes = db.sugestoes || []
  for (const c of itens) for (const ano of anos) {
    const dt = c.pascoa_offset != null ? (() => { const x = pascoaDe(ano); x.setDate(x.getDate() + c.pascoa_offset); return x })() : new Date(ano, c.mes - 1, c.dia, 12)
    const d = dt.toLocaleDateString('en-CA'); if (d < hoje || d > limite || [0, 6].includes(dt.getDay())) continue
    for (const p of uso.values()) {
      if (!c.tribunais.includes(p.tribunal) || (c.comarca && semAcento(c.comarca) !== semAcento(p.comarca))) continue
      const chave = `${c.uf}:${c.comarca || ''}:${c.motivo}:${d}:${p.tribunal}`
      if (db.sugestoes.some(g => g.dados?.chave === chave)) continue
      if (db.suspensoes.some(s => s.data_inicio <= d && s.data_fim >= d && !s.hora_inicio && (s.abrangencia === 'nacional' || (s.tribunal === p.tribunal && (s.abrangencia === 'tribunal' || (c.comarca && s.abrangencia === 'comarca' && semAcento(s.comarca) === semAcento(p.comarca))))))) continue
      db.sugestoes.push({ id: 'cal' + novoId(), tipo: 'suspensao', status: 'pendente', criado_em: agora(),
        justificativa: c.comarca ? `Feriado municipal da comarca de ${p.comarca}, da relação publicada pelo TJBA no Decreto Judiciário nº 09/2026.${ano > 2026 ? ` Para ${ano}, confira se o decreto do ano manteve a data.` : ''}`
          : `Feriado estadual (${c.uf}) do calendário do Orbeo. Antes de confirmar, verifique se o ${p.tribunal} suspendeu o expediente e os prazos nesta data; em geral consta do calendário anual do tribunal.`,
        dados: { abrangencia: c.comarca ? 'comarca' : 'tribunal', tribunal: p.tribunal, comarca: c.comarca ? p.comarca : undefined, instancia: c.instancia, data_inicio: d, data_fim: d, tipo: 'feriado', motivo: c.motivo, numero_ato: c.base_legal, link_ato: c.link || undefined, origem: 'calendario', chave } })
    }
  }
  gravar()
}
gerarCalendarioMock()

export async function listarSuspensoes(ini, fim) {
  await atraso(); return db.suspensoes.filter(s => s.data_inicio <= fim && s.data_fim >= ini).sort((a, b) => a.data_inicio.localeCompare(b.data_inicio))
}
export async function salvarSuspensao(s) {
  await atraso(200)
  const limpo = { ...s, data_fim: s.data_fim || s.data_inicio, tribunal: s.abrangencia === 'nacional' ? null : s.tribunal,
    comarca: ['comarca', 'orgao'].includes(s.abrangencia) ? s.comarca : null, orgao: s.abrangencia === 'orgao' ? s.orgao : null }
  limpo.instancia = s.instancia || 'todas'; delete limpo.tribunais
  if (s.id) { const i = db.suspensoes.findIndex(x => x.id === s.id); db.suspensoes[i] = { ...db.suspensoes[i], ...limpo } }
  else if (s.tribunais?.length > 1) s.tribunais.forEach(t => db.suspensoes.push({ ...limpo, tribunal: t, id: novoId(), fonte: 'manual' }))
  else db.suspensoes.push({ ...limpo, id: novoId(), fonte: 'manual' })
  gravar(); return limpo
}
export async function excluirSuspensao(id) { await atraso(); db.suspensoes = db.suspensoes.filter(s => s.id !== id || s.fonte === 'regra'); gravar() }
export async function sugestoesSuspensao() { await atraso(); return db.sugestoes.filter(s => s.status === 'pendente' && s.tipo === 'suspensao') }
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
  db.oabs?.push({ id: 'o-' + id, advogado_id: id, numero: d.oab_numero, uf: d.oab_uf, principal: true })
  const papel = d.papel || (d.admin ? 'admin' : 'advogado')
  db.advogados.push({ id, nome: d.nome, email: d.email, oab_numero: d.oab_numero, oab_uf: d.oab_uf, admin: papel === 'admin', papel, visao_geral: Boolean(d.visao_geral), ativo: true, trocar_senha: true, ultimo_acesso: null })
  gravar(); return { id, senha_temporaria: senha }
}
export async function adminAtivar(id, ativo) {
  await atraso(); if (id === me()) throw new Error('Você não pode desativar o seu próprio acesso.')
  db.advogados.find(a => a.id === id).ativo = ativo; gravar()
}
export async function adminPapel(id, papel) { await atraso(); const a = db.advogados.find(x => x.id === id); a.papel = papel; a.admin = papel === 'admin'; gravar() }
export async function adminVisaoGeral(id, v) { await atraso(); db.advogados.find(x => x.id === id).visao_geral = v; gravar() }
export async function listarEscritorios() { await atraso(); semearEquipe(); return db.escritorios }
export async function criarEscritorio(d) {
  await atraso(400); const id = novoId()
  db.escritorios.push({ id, nome: d.nome, tipo: 'escritorio', ativo: true, criado_em: new Date().toISOString(), usuarios: 1, processos: 0 }); gravar()
  return { escritorio_id: id, senha_temporaria: senhaDemo() }
}
export async function ativarEscritorio(id, ativo) { await atraso(); db.escritorios.find(e => e.id === id).ativo = ativo; gravar() }
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

// ---------- DataJud (demonstração) ----------
export async function atualizarDataJud(pid) {
  await atraso(900)
  const p = db.processos.find(x => x.id === pid)
  const primeira = !p.datajud_sync_em
  if (p.datajud_sync_em && Date.now() - new Date(p.datajud_sync_em) < 600000) return { novos: 0, aviso: 'Consultado há pouco. Tente de novo em 10 min. (O DataJud atualiza uma vez por dia.)' }
  p.datajud_sync_em = p.djen_sync_em = new Date().toISOString()
  p.datajud_atualizado_em = '2026-10-02T09:12:00.000Z'
  if (!p.comarca) p.comarca = 'Salvador'
  if (!p.classe) p.classe = 'Procedimento do Juizado Especial Cível'
  gravar()
  return primeira ? { novos: 0, total: 14, importados: 14, publicacoes_novas: pid === 'p1' ? 1 : 0 } : { novos: 1, total: 15, publicacoes_novas: 0 }
}
export async function marcarVistas(pid) { await atraso(); if (pid === 'p1') db._pubLida = true; const p = db.processos.find(x => x.id === pid); if (p) p._visto = true; gravar(); return 1 }
export async function saudeConsultas() {
  await atraso()
  const h = n => new Date(Date.now() - n * 3600000).toISOString()
  return [
    { id: 'r1', fonte: 'datajud', iniciada_em: h(16), finalizada_em: h(15.97), status: 'ok', requisicoes: 0, novidades: 0, mensagem: 'Nada a consultar: todos já foram consultados hoje.' },
    { id: 'r2', fonte: 'datajud', iniciada_em: h(16.2), finalizada_em: h(16.17), status: 'ok', requisicoes: 7, novidades: 3, mensagem: '7 processo(s) consultado(s).' },
    { id: 'r3', fonte: 'datajud', iniciada_em: h(40), finalizada_em: h(39.97), status: 'parcial', requisicoes: 5, novidades: 1, mensagem: 'Último erro: O DataJud respondeu com erro 504.' },
  ]
}

// ---------- Audiências (demonstração) ----------
function semearAudiencias() {
  const em = (dias, hora) => { const d = new Date(); d.setDate(d.getDate() + dias); const dia = d.toLocaleDateString('en-CA'); return new Date(`${dia}T${hora}:00-03:00`).toISOString() }
  db.audiencias = [
    { id: 'a1', processo_id: 'p1', tipo: 'conciliacao', data_hora: em(1, '09:00'), modalidade: 'virtual', local: null, link: 'https://meet.exemplo/juizado-5', status: 'agendada', resultado: null, observacoes: 'Levar proposta de acordo até R$ 3.000.' },
    { id: 'a2', processo_id: 'p4', tipo: 'instrucao', data_hora: em(3, '14:00'), modalidade: 'presencial', local: 'Fórum Trabalhista de Salvador · Sala 4', link: null, status: 'agendada', resultado: null, observacoes: 'Duas testemunhas da empresa.' },
    { id: 'a3', processo_id: 'p3', tipo: 'una', data_hora: em(9, '10:30'), modalidade: 'hibrida', local: 'Fórum de Feira de Santana', link: 'https://meet.exemplo/feira', status: 'agendada', resultado: null, observacoes: null },
    { id: 'a4', processo_id: 'p2', tipo: 'conciliacao', data_hora: em(-2, '11:00'), modalidade: 'virtual', local: null, link: 'https://meet.exemplo/x', status: 'agendada', resultado: null, observacoes: null },
    { id: 'a5', processo_id: 'p6', tipo: 'conciliacao', data_hora: em(-20, '15:00'), modalidade: 'virtual', local: null, link: null, status: 'realizada', resultado: 'Sem acordo. Autos conclusos para sentença.', observacoes: null },
    { id: 'a9', processo_id: 'p9', tipo: 'conciliacao', data_hora: em(1, '08:00'), modalidade: 'virtual', local: null, link: null, status: 'agendada', resultado: null, observacoes: 'sigilosa da colega' },
  ]
  db.sugestoes = db.sugestoes || []
  db.sugestoes.push({ id: 'sa1', tipo: 'audiencia', status: 'pendente', processo_id: 'p5', criado_em: agora(),
    dados: { tipo: 'conciliacao', andamento: 'Audiência', complemento: 'tipo de audiencia: Conciliação · situacao da audiencia: designada' },
    justificativa: 'Andamento no DataJud: Audiência (tipo de audiencia: Conciliação · situacao da audiencia: designada). O DataJud não informa a data da audiência: confira no processo e cadastre.' })
}
if (!db.audiencias) { semearAudiencias(); gravar() }
function vwAud(a) {
  const p = db.processos.find(x => x.id === a.processo_id); const c = db.clientes.find(x => x.id === p.cliente_id)
  return { ...a, numero_cnj: p.numero_cnj, tribunal: p.tribunal, comarca: p.comarca, orgao_julgador: p.orgao_julgador, polo: p.polo, parte_contraria: p.parte_contraria, cliente_id: p.cliente_id, cliente: c.nome }
}
export async function listarAudiencias(f = {}) {
  await atraso()
  let l = db.audiencias.filter(a => podeVerProcesso(a.processo_id)).map(vwAud)
  if (f.processo_id) l = l.filter(a => a.processo_id === f.processo_id)
  if (f.de) l = l.filter(a => a.data_hora >= f.de)
  if (f.ate) l = l.filter(a => a.data_hora <= f.ate)
  if (f.status) l = l.filter(a => a.status === f.status)
  l.sort((a, b) => a.data_hora.localeCompare(b.data_hora)); if (f.decrescente) l.reverse()
  return l.slice(0, f.limite || 500)
}
export async function salvarAudiencia(a) {
  await atraso(200)
  if (!podeVerProcesso(a.processo_id)) throw new Error('Você não tem acesso a este registro.')
  if (a.id) { const i = db.audiencias.findIndex(x => x.id === a.id); db.audiencias[i] = { ...db.audiencias[i], ...a } ; gravar(); return db.audiencias[i] }
  const nova = { status: 'agendada', ...a, id: novoId() }; db.audiencias.push(nova); gravar(); return nova
}
export async function excluirAudiencia(id) { await atraso(); db.audiencias = db.audiencias.filter(a => a.id !== id); gravar() }
export async function sugestoesAudiencia() {
  await atraso()
  return (db.sugestoes || []).filter(s => s.tipo === 'audiencia' && s.status === 'pendente' && podeVerProcesso(s.processo_id))
    .map(s => { const p = vwProcesso(db.processos.find(x => x.id === s.processo_id)); return { ...s, processo: { id: p.id, numero_cnj: p.numero_cnj, cliente_nome: p.cliente_nome, polo: p.polo, tribunal: p.tribunal, orgao_julgador: p.orgao_julgador } } })
}
export async function aceitarSugestaoAudiencia(sg, a) {
  const s = await salvarAudiencia({ ...a, processo_id: sg.processo_id, sugestao_id: sg.id })
  db.sugestoes.find(x => x.id === sg.id).status = 'aceita'; gravar(); return s
}

// ---------- Prazos (demonstração) ----------
function vwPrazo(z) {
  const p = db.processos.find(x => x.id === z.processo_id); const c = db.clientes.find(x => x.id === p.cliente_id)
  const hoje = hojeSP()
  return { ...z, numero_cnj: p.numero_cnj, tribunal: p.tribunal, comarca: p.comarca, orgao_julgador: p.orgao_julgador, polo: p.polo, parte_contraria: p.parte_contraria, cliente: c.nome,
    responsavel_nome: db.advogados.find(a => a.id === z.responsavel_id)?.nome, responsavel_papel: db.advogados.find(a => a.id === z.responsavel_id)?.papel,
    cumprido_por_nome: db.advogados.find(a => a.id === z.cumprido_por)?.nome || null, rito: p.rito,
    audiencia_data_hora: z.audiencia_id ? db.audiencias.find(a => a.id === z.audiencia_id)?.data_hora : null,
    situacao: z.status !== 'aberto' ? z.status : z.prazo_fatal < hoje ? 'vencido' : z.prazo_fatal === hoje ? 'vence_hoje' : 'aberto' }
}
export async function listarPrazos(f = {}) {
  await atraso()
  return db.prazos.filter(z => podeVerProcesso(z.processo_id) && (!f.processo_id || z.processo_id === f.processo_id) && (!f.status || z.status === f.status))
    .map(vwPrazo).sort((a, b) => a.prazo_fatal.localeCompare(b.prazo_fatal))
}
export async function salvarPrazo(z) {
  await atraso(200)
  if (!podeVerProcesso(z.processo_id)) throw new Error('Você não tem acesso a este registro.')
  if (z.publicacao_id === 'x1') db._pubPrazo = true
  const p = db.processos.find(x => x.id === z.processo_id)
  let reg = { status: 'aberto', ...z, calculo_auto: z.calculo_auto !== false }
  if (z.audiencia_id) {
    const a = db.audiencias.find(x => x.id === z.audiencia_id)
    reg = { ...reg, calculo_auto: false, prazo_fatal: new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo' }).format(new Date(a.data_hora)) }
  } else if (reg.calculo_auto) {
    const r = _calc({ data: z.data_recebimento, origem: z.origem_contagem, dias: Number(z.dias), contagem: z.contagem }, db.suspensoes, p)
    reg = { ...reg, prazo_fatal: r.fatal, data_inicio_contagem: r.inicio }
  }
  if (!reg.prazo_fatal) throw new Error('Informe o prazo fatal ou os dias do prazo.')
  if (z.id) { const i = db.prazos.findIndex(x => x.id === z.id); db.prazos[i] = { ...db.prazos[i], ...reg } } else db.prazos.push({ ...reg, id: novoId() })
  gravar(); return reg
}
const nomeDe = id => db.advogados.find(a => a.id === id)?.nome || null
function registrar(prazo_id, acao, texto) { (db.przh ||= []).push({ id: novoId(), prazo_id, acao, texto, autor_id: me(), autor_nome: nomeDe(me()), em: new Date().toISOString() }) }
export async function cumprirPrazo(id, data, obs = null) {
  await atraso(); const z = db.prazos.find(x => x.id === id); z.status = 'cumprido'; z.data_cumprimento = data; z.cumprido_por = me(); z.cumprimento_obs = obs || null
  registrar(id, 'cumprido', `Cumprido em ${data.split('-').reverse().join('/')}${obs ? '\n' + obs : ''}`); gravar(); return z
}
export async function historicoPrazo(id) {
  await atraso(); const z = db.prazos.find(x => x.id === id)
  const base = [{ id: 'h0' + id, prazo_id: id, acao: 'criado', texto: `${z.tipo} · fatal ${z.prazo_fatal.split('-').reverse().join('/')}${z.responsavel_id ? ' · responsável: ' + nomeDe(z.responsavel_id) : ''}`, autor_nome: nomeDe(EU), em: z.criado_em || new Date(Date.now() - 86400000 * 3).toISOString() }]
  return [...base, ...(db.przh || []).filter(h => h.prazo_id === id)]
}
export async function observarPrazo(id, texto) { await atraso(); registrar(id, 'observacao', texto); gravar() }
export async function reabrirPrazo(id) { await atraso(); const z = db.prazos.find(x => x.id === id); z.status = 'aberto'; z.data_cumprimento = null; z.cumprido_por = null; z.cumprimento_obs = null; registrar(id, 'reaberto', null); gravar(); return z }
export async function excluirPrazo(id) { await atraso(); db.prazos = db.prazos.filter(z => z.id !== id); gravar() }

// ---------- Buscar processos no DJEN (demonstração) ----------
export async function pesquisarDJEN({ nome, inicio, fim }) {
  await atraso(1400)
  const meu = db.processos.find(p => podeVerProcesso(p.id))
  const N = nome.toUpperCase()
  return { inicio, fim, publicacoes: 5, total: 5, truncado: false, coberto_desde: null, processos: [
    { numero_cnj: '8004567-12.2026.8.05.0001', tribunal: 'TJBA', orgao_julgador: '12ª Vara do Sistema dos Juizados Especiais do Consumidor', classe: 'Procedimento do Juizado Especial Cível',
      partes: [{ nome: 'CARLA MENDES DE OLIVEIRA', polo: 'A' }, { nome: N, polo: 'P' }], publicacoes: 2, primeira: menosDias(9), ultima: menosDias(3), ultimo_tipo: 'Despacho',
      ultimo_trecho: 'Designo audiência de conciliação para o dia 09/12/2026, às 10h, por videoconferência. Cite-se e intime-se a parte ré.', link: 'https://comunica.pje.jus.br/', polo_pesquisado: 'reu', processo_id: null },
    { numero_cnj: '0012345-67.2026.8.05.0080', tribunal: 'TJBA', orgao_julgador: '2ª Vara Cível de Feira de Santana', classe: 'Procedimento Comum Cível',
      partes: [{ nome: N, polo: 'A' }, { nome: 'VIAGENS BRASIL AGÊNCIA LTDA', polo: 'P' }], publicacoes: 1, primeira: menosDias(6), ultima: menosDias(6), ultimo_tipo: 'Decisão',
      ultimo_trecho: 'Defiro a tutela de urgência requerida...', link: null, polo_pesquisado: 'autor', processo_id: null },
    { numero_cnj: meu.numero_cnj, tribunal: meu.tribunal, orgao_julgador: meu.orgao_julgador, classe: meu.classe, partes: [{ nome: meu.parte_contraria, polo: 'A' }, { nome: N, polo: 'P' }],
      publicacoes: 2, primeira: menosDias(20), ultima: menosDias(6), ultimo_tipo: 'Despacho', ultimo_trecho: 'Intime-se a parte ré para manifestação.', link: null, polo_pesquisado: 'reu', processo_id: meu.id },
  ] }
}
function menosDias(n) { const d = new Date(); d.setDate(d.getDate() - n); return d.toLocaleDateString('en-CA') }

// ---------- Notificações (demonstração) ----------
export async function pushChavePublica() { await atraso(); return 'BEl62iUYgUivxIkv69yViEuiBIa-Ib9-SkvMeAtA3LFgDzkrxZJjSgSnfckjBJuBkr3qBUYIHBQFLXYp5Nksh8U' }
export async function salvarInscricaoPush() { await atraso(); db._push = [{ id: 'd1', aparelho: 'iPhone', criado_em: new Date().toISOString() }]; gravar() }
export async function removerInscricaoPush() { await atraso(); db._push = []; gravar() }
export async function meusAparelhos() { await atraso(); return db._push || [] }
export async function pushTeste() { await atraso(500); return { enviados: 1 } }

// ---------- Processos novos (demonstração) ----------
function semearDescobertas() {
  if (db.descobertas) return db.descobertas
  const h = n => new Date(Date.now() - n * 3600000).toISOString()
  const d = n => { const x = new Date(); x.setDate(x.getDate() - n); return x.toLocaleDateString('en-CA') }
  const base = (id, cliente, fantasia, num, trib, orgao, classe, partes, polo, ult, tipo, trecho) => ({ descoberta_id: id, cliente_id: 'c1', cliente_nome: cliente, cliente_fantasia: fantasia,
    numero_cnj: num, tribunal: trib, orgao_julgador: orgao, classe, partes, polo_cliente: polo, publicacoes: 1, primeira: ult, ultima: ult, ultimo_tipo: tipo, trecho, link: 'https://comunica.pje.jus.br/', termo: 'MARQUES TURISMO', encontrado_em: h(5) })
  const d1 = base('dsc1', 'Marques Turismo Ltda', 'Marques Turismo', '8007788-15.2026.8.05.0001', 'TJBA', '9ª Vara do Sistema dos Juizados Especiais do Consumidor', 'Procedimento do Juizado Especial Cível',
    [{ nome: 'RENATA ALVES COSTA', polo: 'A' }, { nome: 'MARQUES TURISMO LTDA', polo: 'P' }], 'reu', d(1), 'Despacho', 'Designo audiência de conciliação por videoconferência. Cite-se a parte ré.')
  const d2 = base('dsc2', 'Marques Turismo Ltda', 'Marques Turismo', '1023456-78.2026.8.26.0100', 'TJSP', '3ª Vara Cível do Foro Central', 'Procedimento Comum Cível',
    [{ nome: 'PAULO HENRIQUE DIAS', polo: 'A' }, { nome: 'MARQUES TURISMO LTDA', polo: 'P' }], 'reu', d(2), 'Decisão', 'Defiro a gratuidade. Cite-se a ré para contestar no prazo legal.')
  const d3 = base('dsc3', 'Bahia Tech Notebooks Ltda', 'Bahia Tech', '0001122-33.2026.5.05.0003', 'TRT5', '3ª Vara do Trabalho de Salvador', 'Ação Trabalhista - Rito Ordinário',
    [{ nome: 'JOSÉ CARLOS SOUZA', polo: 'A' }, { nome: 'BAHIA TECH NOTEBOOKS LTDA', polo: 'P' }], 'reu', d(9), 'Notificação', 'Notifique-se a reclamada para audiência inicial.')
  db.descobertas = [
    { ...d1, aviso_id: 'av1', advogado_id: EU, advogado_nome: 'Wilquer Bosque', meu: true, notificado_em: h(5), status: 'pendente', decidido_em: null, decidido_por_nome: null },
    { ...d1, aviso_id: 'av2', advogado_id: COLEGA, advogado_nome: 'Colega do Escritório', meu: false, notificado_em: h(5), status: 'pendente', decidido_em: null, decidido_por_nome: null },
    { ...d2, aviso_id: 'av3', advogado_id: EU, advogado_nome: 'Wilquer Bosque', meu: true, notificado_em: h(29), status: 'pendente', decidido_em: null, decidido_por_nome: null },
    { ...d3, aviso_id: 'av4', advogado_id: EU, advogado_nome: 'Wilquer Bosque', meu: true, notificado_em: h(200), status: 'visualizado', decidido_em: h(190), decidido_por_nome: 'Wilquer Bosque' },
  ]
  gravar(); return db.descobertas
}
export async function listarDescobertas({ historico = false } = {}) {
  await atraso(); const l = semearDescobertas()
  return (historico ? l : l.filter(x => x.meu && x.status === 'pendente')).map(x => ({ ...x })).sort((a, b) => b.notificado_em.localeCompare(a.notificado_em))
}
export async function decidirDescoberta(avisoId, status) {
  await atraso(200); const a = db.descobertas.find(x => x.aviso_id === avisoId)
  a.status = status; a.decidido_em = status === 'pendente' ? null : new Date().toISOString(); a.decidido_por_nome = status === 'pendente' ? null : 'Wilquer Bosque'; gravar()
}

// ---------- Notificações pessoais (demonstração) ----------
export const PREFS_PADRAO = { prazos: true, prazos_hora: 7, prazos_dias: 1, prazos_elaborar: true, audiencias: true, aud_vespera_hora: 18,
  aud_horas_antes: 2, publicacoes: true, novos: true, sugestoes: true, sugestoes_hora: 8, escopo: 'meus' }
function semearNotificacoes() {
  const h = (horas) => new Date(Date.now() - horas * 3600_000).toISOString()
  const d1 = (db.descobertas || [])[0]
  db.notificacoes = [
    { id: 'n1', tipo: 'novos', titulo: 'Processos novos identificados', texto: '2 processos dos seus clientes ainda não estão no Orbeo.', url: '#/novos', criado_em: h(5), lida_em: null, push_aparelhos: 0, push_motivo: 'Nenhum aparelho com notificações ativas.' },
    { id: 'n2', tipo: 'prazos', titulo: 'Prazos', texto: '1 prazo vence hoje, 2 prazos vencem amanhã.', url: '#/prazos', criado_em: h(6), lida_em: null, push_aparelhos: 0, push_motivo: 'Nenhum aparelho com notificações ativas.' },
    { id: 'n3', tipo: 'publicacao', titulo: 'Publicação nova no DJEN', texto: `${db.clientes?.[0]?.nome || 'Cliente'} · Intimação`, url: '#/processos/p1', criado_em: h(7), lida_em: null, push_aparelhos: 1, push_motivo: null },
    { id: 'n4', tipo: 'audiencia', titulo: 'Audiência amanhã', texto: `${db.clientes?.[1]?.nome || 'Cliente'} · 09:30`, url: '#/audiencias', criado_em: h(20), lida_em: h(19), push_aparelhos: 1, push_motivo: null },
    { id: 'n5', tipo: 'sugestoes', titulo: 'Sugestões para confirmar', texto: '3 sugestões aguardam a confirmação do escritório.', url: '#/suspensoes', criado_em: h(29), lida_em: h(28), push_aparelhos: 1, push_motivo: null },
  ]
  if (d1) db.notificacoes[0].texto = '2 processos dos seus clientes ainda não estão no Orbeo.'
}
if (!db.notificacoes) { semearNotificacoes(); gravar() }
export async function minhasPreferencias() { await atraso(); return { ...PREFS_PADRAO, ...(db.notifPrefs?.[me()] || {}) } }
export async function salvarPreferencias(p) { await atraso(); db.notifPrefs = { ...(db.notifPrefs || {}), [me()]: { ...p } }; gravar(); return p }
export async function listarNotificacoes() { await atraso(); return [...db.notificacoes].sort((a, b) => b.criado_em.localeCompare(a.criado_em)) }
export async function contarNaoLidas() { return db.notificacoes.filter(n => !n.lida_em).length }
export async function marcarNotificacoesLidas(ids = null) {
  await atraso(); let n = 0
  for (const x of db.notificacoes) if (!x.lida_em && (!ids || ids.includes(x.id))) { x.lida_em = agora(); n++ }
  gravar(); return n
}
if (!db.observacoes) {
  const outro = db.advogados.find(a => a.id !== EU) || db.advogados[0]
  db.observacoes = [{ id: 'ob1', processo_id: 'p1', texto: 'Cliente informou que houve tentativa de acordo pelo WhatsApp. Aguardar proposta por escrito.', autor_id: outro.id, criado_em: '2026-10-21T10:00:00-03:00' }]
  gravar()
}
