import { createContext, useCallback, useContext, useEffect, useRef, useState } from 'react'
import { NavLink, useNavigate } from 'react-router-dom'
import Icone from './Icone.jsx'
import { iniciais } from '../lib/formato.js'
import Logo from './Logo.jsx'

// ---------- Avisos rápidos (toast) ----------
const ToastCtx = createContext(() => {})
export function ToastProvider({ children }) {
  const [t, setT] = useState(null)
  const timer = useRef()
  const mostrar = useCallback((texto, tipo = 'ok') => {
    clearTimeout(timer.current)
    setT({ texto, tipo })
    timer.current = setTimeout(() => setT(null), tipo === 'erro' ? 5000 : 2600)
  }, [])
  return (
    <ToastCtx.Provider value={mostrar}>
      {children}
      {t && <div role="status" className={`toast ${t.tipo === 'erro' ? 'erro' : ''}`}>{t.texto}</div>}
    </ToastCtx.Provider>
  )
}
export const useToast = () => useContext(ToastCtx)

// ---------- Carregar dados ----------
export function useCarregar(fn, deps = []) {
  const [estado, setEstado] = useState({ dados: null, erro: null, carregando: true })
  const recarregar = useCallback(() => {
    let vivo = true
    setEstado(e => ({ ...e, carregando: true }))
    fn().then(d => vivo && setEstado({ dados: d, erro: null, carregando: false }))
        .catch(e => vivo && setEstado({ dados: null, erro: e, carregando: false }))
    return () => { vivo = false }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps)
  useEffect(recarregar, [recarregar])
  return { ...estado, recarregar }
}

// ---------- Estrutura ----------
export function Navegacao({ perfil, aoSair }) {
  // [rota, ícone, rótulo, só no computador?, só admin?]
  const itens = [
    ['/', 'inicio', 'Início'],
    ['/processos', 'processos', 'Processos'],
    ['/pesquisa', 'busca', 'Buscar processos', true],
    ['/prazos', 'relogio', 'Prazos'],
    ['/audiencias', 'martelo', 'Audiências'],
    ['/clientes', 'clientes', 'Clientes', true],
    ['/suspensoes', 'calendario', 'Suspensões', true],
    ['/usuarios', 'usuarios', 'Usuários', true, true],
    ['/ajustes', 'engrenagem', 'Ajustes'],
  ].filter(i => !i[4] || perfil?.admin)
  return (
    <nav className="tabbar" aria-label="Navegação principal">
      <div className="marca"><Logo variante="escuro" /></div>
      {itens.map(([to, ic, rot, soDesktop]) => (
        <NavLink key={to} to={to} end={to === '/'} className={({ isActive }) => `${isActive ? 'ativo' : ''} ${soDesktop ? 'so-desktop' : ''}`}>
          <Icone nome={ic} />{rot}
        </NavLink>
      ))}
      {perfil && (
        <div className="menu-usuario">
          <span className="avatar">{iniciais(perfil.nome)}</span>
          <div className="quem"><b title={perfil.nome}>{perfil.nome}</b><span>OAB {perfil.oab_numero}/{perfil.oab_uf}{perfil.admin ? ' · Admin' : ''}</span></div>
          <button onClick={aoSair} aria-label="Sair do sistema" title="Sair"><Icone nome="sair" /></button>
        </div>
      )}
    </nav>
  )
}

export function Topo({ titulo, sub, voltar, acoes }) {
  const nav = useNavigate()
  return (
    <header className="topbar">
      {voltar && (
        <button className="icone-btn" onClick={() => (window.history.length > 1 ? nav(-1) : nav(voltar))} aria-label="Voltar">
          <Icone nome="voltar" />
        </button>
      )}
      <h1>{titulo}{sub && <span className="sub">{sub}</span>}</h1>
      {acoes}
    </header>
  )
}

export function Fab({ to, rotulo }) {
  const nav = useNavigate()
  return (
    <button className="fab" onClick={() => nav(to)}>
      <Icone nome="mais_add" />{rotulo}
    </button>
  )
}

export function Folha({ titulo, aberta, fechar, children }) {
  useEffect(() => {
    if (!aberta) return
    const esc = e => e.key === 'Escape' && fechar()
    document.addEventListener('keydown', esc)
    document.body.style.overflow = 'hidden'
    return () => { document.removeEventListener('keydown', esc); document.body.style.overflow = '' }
  }, [aberta, fechar])
  if (!aberta) return null
  return (
    <div className="veu" onClick={fechar}>
      <div className="folha" role="dialog" aria-modal="true" aria-label={titulo} onClick={e => e.stopPropagation()}>
        <div className="alca" />
        <h2>{titulo}</h2>
        {children}
      </div>
    </div>
  )
}

export function Vazio({ icone = 'processos', titulo, texto, children }) {
  return (
    <div className="vazio">
      <Icone nome={icone} />
      <h3>{titulo}</h3>
      {texto && <p>{texto}</p>}
      {children}
    </div>
  )
}

export function Carregando({ n = 4 }) {
  return <div className="carregando" aria-busy="true">{Array.from({ length: n }, (_, i) => <div key={i} className="esqueleto" />)}</div>
}

export function Erro({ erro, tentar }) {
  return (
    <div className="aviso erro" role="alert">
      <Icone nome="alerta" />
      <div>{erro?.message || 'Algo deu errado.'} {tentar && <button className="link-btn" onClick={tentar}>Tentar de novo</button>}</div>
    </div>
  )
}

export function Campo({ rotulo, obrigatorio, ajuda, erro, certo, children }) {
  return (
    <label className="campo">
      <span>{rotulo}{obrigatorio && <em> *</em>}</span>
      {children}
      {erro ? <small className="erro">{erro}</small> : certo ? <small className="certo">{certo}</small> : ajuda ? <small>{ajuda}</small> : null}
    </label>
  )
}

export function Segmentado({ valor, opcoes, onChange, rotulo }) {
  return (
    <div className="segmentado" role="radiogroup" aria-label={rotulo}>
      {opcoes.map(([v, r]) => (
        <button type="button" key={v} role="radio" aria-checked={valor === v} className={valor === v ? 'ativo' : ''} onClick={() => onChange(v)}>{r}</button>
      ))}
    </div>
  )
}

export function Avatares({ advogados = [] }) {
  return (
    <span className="avatares" title={advogados.map(a => a.nome).join(', ')}>
      {advogados.map(a => <span key={a.id} className="avatar">{iniciais(a.nome)}</span>)}
    </span>
  )
}
