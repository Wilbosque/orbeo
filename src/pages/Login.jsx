import { useState } from 'react'
import * as api from '#backend'
import Icone from '../components/Icone.jsx'
import Logo from '../components/Logo.jsx'
import { Campo, useToast } from '../components/ui.jsx'

export function TelaCentral({ subtitulo, children }) {
  return (
    <div className="login">
      <div className="caixa">
        <div className="topo-login">
          <Logo />
          {subtitulo && <p>{subtitulo}</p>}
        </div>
        {children}
      </div>
    </div>
  )
}

export default function Login() {
  const [email, setEmail] = useState('')
  const [senha, setSenha] = useState('')
  const [ver, setVer] = useState(false)
  const [enviando, setEnviando] = useState(false)
  const [erro, setErro] = useState('')
  const toast = useToast()

  async function entrar(e) {
    e.preventDefault()
    setErro(''); setEnviando(true)
    try { await api.entrar(email.trim(), senha) }
    catch (err) { setErro(err.message); setSenha('') }
    finally { setEnviando(false) }
  }
  async function esqueci() {
    if (!email.trim()) { setErro('Digite seu e-mail para receber o link de nova senha.'); return }
    try { await api.recuperarSenha(email.trim()); toast('Enviamos um link de nova senha para o seu e-mail.') }
    catch (err) { setErro(err.message) }
  }

  return (
    <TelaCentral subtitulo="Processos, publicações e prazos do escritório">
      <form className="form" onSubmit={entrar} style={{ marginTop: 18 }}>
        {erro && <div className="aviso erro" role="alert"><Icone nome="alerta" />{erro}</div>}
        <Campo rotulo="E-mail">
          <input className="entrada" type="email" autoComplete="username" inputMode="email" value={email} onChange={e => setEmail(e.target.value)} required placeholder="voce@escritorio.com.br" />
        </Campo>
        <Campo rotulo="Senha">
          <div style={{ position: 'relative' }}>
            <input className="entrada" type={ver ? 'text' : 'password'} autoComplete="current-password" value={senha} onChange={e => setSenha(e.target.value)} required style={{ paddingRight: 84 }} />
            <button type="button" className="link-btn" onClick={() => setVer(!ver)} style={{ position: 'absolute', right: 14, top: 7 }}>{ver ? 'Ocultar' : 'Mostrar'}</button>
          </div>
        </Campo>
        <button className="btn primario bloco" disabled={enviando}>{enviando ? 'Entrando…' : 'Entrar'}</button>
        <button type="button" className="link-btn" onClick={esqueci}>Esqueci minha senha</button>
      </form>
      <div className="rodape-login"><Icone nome="cadeado" width="12" height="12" style={{ verticalAlign: -1 }} /> Acesso restrito aos advogados cadastrados</div>
    </TelaCentral>
  )
}
