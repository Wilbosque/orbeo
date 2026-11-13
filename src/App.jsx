import { createContext, useContext, useEffect, useState } from 'react'
import { HashRouter, Route, Routes, Navigate } from 'react-router-dom'
import * as api from '#backend'
import { Navegacao, ToastProvider } from './components/ui.jsx'
import Login from './pages/Login.jsx'
import PrimeiroAcesso from './pages/PrimeiroAcesso.jsx'
import Inicio from './pages/Inicio.jsx'
import Clientes from './pages/Clientes.jsx'
import ClienteForm from './pages/ClienteForm.jsx'
import ClienteDetalhe from './pages/ClienteDetalhe.jsx'
import Processos from './pages/Processos.jsx'
import ProcessoForm from './pages/ProcessoForm.jsx'
import ProcessoDetalhe from './pages/ProcessoDetalhe.jsx'
import Ajustes from './pages/Ajustes.jsx'
import Suspensoes from './pages/Suspensoes.jsx'
import Fontes from './pages/Fontes.jsx'
import Usuarios from './pages/Usuarios.jsx'
import TrocarSenhaObrigatoria from './pages/TrocarSenhaObrigatoria.jsx'
import { TelaCentral } from './pages/Login.jsx'

const PerfilCtx = createContext(null)
export const usePerfil = () => useContext(PerfilCtx)

export default function App() {
  const [sessao, setSessao] = useState(undefined)
  const [perfil, setPerfil] = useState(undefined)

  useEffect(() => {
    api.sessaoAtual().then(setSessao)
    return api.aoMudarSessao(setSessao)
  }, [])

  const userId = sessao?.user?.id
  useEffect(() => {
    if (!userId) { setPerfil(undefined); return }
    api.meuPerfil().then(setPerfil).catch(() => setPerfil(null))
  }, [userId])

  let conteudo
  if (sessao === undefined || (sessao && perfil === undefined)) conteudo = <div className="login" aria-busy="true" />
  else if (!sessao) conteudo = <Login />
  else if (!perfil) conteudo = <PrimeiroAcesso aoSalvar={setPerfil} />
  else if (perfil.ativo === false) conteudo = (
    <TelaCentral subtitulo="Seu acesso está desativado. Fale com o administrador do escritório.">
      <button className="btn bloco" style={{ marginTop: 18 }} onClick={() => api.sair()}>Sair</button>
    </TelaCentral>
  )
  else if (perfil.trocar_senha) conteudo = <TrocarSenhaObrigatoria perfil={perfil} aoConcluir={setPerfil} />
  else conteudo = (
    <PerfilCtx.Provider value={{ perfil, setPerfil, email: sessao.user.email }}>
      <HashRouter>
        <div className="app">
          <Navegacao perfil={perfil} aoSair={() => api.sair()} />
          <main className="main">
            <Routes>
              <Route path="/" element={<Inicio />} />
              <Route path="/processos" element={<Processos />} />
              <Route path="/processos/novo" element={<ProcessoForm />} />
              <Route path="/processos/:id" element={<ProcessoDetalhe />} />
              <Route path="/processos/:id/editar" element={<ProcessoForm />} />
              <Route path="/clientes" element={<Clientes />} />
              <Route path="/clientes/novo" element={<ClienteForm />} />
              <Route path="/clientes/:id" element={<ClienteDetalhe />} />
              <Route path="/clientes/:id/editar" element={<ClienteForm />} />
              <Route path="/ajustes" element={<Ajustes />} />
              <Route path="/suspensoes" element={<Suspensoes />} />
              <Route path="/ajustes/fontes" element={<Fontes />} />
              <Route path="/usuarios" element={perfil.admin ? <Usuarios /> : <Navigate to="/" replace />} />
              <Route path="*" element={<Navigate to="/" replace />} />
            </Routes>
          </main>
        </div>
      </HashRouter>
    </PerfilCtx.Provider>
  )
  return <ToastProvider>{conteudo}</ToastProvider>
}
