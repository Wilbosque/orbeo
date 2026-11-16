import { useState } from 'react'
import * as api from '#backend'
import Icone from '../components/Icone.jsx'
import { Campo, Carregando, Erro, Folha, Topo, Vazio, useCarregar, useToast } from '../components/ui.jsx'
import { UFS } from '../lib/formato.js'

// Área do dono da plataforma: cria escritórios e o sócio administrador de cada um
function NovoEscritorio({ aoCriar }) {
  const [f, setF] = useState({ nome: '', admin_nome: '', admin_email: '', admin_oab_numero: '', admin_oab_uf: 'BA' })
  const [erro, setErro] = useState('')
  const [salvando, setSalvando] = useState(false)
  const set = k => e => setF({ ...f, [k]: e.target.value })
  async function salvar(e) {
    e.preventDefault(); setErro('')
    if (!f.nome.trim() || !f.admin_nome.trim() || !f.admin_email.trim() || !f.admin_oab_numero.trim()) return setErro('Preencha todos os campos.')
    setSalvando(true)
    try { const r = await api.criarEscritorio({ ...f, admin_email: f.admin_email.trim().toLowerCase() }); aoCriar(r, f) }
    catch (err) { setErro(err.message) } finally { setSalvando(false) }
  }
  return (
    <form className="form" onSubmit={salvar}>
      {erro && <div className="aviso erro"><Icone nome="alerta" />{erro}</div>}
      <Campo rotulo="Nome do escritório" obrigatorio><input className="entrada" value={f.nome} onChange={set('nome')} placeholder="Ex.: Souza & Lima Advogados" /></Campo>
      <div className="secao" style={{ marginTop: 6 }}><h2>Sócio administrador</h2></div>
      <small className="muted" style={{ marginTop: -8 }}>Ele cria os demais usuários do escritório e decide quem tem visão geral dos processos.</small>
      <Campo rotulo="Nome completo" obrigatorio><input className="entrada" value={f.admin_nome} onChange={set('admin_nome')} /></Campo>
      <Campo rotulo="E-mail de acesso" obrigatorio><input className="entrada" type="email" inputMode="email" value={f.admin_email} onChange={set('admin_email')} /></Campo>
      <div className="duas">
        <Campo rotulo="Nº da OAB" obrigatorio><input className="entrada mono" inputMode="numeric" value={f.admin_oab_numero} onChange={set('admin_oab_numero')} /></Campo>
        <Campo rotulo="UF"><select className="entrada" value={f.admin_oab_uf} onChange={set('admin_oab_uf')}>{UFS.map(u => <option key={u}>{u}</option>)}</select></Campo>
      </div>
      <button className="btn primario bloco" disabled={salvando}>{salvando ? 'Criando…' : 'Criar escritório'}</button>
    </form>
  )
}

export default function Escritorios() {
  const toast = useToast()
  const r = useCarregar(() => api.listarEscritorios(), [])
  const [novo, setNovo] = useState(false)
  const [criado, setCriado] = useState(null)
  const lista = r.dados || []
  async function ativar(e) {
    if (e.ativo && !window.confirm(`Desativar ${e.nome}? Todos os usuários dele perdem o acesso (nada é apagado).`)) return
    try { await api.ativarEscritorio(e.id, !e.ativo); toast(e.ativo ? 'Escritório desativado.' : 'Escritório reativado.'); r.recarregar() } catch (err) { toast(err.message, 'erro') }
  }
  const copiar = async t => { try { await navigator.clipboard.writeText(t); toast('Senha copiada.') } catch { toast('Copie manualmente.', 'erro') } }
  return (
    <>
      <Topo titulo="Escritórios" sub="Área do dono da plataforma" />
      <div className="aviso info" style={{ marginBottom: 12 }}><Icone nome="cadeado" />
        <div>Cada escritório só enxerga os próprios dados. Como dono da plataforma, você cria escritórios e o primeiro sócio administrador, mas <b>não vê</b> os processos deles.</div>
      </div>
      {r.erro && <Erro erro={r.erro} tentar={r.recarregar} />}
      {r.carregando && !r.dados ? <Carregando n={2} /> : lista.length ? (
        <div className="lista grade">
          {lista.map(e => (
            <div key={e.id} className="cartao" style={{ opacity: e.ativo ? 1 : .6 }}>
              <div className="cartao-topo"><h3 style={{ margin: 0 }}>{e.nome}</h3>{!e.ativo && <span className="selo perigo">Desativado</span>}</div>
              <div className="linha">{e.usuarios} usuário{e.usuarios === 1 ? '' : 's'} · {e.processos} processo{e.processos === 1 ? '' : 's'} · desde {new Date(e.criado_em).toLocaleDateString('pt-BR')}</div>
              <button className="btn pequeno" style={{ marginTop: 10 }} onClick={() => ativar(e)}>{e.ativo ? 'Desativar' : 'Reativar'}</button>
            </div>
          ))}
        </div>
      ) : <Vazio icone="balanca" titulo="Nenhum escritório" texto="Crie o primeiro pelo botão abaixo." />}
      <button className="fab" onClick={() => setNovo(true)}><Icone nome="mais_add" />Escritório</button>
      <Folha titulo={criado ? 'Escritório criado' : 'Novo escritório'} aberta={novo || Boolean(criado)} fechar={() => { setNovo(false); setCriado(null) }}>
        {criado ? (
          <div className="form">
            <div className="aviso info"><Icone nome="cadeado" /><div>Envie a senha provisória para <b>{criado.email}</b> por um canal seguro. Ela só aparece agora; no primeiro acesso, o sistema pede uma senha pessoal.</div></div>
            <div className="senha-gerada mono">{criado.senha}</div>
            <button className="btn primario bloco" onClick={() => copiar(criado.senha)}><Icone nome="copiar" />Copiar senha</button>
            <button className="btn bloco" onClick={() => { setCriado(null); setNovo(false) }}>Concluir</button>
          </div>
        ) : <NovoEscritorio aoCriar={(res, f) => { setCriado({ senha: res.senha_temporaria, email: f.admin_email }); setNovo(false); r.recarregar() }} />}
      </Folha>
    </>
  )
}
