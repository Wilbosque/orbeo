import { useState } from 'react'
import * as api from '#backend'
import { usePerfil } from '../App.jsx'
import Icone from '../components/Icone.jsx'
import { Campo, Carregando, Erro, Folha, Topo, useCarregar, useToast } from '../components/ui.jsx'
import { UFS, iniciais } from '../lib/formato.js'
import Oabs from '../components/Oabs.jsx'
import { PAPEIS } from '../components/Prazos.jsx'

function quando(iso) {
  if (!iso) return 'Nunca entrou'
  const d = new Date(iso), dias = Math.floor((Date.now() - d) / 86400000)
  return dias <= 0 ? 'Último acesso hoje' : dias === 1 ? 'Último acesso ontem' : `Último acesso há ${dias} dias`
}

function SenhaGerada({ senha, email, fechar }) {
  const toast = useToast()
  const copiar = async () => { try { await navigator.clipboard.writeText(senha); toast('Senha copiada.') } catch { toast('Copie manualmente.', 'erro') } }
  return (
    <div className="form">
      <div className="aviso info"><Icone nome="cadeado" /><div>Envie esta senha para <b>{email}</b> por um canal seguro. Ela só aparece agora. No primeiro acesso, o sistema pede para criar uma senha pessoal.</div></div>
      <div className="senha-gerada mono">{senha}</div>
      <button className="btn primario bloco" onClick={copiar}><Icone nome="copiar" />Copiar senha</button>
      <button className="btn bloco" onClick={fechar}>Concluir</button>
    </div>
  )
}

export const DESC_PAPEL = {
  admin: 'Sócio administrador: cria e gerencia os usuários do escritório e decide quem tem visão geral.',
  advogado: 'Cadastra clientes, processos, prazos e audiências. Vê os próprios processos (ou todos, se tiver visão geral).',
  estagiario: 'Consulta os processos e dá cumprimento, com observação, aos prazos designados a ele. Não cadastra prazos.',
}
export function CamposAcesso({ papel, visao, setPapel, setVisao }) {
  return (
    <>
      <Campo rotulo="Papel no escritório" ajuda={DESC_PAPEL[papel]}>
        <select className="entrada" value={papel} onChange={e => setPapel(e.target.value)}>
          {Object.entries(PAPEIS).map(([v, t]) => <option key={v} value={v}>{t}</option>)}
        </select>
      </Campo>
      <label className="caixa-check">
        <input type="checkbox" checked={visao} onChange={e => setVisao(e.target.checked)} />
        <div><b>Visão geral dos processos do escritório</b><span>Vê todos os processos e clientes do escritório, não só os vinculados a ele. Sem isso, vale o sigilo entre advogados.</span></div>
      </label>
    </>
  )
}

function NovoUsuario({ aoCriar }) {
  const [f, setF] = useState({ nome: '', email: '', oab_numero: '', oab_uf: 'BA', papel: 'advogado', visao_geral: false })
  const [erro, setErro] = useState('')
  const [salvando, setSalvando] = useState(false)
  const set = k => e => setF({ ...f, [k]: e.target.type === 'checkbox' ? e.target.checked : e.target.value })
  async function salvar(e) {
    e.preventDefault(); setErro('')
    if (!f.nome.trim() || !f.email.trim() || !f.oab_numero.trim()) return setErro('Preencha nome, e-mail e OAB.')
    setSalvando(true)
    try { const r = await api.adminCriar({ ...f, email: f.email.trim().toLowerCase(), nome: f.nome.trim() }); aoCriar(r.senha_temporaria, f.email) }
    catch (err) { setErro(err.message) } finally { setSalvando(false) }
  }
  return (
    <form className="form" onSubmit={salvar}>
      {erro && <div className="aviso erro"><Icone nome="alerta" />{erro}</div>}
      <Campo rotulo="Nome completo" obrigatorio><input className="entrada" value={f.nome} onChange={set('nome')} /></Campo>
      <Campo rotulo="E-mail de acesso" obrigatorio><input className="entrada" type="email" inputMode="email" value={f.email} onChange={set('email')} /></Campo>
      <div className="duas">
        <Campo rotulo="Nº da OAB" obrigatorio><input className="entrada mono" inputMode="numeric" value={f.oab_numero} onChange={set('oab_numero')} /></Campo>
        <Campo rotulo="UF"><select className="entrada" value={f.oab_uf} onChange={set('oab_uf')}>{UFS.map(u => <option key={u}>{u}</option>)}</select></Campo>
      </div>
      <CamposAcesso papel={f.papel} visao={f.visao_geral} setPapel={v => setF({ ...f, papel: v })} setVisao={v => setF({ ...f, visao_geral: v })} />
      <button className="btn primario bloco" disabled={salvando}>{salvando ? 'Criando…' : 'Criar usuário'}</button>
    </form>
  )
}

export default function Usuarios() {
  const { perfil } = usePerfil()
  const toast = useToast()
  const r = useCarregar(() => api.adminListar(), [])
  const oabs = useCarregar(() => api.listarOabs(), [])
  const oabsDe = id => (oabs.dados || []).filter(o => o.advogado_id === id).sort((a, b) => Number(b.principal) - Number(a.principal))
  const [novo, setNovo] = useState(false)
  const [senha, setSenha] = useState(null)       // {senha, email}
  const [sel, setSel] = useState(null)
  const [ocupado, setOcupado] = useState(false)

  async function agir(fn, msg) {
    setOcupado(true)
    try { const res = await fn(); if (msg) toast(msg); r.recarregar(); return { res } }
    catch (e) { toast(e.message, 'erro'); return null } finally { setOcupado(false) }
  }
  const lista = r.dados || []
  const ativos = lista.filter(u => u.ativo).length

  return (
    <>
      <Topo titulo="Usuários" sub={r.dados ? `${ativos} ativo${ativos === 1 ? '' : 's'} · ${lista.length} no total` : ' '} />
      <div className="aviso info" style={{ marginBottom: 12 }}>
        <Icone nome="info" />
        <div>Cada advogado vê só os processos em que está incluído. Quem tem <b>visão geral</b> vê todos os processos do escritório. Você decide isso em cada usuário, inclusive no seu.</div>
      </div>
      {r.erro && <Erro erro={r.erro} tentar={r.recarregar} />}
      {r.carregando && !r.dados ? <Carregando n={2} /> : (
        <div className="lista grade">
          {lista.map(u => (
            <button key={u.id} className="cartao usuario" onClick={() => setSel(u)} style={{ opacity: u.ativo ? 1 : .6 }}>
              <span className="avatar grande">{iniciais(u.nome || u.email)}</span>
              <div style={{ flex: 1, minWidth: 0 }}>
                <h3 style={{ margin: 0 }}>{u.nome || u.email}{u.id === perfil.id && <span className="muted" style={{ fontWeight: 400 }}> (você)</span>}</h3>
                <div className="linha">{u.email}</div>
                <div className="cartao-rodape" style={{ marginTop: 6 }}>
                  {oabsDe(u.id).length ? oabsDe(u.id).map(o => <span key={o.id} className="selo">OAB {o.numero}/{o.uf}</span>)
                    : u.oab_numero && <span className="selo">OAB {u.oab_numero}/{u.oab_uf}</span>}
                  <span className={`selo ${u.papel === 'admin' ? 'violeta' : ''}`}>{PAPEIS[u.papel || (u.admin ? 'admin' : 'advogado')]}</span>
                  {u.visao_geral && <span className="selo">Visão geral</span>}
                  {!u.ativo && <span className="selo perigo">Desativado</span>}
                  {u.trocar_senha && u.ativo && <span className="selo alerta">Senha provisória</span>}
                </div>
                <div className="linha faint" style={{ marginTop: 4, fontSize: '.78rem' }}>{quando(u.ultimo_acesso)}</div>
              </div>
              <Icone nome="seta" width="18" height="18" />
            </button>
          ))}
        </div>
      )}
      <button className="fab" onClick={() => setNovo(true)}><Icone nome="mais_add" />Usuário</button>

      <Folha titulo={senha ? 'Senha provisória' : 'Novo usuário'} aberta={novo || Boolean(senha)} fechar={() => { setNovo(false); setSenha(null) }}>
        {senha ? <SenhaGerada senha={senha.senha} email={senha.email} fechar={() => { setSenha(null); setNovo(false) }} />
          : <NovoUsuario aoCriar={(s, email) => { setSenha({ senha: s, email }); r.recarregar() }} />}
      </Folha>

      <Folha titulo={sel?.nome || sel?.email || ''} aberta={Boolean(sel)} fechar={() => setSel(null)}>
        {sel && (
          <div className="form">
            <div className="muted" style={{ marginTop: -8 }}>{sel.email}</div>
            {!sel.sem_perfil && (
              <>
                <b style={{ fontSize: '.92rem' }}>OABs</b>
                <Oabs advogadoId={sel.id} aoMudar={() => { oabs.recarregar(); r.recarregar() }} />
              </>
            )}
            {sel.id === perfil.id ? (
              <>
                <div className="aviso info"><Icone nome="info" />Este é o seu usuário. Para trocar sua senha, use Ajustes → Trocar senha.</div>
                <label className="caixa-check">
                  <input type="checkbox" checked={Boolean(sel.visao_geral)} disabled={ocupado}
                    onChange={async e => { const v = e.target.checked; if (await agir(() => api.adminVisaoGeral(sel.id, v), v ? 'Visão geral ligada.' : 'Visão geral desligada.')) setSel({ ...sel, visao_geral: v }) }} />
                  <div><b>Minha visão geral dos processos do escritório</b><span>Ligada, você vê todos os processos e clientes do escritório.</span></div>
                </label>
              </>
            ) : (
              <>
                <button className="btn bloco" disabled={ocupado} onClick={async () => {
                  const res = await agir(() => api.adminRedefinirSenha(sel.id))
                  if (res?.res?.senha_temporaria) { setSenha({ senha: res.res.senha_temporaria, email: sel.email }); setSel(null) }
                }}><Icone nome="cadeado" />Gerar nova senha provisória</button>
                <CamposAcesso papel={sel.papel || (sel.admin ? 'admin' : 'advogado')} visao={Boolean(sel.visao_geral)}
                  setPapel={async v => { if (await agir(() => api.adminPapel(sel.id, v), `Agora é ${PAPEIS[v].toLowerCase()}.`)) setSel({ ...sel, papel: v, admin: v === 'admin' }) }}
                  setVisao={async v => { if (await agir(() => api.adminVisaoGeral(sel.id, v), v ? 'Visão geral ligada.' : 'Visão geral desligada: vale o sigilo.')) setSel({ ...sel, visao_geral: v }) }} />
                <button className="btn bloco" disabled={ocupado} onClick={async () => {
                  if (sel.ativo && !window.confirm(`Desativar o acesso de ${sel.nome || sel.email}? Ele(a) não conseguirá entrar, mas nada é apagado.`)) return
                  if (await agir(() => api.adminAtivar(sel.id, !sel.ativo), sel.ativo ? 'Acesso desativado.' : 'Acesso reativado.')) setSel(null)
                }}><Icone nome={sel.ativo ? 'sair' : 'certo'} />{sel.ativo ? 'Desativar acesso' : 'Reativar acesso'}</button>
                <button className="btn perigo bloco" disabled={ocupado} onClick={async () => {
                  if (!window.confirm(`Excluir definitivamente ${sel.nome || sel.email}? Essa ação não pode ser desfeita.`)) return
                  const ok = await agir(() => api.adminExcluir(sel.id), 'Usuário excluído.')
                  if (ok) setSel(null)
                }}><Icone nome="lixo" />Excluir usuário</button>
                <small className="muted">A exclusão só é permitida quando não há processos ou clientes que só este advogado enxerga. Nesses casos, desative o acesso.</small>
              </>
            )}
          </div>
        )}
      </Folha>
    </>
  )
}
