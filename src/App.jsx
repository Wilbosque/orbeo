import { createContext, useContext, useEffect, useState } from 'react'
import { HashRouter, Route, Routes, Navigate } from 'react-router-dom'
import * as api from '#backend'
import { Navegacao, ToastProvider } from './components/ui.jsx'
import Icone from './components/Icone.jsx'
import Login from './pages/Login.jsx'
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
import Saude from './pages/Saude.jsx'
import Audiencias from './pages/Audiencias.jsx'
import Prazos from './pages/Prazos.jsx'
import Usuarios from './pages/Usuarios.jsx'
import Pesquisa from './pages/Pesquisa.jsx'
import Novos from './pages/Novos.jsx'
import Escritorios from './pages/Escritorios.jsx'
import Notificacoes from './pages/Notificacoes.jsx'
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
    api.meuPerfil().then(async p => {
      // Espaço em uso saiu (escritório desativado ou vínculo removido): passa para outro espaço ativo
      if (p?.espacos?.length && !p.atual) { await api.trocarEspaco(p.espacos[0].id); p = await api.meuPerfil() }
      setPerfil(p)
    }).catch(() => setPerfil(null))
  }, [userId])

  // Estagiário: esconde botões de cadastro/edição (o banco também bloqueia)
  useEffect(() => { document.body.classList.toggle('estagiario', perfil?.papel === 'estagiario' || Boolean(perfil?.observador)) }, [perfil?.papel, perfil?.observador])

  let conteudo
  if (sessao === undefined || (sessao && perfil === undefined)) conteudo = <div className="login" aria-busy="true" />
  else if (!sessao) conteudo = <Login />
  else if (!perfil) conteudo = (
    <TelaCentral subtitulo="Seu cadastro ainda não foi concluído. Peça ao sócio administrador do escritório para criar o seu usuário.">
      <button className="btn bloco" style={{ marginTop: 18 }} onClick={() => api.sair()}>Sair</button>
    </TelaCentral>
  )
  else if (perfil.espacos && !perfil.espacos.length) conteudo = (
    <TelaCentral subtitulo="Você não está mais em nenhum escritório ativo do Orbeo. Fale com o sócio administrador ou com o suporte.">
      <button className="btn bloco" style={{ marginTop: 18 }} onClick={() => api.sair()}>Sair</button>
    </TelaCentral>
  )
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
            {perfil.observador && (
              <div className="faixa-leitura">
                <Icone nome="info" width="18" height="18" />
                <div style={{ flex: 1 }}><b>Modo leitura</b> · você está vendo {perfil.atual?.tipo === 'autonomo' ? 'o espaço autônomo' : 'o escritório'} <b>{perfil.atual?.nome}</b>. Nada pode ser alterado.</div>
                <button className="btn pequeno" onClick={async () => { const meu = perfil.espacos?.[0]; if (meu) { await api.trocarEspaco(meu.id); window.location.hash = '#/'; window.location.reload() } }}>Voltar ao meu espaço</button>
              </div>
            )}
            <Routes>
              <Route path="/" element={<Inicio />} />
              <Route path="/processos" element={<Processos />} />
              <Route path="/processos/novo" element={<ProcessoForm />} />
              <Route path="/pesquisa" element={<Pesquisa />} />
              <Route path="/novos" element={<Novos />} />
              <Route path="/processos/:id" element={<ProcessoDetalhe />} />
              <Route path="/processos/:id/editar" element={<ProcessoForm />} />
              <Route path="/audiencias" element={<Audiencias />} />
              <Route path="/prazos" element={<Prazos />} />
              <Route path="/clientes" element={<Clientes />} />
              <Route path="/clientes/novo" element={<ClienteForm />} />
              <Route path="/clientes/:id" element={<ClienteDetalhe />} />
              <Route path="/clientes/:id/editar" element={<ClienteForm />} />
              <Route path="/ajustes" element={<Ajustes />} />
              <Route path="/notificacoes" element={<Notificacoes />} />
              <Route path="/suspensoes" element={<Suspensoes />} />
              <Route path="/ajustes/fontes" element={<Fontes />} />
              <Route path="/ajustes/saude" element={<Saude />} />
              <Route path="/usuarios" element={perfil.admin ? <Usuarios /> : <Navigate to="/" replace />} />
              <Route path="/escritorios" element={perfil.dono ? <Escritorios /> : <Navigate to="/" replace />} />
              <Route path="*" element={<Navigate to="/" replace />} />
            </Routes>
          </main>
        </div>
      </HashRouter>
    </PerfilCtx.Provider>
  )
  return <ToastProvider>{conteudo}</ToastProvider>
}
