import { useState } from 'react'
import * as api from '#backend'
import Icone from '../components/Icone.jsx'
import { Campo } from '../components/ui.jsx'
import { TelaCentral } from './Login.jsx'

// Exigida quando o administrador cria o usuário ou redefine a senha
export default function TrocarSenhaObrigatoria({ perfil, aoConcluir }) {
  const [a, setA] = useState('')
  const [b, setB] = useState('')
  const [erro, setErro] = useState('')
  const [salvando, setSalvando] = useState(false)
  async function salvar(e) {
    e.preventDefault()
    if (a.length < 8) return setErro('A senha precisa ter pelo menos 8 caracteres.')
    if (a !== b) return setErro('As duas senhas não são iguais.')
    setSalvando(true); setErro('')
    try { await api.trocarSenha(a); aoConcluir(await api.meuPerfil()) }
    catch (err) { setErro(err.message) } finally { setSalvando(false) }
  }
  return (
    <TelaCentral subtitulo={`Olá, ${perfil.nome.split(' ')[0]}. Sua senha foi definida pelo administrador; crie uma senha pessoal para continuar.`}>
      <form className="form" onSubmit={salvar} style={{ marginTop: 18 }}>
        <h1>Crie sua senha</h1>
        {erro && <div className="aviso erro"><Icone nome="alerta" />{erro}</div>}
        <Campo rotulo="Nova senha" ajuda="Mínimo de 8 caracteres."><input className="entrada" type="password" autoComplete="new-password" value={a} onChange={e => setA(e.target.value)} /></Campo>
        <Campo rotulo="Repita a nova senha"><input className="entrada" type="password" autoComplete="new-password" value={b} onChange={e => setB(e.target.value)} /></Campo>
        <button className="btn primario bloco" disabled={salvando}>{salvando ? 'Salvando…' : 'Salvar e entrar'}</button>
        <button type="button" className="link-btn" onClick={() => api.sair()}>Sair</button>
      </form>
    </TelaCentral>
  )
}
