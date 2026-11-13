import { useState } from 'react'
import { Link } from 'react-router-dom'
import * as api from '#backend'
import { usePerfil } from '../App.jsx'
import Icone from '../components/Icone.jsx'
import { Campo, Folha, Topo, useToast } from '../components/ui.jsx'
import { UFS, iniciais } from '../lib/formato.js'

export default function Ajustes() {
  const { perfil, setPerfil, email } = usePerfil()
  const toast = useToast()
  const [editar, setEditar] = useState(false)
  const [senha, setSenha] = useState(false)
  const [f, setF] = useState(perfil)
  const [nova, setNova] = useState('')
  const [salvando, setSalvando] = useState(false)

  async function salvarPerfil(e) {
    e.preventDefault(); setSalvando(true)
    try { setPerfil(await api.salvarPerfil({ nome: f.nome.trim(), oab_numero: f.oab_numero.replace(/\D/g, ''), oab_uf: f.oab_uf })); setEditar(false); toast('Cadastro atualizado.') }
    catch (err) { toast(err.message, 'erro') } finally { setSalvando(false) }
  }
  async function salvarSenha(e) {
    e.preventDefault()
    if (nova.length < 8) { toast('A senha precisa ter pelo menos 8 caracteres.', 'erro'); return }
    setSalvando(true)
    try { await api.trocarSenha(nova); setSenha(false); setNova(''); toast('Senha alterada.') }
    catch (err) { toast(err.message, 'erro') } finally { setSalvando(false) }
  }

  return (
    <>
      <Topo titulo="Ajustes" sub="Sua conta e as configurações do sistema" />
      <div className="cartao" style={{ display: 'flex', gap: 14, alignItems: 'center' }}>
        <span className="avatar" style={{ width: 52, height: 52, fontSize: '1.05rem', background: 'var(--violeta)', color: '#fff' }}>{iniciais(perfil.nome)}</span>
        <div style={{ flex: 1, minWidth: 0 }}>
          <h3 style={{ margin: 0 }}>{perfil.nome}</h3>
          <div className="linha">OAB {perfil.oab_numero}/{perfil.oab_uf}</div>
          <div className="linha">{email}</div>
        </div>
      </div>

      <div className="secao"><h2>Conta</h2></div>
      <div className="lista">
        <button className="cartao" onClick={() => { setF(perfil); setEditar(true) }} style={{ display: 'flex', gap: 12, alignItems: 'center' }}><Icone nome="usuario" width="22" height="22" /><b style={{ flex: 1 }}>Meus dados e OAB</b><Icone nome="seta" width="18" height="18" /></button>
        <button className="cartao" onClick={() => setSenha(true)} style={{ display: 'flex', gap: 12, alignItems: 'center' }}><Icone nome="engrenagem" width="22" height="22" /><b style={{ flex: 1 }}>Trocar senha</b><Icone nome="seta" width="18" height="18" /></button>
      </div>

      <div className="secao"><h2>Prazos</h2></div>
      <div className="lista">
        <Link to="/suspensoes" className="cartao" style={{ display: 'flex', gap: 12, alignItems: 'center' }}><Icone nome="calendario" width="22" height="22" /><b style={{ flex: 1 }}>Suspensões de prazo</b><Icone nome="seta" width="18" height="18" /></Link>
        {perfil.admin && <Link to="/usuarios" className="cartao" style={{ display: 'flex', gap: 12, alignItems: 'center' }}><Icone nome="usuarios" width="22" height="22" /><b style={{ flex: 1 }}>Usuários do sistema</b><span className="selo violeta">Admin</span><Icone nome="seta" width="18" height="18" /></Link>}
        <Link to="/ajustes/fontes" className="cartao" style={{ display: 'flex', gap: 12, alignItems: 'center' }}><Icone nome="radar" width="22" height="22" /><b style={{ flex: 1 }}>Fontes dos diários (varredura)</b><Icone nome="seta" width="18" height="18" /></Link>
      </div>

      <div className="secao"><h2>Em breve</h2></div>
      <div className="lista">
        {[['radar', 'Saúde das consultas (DJEN e DataJud)'], ['engrenagem', 'Configurações das consultas']].map(([ic, t]) => (
          <div key={t} className="cartao muted" style={{ display: 'flex', gap: 12, alignItems: 'center' }}><Icone nome={ic} width="22" height="22" />{t}</div>
        ))}
      </div>

      <div style={{ marginTop: 28 }}>
        <button className="btn bloco" onClick={() => api.sair()}><Icone nome="sair" />Sair</button>
      </div>

      <Folha titulo="Meus dados" aberta={editar} fechar={() => setEditar(false)}>
        <form className="form" onSubmit={salvarPerfil}>
          <Campo rotulo="Nome completo" obrigatorio><input className="entrada" value={f.nome} onChange={e => setF({ ...f, nome: e.target.value })} required /></Campo>
          <div className="duas">
            <Campo rotulo="Nº da OAB" obrigatorio><input className="entrada mono" inputMode="numeric" value={f.oab_numero} onChange={e => setF({ ...f, oab_numero: e.target.value })} required /></Campo>
            <Campo rotulo="UF"><select className="entrada" value={f.oab_uf} onChange={e => setF({ ...f, oab_uf: e.target.value })}>{UFS.map(u => <option key={u}>{u}</option>)}</select></Campo>
          </div>
          <small className="muted">A OAB é usada para buscar as suas publicações no DJEN.</small>
          <button className="btn primario bloco" disabled={salvando}>Salvar</button>
        </form>
      </Folha>
      <Folha titulo="Trocar senha" aberta={senha} fechar={() => setSenha(false)}>
        <form className="form" onSubmit={salvarSenha}>
          <Campo rotulo="Nova senha" ajuda="Mínimo de 8 caracteres."><input className="entrada" type="password" autoComplete="new-password" value={nova} onChange={e => setNova(e.target.value)} /></Campo>
          <button className="btn primario bloco" disabled={salvando}>Alterar senha</button>
        </form>
      </Folha>
    </>
  )
}
