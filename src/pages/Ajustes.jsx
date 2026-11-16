import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import * as api from '#backend'
import { usePerfil } from '../App.jsx'
import Icone from '../components/Icone.jsx'
import { Campo, Folha, Topo, useToast } from '../components/ui.jsx'
import { UFS, iniciais } from '../lib/formato.js'
import { ativarPush, desativarPush, estadoPush } from '../lib/push.js'

const AVISOS = [
  ['relogio', 'Prazos que vencem hoje e amanhã', 'resumo às 7h'],
  ['martelo', 'Audiências', 'na véspera, às 18h, e 2 horas antes'],
  ['processos', 'Publicações novas no DJEN', 'assim que a consulta encontrar'],
  ['radar', 'Sugestões para confirmar', 'uma vez por dia, às 8h'],
]

function Notificacoes() {
  const toast = useToast()
  const [estado, setEstado] = useState(null)
  const [ocupado, setOcupado] = useState(false)
  const recarregar = () => estadoPush().then(setEstado).catch(() => setEstado('sem_suporte'))
  useEffect(() => { recarregar() }, [])
  async function fazer(fn, msg) {
    setOcupado(true)
    try { await fn(); if (msg) toast(msg) } catch (e) { toast(e.message, 'erro') } finally { setOcupado(false); recarregar() }
  }
  return (
    <div className="cartao notif">
      <div style={{ display: 'flex', gap: 12, alignItems: 'center' }}>
        <Icone nome="sino" width="22" height="22" />
        <b style={{ flex: 1 }}>Notificações neste aparelho</b>
        {estado === 'ligado' && <span className="selo violeta">Ativas</span>}
      </div>
      {estado === 'instalar' && (
        <div className="aviso info" style={{ marginTop: 10 }}><Icone nome="info" />
          <div>No iPhone, as notificações só funcionam com o Orbeo salvo na tela de início. No <b>Safari</b>, toque em <b>Compartilhar</b> → <b>Adicionar à Tela de Início</b>, abra o Orbeo pelo ícone e volte aqui.</div>
        </div>
      )}
      {estado === 'sem_suporte' && <p className="muted" style={{ marginBottom: 0 }}>Este navegador não recebe notificações. No iPhone, use o Safari (iOS 16.4 ou mais novo); no Android, o Chrome.</p>}
      {estado === 'bloqueado' && (
        <div className="aviso alerta" style={{ marginTop: 10 }}><Icone nome="alerta" />
          <div>As notificações estão bloqueadas para o Orbeo. Libere em <b>Ajustes do aparelho → Notificações → Orbeo</b> (no Android, nas permissões do site no Chrome) e volte aqui.</div>
        </div>
      )}
      {(estado === 'desligado' || estado === 'ligado') && (
        <>
          <ul className="avisos-lista">{AVISOS.map(([ic, t, q]) => <li key={t}><Icone nome={ic} width="16" height="16" /><span><b>{t}</b> · {q}</span></li>)}</ul>
          <small className="muted" style={{ display: 'block', marginBottom: 10 }}>Você só recebe avisos dos seus processos.</small>
          {estado === 'desligado'
            ? <button className="btn primario bloco" disabled={ocupado} onClick={() => fazer(ativarPush, 'Notificações ativadas neste aparelho.')}><Icone nome="sino" />{ocupado ? 'Ativando…' : 'Ativar notificações'}</button>
            : (
              <div className="duas">
                <button className="btn" disabled={ocupado} onClick={() => fazer(api.pushTeste, 'Aviso de teste enviado. Deve chegar em instantes.')}>Enviar teste</button>
                <button className="btn perigo" disabled={ocupado} onClick={() => fazer(desativarPush, 'Notificações desativadas neste aparelho.')}>Desativar</button>
              </div>
            )}
        </>
      )}
    </div>
  )
}

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

      <div className="secao"><h2>Notificações</h2></div>
      <Notificacoes />

      <div className="secao"><h2>Conta</h2></div>
      <div className="lista">
        <button className="cartao" onClick={() => { setF(perfil); setEditar(true) }} style={{ display: 'flex', gap: 12, alignItems: 'center' }}><Icone nome="usuario" width="22" height="22" /><b style={{ flex: 1 }}>Meus dados e OAB</b><Icone nome="seta" width="18" height="18" /></button>
        <button className="cartao" onClick={() => setSenha(true)} style={{ display: 'flex', gap: 12, alignItems: 'center' }}><Icone nome="engrenagem" width="22" height="22" /><b style={{ flex: 1 }}>Trocar senha</b><Icone nome="seta" width="18" height="18" /></button>
      </div>

      <div className="secao"><h2>Cadastros e prazos</h2></div>
      <div className="lista">
        <Link to="/clientes" className="cartao so-celular" style={{ display: 'flex', gap: 12, alignItems: 'center' }}><Icone nome="clientes" width="22" height="22" /><b style={{ flex: 1 }}>Clientes</b><Icone nome="seta" width="18" height="18" /></Link>
        <Link to="/suspensoes" className="cartao" style={{ display: 'flex', gap: 12, alignItems: 'center' }}><Icone nome="calendario" width="22" height="22" /><b style={{ flex: 1 }}>Suspensões de prazo</b><Icone nome="seta" width="18" height="18" /></Link>
        {perfil.admin && <Link to="/usuarios" className="cartao" style={{ display: 'flex', gap: 12, alignItems: 'center' }}><Icone nome="usuarios" width="22" height="22" /><b style={{ flex: 1 }}>Usuários do sistema</b><span className="selo violeta">Admin</span><Icone nome="seta" width="18" height="18" /></Link>}
        <Link to="/ajustes/saude" className="cartao" style={{ display: 'flex', gap: 12, alignItems: 'center' }}><Icone nome="saude" width="22" height="22" /><b style={{ flex: 1 }}>Saúde das consultas</b><Icone nome="seta" width="18" height="18" /></Link>
        <Link to="/ajustes/fontes" className="cartao" style={{ display: 'flex', gap: 12, alignItems: 'center' }}><Icone nome="radar" width="22" height="22" /><b style={{ flex: 1 }}>Fontes dos diários (varredura)</b><Icone nome="seta" width="18" height="18" /></Link>
      </div>

      <div className="secao"><h2>Em breve</h2></div>
      <div className="lista">
        {[['engrenagem', 'Configurações das consultas']].map(([ic, t]) => (
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
          <small className="muted">A OAB aparece no seu cadastro e para os colegas do escritório.</small>
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
