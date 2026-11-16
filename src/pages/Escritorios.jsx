import { useState } from 'react'
import * as api from '#backend'
import Icone from '../components/Icone.jsx'
import { Campo, Carregando, Erro, Folha, Topo, Vazio, useCarregar, useToast } from '../components/ui.jsx'
import { UFS } from '../lib/formato.js'
import Saida from '../components/Saida.jsx'
import { PAPEIS } from '../components/Prazos.jsx'

function NovoAutonomo({ aoCriar }) {
  const [f, setF] = useState({ nome: '', email: '', oab_numero: '', oab_uf: 'BA' })
  const [erro, setErro] = useState(''); const [salvando, setSalvando] = useState(false)
  const set = k => e => setF({ ...f, [k]: e.target.value })
  async function salvar(e) {
    e.preventDefault(); setErro('')
    if (!f.nome.trim() || !f.email.trim() || !f.oab_numero.trim()) return setErro('Preencha todos os campos.')
    setSalvando(true)
    try { const r = await api.criarAutonomo({ ...f, email: f.email.trim().toLowerCase() }); aoCriar(r, f.email) } catch (err) { setErro(err.message) } finally { setSalvando(false) }
  }
  return (
    <form className="form" onSubmit={salvar}>
      {erro && <div className="aviso erro"><Icone nome="alerta" />{erro}</div>}
      <small className="muted">Advogado sem escritório: ele tem um espaço só dele, com os próprios processos. Depois pode ser incluído em escritórios, mantendo o espaço autônomo.</small>
      <Campo rotulo="Nome completo" obrigatorio><input className="entrada" value={f.nome} onChange={set('nome')} /></Campo>
      <Campo rotulo="E-mail de acesso" obrigatorio><input className="entrada" type="email" inputMode="email" value={f.email} onChange={set('email')} /></Campo>
      <div className="duas">
        <Campo rotulo="Nº da OAB" obrigatorio><input className="entrada mono" inputMode="numeric" value={f.oab_numero} onChange={set('oab_numero')} /></Campo>
        <Campo rotulo="UF"><select className="entrada" value={f.oab_uf} onChange={set('oab_uf')}>{UFS.map(u => <option key={u}>{u}</option>)}</select></Campo>
      </div>
      <button className="btn primario bloco" disabled={salvando}>{salvando ? 'Criando…' : 'Criar advogado autônomo'}</button>
    </form>
  )
}

// Membros de um escritório: incluir advogado existente e remanejar para outro escritório
function Membros({ esc, escritorios, aoMudar }) {
  const toast = useToast()
  const r = useCarregar(() => api.membrosEscritorio(esc.id), [esc.id])
  const [incluir, setIncluir] = useState(null)
  const [mover, setMover] = useState(null)       // { adv, para, papel, visao_geral, etapa }
  const destinos = escritorios.filter(e => e.id !== esc.id && e.ativo && e.tipo === 'escritorio')
  async function salvarInclusao() {
    try { await api.incluirExistente({ ...incluir, escritorio_id: esc.id }); toast('Advogado incluído no escritório.'); setIncluir(null); r.recarregar(); aoMudar() }
    catch (e) { toast(e.message, 'erro') }
  }
  if (mover?.etapa === 2) return (
    <>
      <button className="link-btn" onClick={() => setMover({ ...mover, etapa: 1 })}>← Voltar</button>
      <Saida alvo={mover.adv} modo="remanejar" equipe={r.dados || []} rotulo={`Remanejar para ${destinos.find(d => d.id === mover.para)?.nome}`}
        carregarPrevia={() => api.adminPreviaSaida(mover.adv.id, esc.id)}
        aoConfirmar={async d => {
          await api.remanejarAdvogado({ id: mover.adv.id, de: esc.id, para: mover.para, papel: mover.papel, visao_geral: mover.visao_geral, sucessor_id: d.sucessor_id, levar: d.levar })
          toast('Advogado remanejado.'); setMover(null); r.recarregar(); aoMudar()
        }} />
    </>
  )
  if (mover) return (
    <div className="form">
      <b>Remanejar {mover.adv.nome}</b>
      <Campo rotulo="Para o escritório">
        <select className="entrada" value={mover.para} onChange={e => setMover({ ...mover, para: e.target.value })}>
          <option value="">Selecione…</option>
          {destinos.map(d => <option key={d.id} value={d.id}>{d.nome}</option>)}
        </select>
      </Campo>
      <Campo rotulo="Papel no novo escritório">
        <select className="entrada" value={mover.papel} onChange={e => setMover({ ...mover, papel: e.target.value })}>
          {Object.entries(PAPEIS).map(([v, t]) => <option key={v} value={v}>{t}</option>)}
        </select>
      </Campo>
      <label className="caixa-check"><input type="checkbox" checked={mover.visao_geral} onChange={e => setMover({ ...mover, visao_geral: e.target.checked })} />
        <div><b>Visão geral no novo escritório</b><span>Vê todos os processos de lá.</span></div></label>
      <button className="btn primario bloco" disabled={!mover.para} onClick={() => setMover({ ...mover, etapa: 2 })}>Continuar</button>
      <button className="btn bloco" onClick={() => setMover(null)}>Cancelar</button>
    </div>
  )
  return (
    <div className="form">
      {r.carregando && !r.dados ? <Carregando n={2} /> : (
        <div className="lista">
          {(r.dados || []).map(a => (
            <div key={a.id} className="cartao" style={{ display: 'flex', gap: 10, alignItems: 'center', padding: '10px 14px', opacity: a.ativo === false ? .6 : 1 }}>
              <div style={{ flex: 1, minWidth: 0 }}><b>{a.nome}</b><div className="linha">{PAPEIS[a.papel]}{a.visao_geral ? ' · visão geral' : ''} · {a.email}</div></div>
              {esc.tipo === 'escritorio' && destinos.length > 0 && <button className="btn pequeno" onClick={() => setMover({ adv: a, para: '', papel: a.papel, visao_geral: false, etapa: 1 })}>Remanejar</button>}
            </div>
          ))}
        </div>
      )}
      {incluir ? (
        <div className="form cartao">
          <b>Incluir advogado que já usa o Orbeo</b>
          <Campo rotulo="E-mail de acesso dele"><input className="entrada" type="email" value={incluir.email} onChange={e => setIncluir({ ...incluir, email: e.target.value })} /></Campo>
          <Campo rotulo="Papel"><select className="entrada" value={incluir.papel} onChange={e => setIncluir({ ...incluir, papel: e.target.value })}>
            {Object.entries(PAPEIS).map(([v, t]) => <option key={v} value={v}>{t}</option>)}</select></Campo>
          <label className="caixa-check"><input type="checkbox" checked={incluir.visao_geral} onChange={e => setIncluir({ ...incluir, visao_geral: e.target.checked })} />
            <div><b>Visão geral</b><span>Vê todos os processos deste escritório.</span></div></label>
          <small className="muted">Ele continua nos espaços que já tem (outros escritórios ou autônomo) e troca entre eles pelo seletor.</small>
          <button className="btn primario bloco" disabled={!incluir.email.trim()} onClick={salvarInclusao}>Incluir</button>
          <button className="btn bloco" onClick={() => setIncluir(null)}>Cancelar</button>
        </div>
      ) : esc.tipo === 'escritorio' && <button className="btn bloco" onClick={() => setIncluir({ email: '', papel: 'advogado', visao_geral: false })}><Icone nome="mais_add" />Incluir advogado existente</button>}
    </div>
  )
}

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
  const [autonomo, setAutonomo] = useState(false)
  const [membros, setMembros] = useState(null)
  const lista = (r.dados || []).filter(e => e.tipo !== 'autonomo')
  async function verLeitura(e) {
    try { await api.trocarEspaco(e.id); window.location.hash = '#/processos'; window.location.reload() } catch (err) { toast(err.message, 'erro') }
  }
  async function ativar(e) {
    if (e.ativo && !window.confirm(`Desativar ${e.nome}? Todos os usuários dele perdem o acesso (nada é apagado).`)) return
    try { await api.ativarEscritorio(e.id, !e.ativo); toast(e.ativo ? 'Escritório desativado.' : 'Escritório reativado.'); r.recarregar() } catch (err) { toast(err.message, 'erro') }
  }
  const copiar = async t => { try { await navigator.clipboard.writeText(t); toast('Senha copiada.') } catch { toast('Copie manualmente.', 'erro') } }
  return (
    <>
      <Topo titulo="Escritórios" sub="Área do dono da plataforma"
        acoes={<button className="btn pequeno" onClick={() => setAutonomo(true)}><Icone nome="usuario" />Advogado autônomo</button>} />
      <div className="aviso info" style={{ marginBottom: 12 }}><Icone nome="cadeado" />
        <div>Cada escritório só enxerga os próprios dados. Como dono da plataforma, você pode abrir qualquer escritório em <b>modo leitura</b> (ver, sem alterar). Advogados autônomos ficam em Usuários → Autônomos.</div>
      </div>
      {r.erro && <Erro erro={r.erro} tentar={r.recarregar} />}
      {r.carregando && !r.dados ? <Carregando n={2} /> : lista.length ? (
        <div className="lista grade">
          {lista.map(e => (
            <div key={e.id} className="cartao" style={{ opacity: e.ativo ? 1 : .6 }}>
              <div className="cartao-topo"><h3 style={{ margin: 0 }}>{e.nome}</h3>
                {e.tipo === 'autonomo' && <span className="selo">Autônomo</span>}{!e.ativo && <span className="selo perigo">Desativado</span>}</div>
              <div className="linha">{e.usuarios} usuário{e.usuarios === 1 ? '' : 's'} · {e.processos} processo{e.processos === 1 ? '' : 's'} · desde {new Date(e.criado_em).toLocaleDateString('pt-BR')}</div>
              <div style={{ display: 'flex', gap: 8, marginTop: 10 }}>
                <button className="btn pequeno" onClick={() => setMembros(e)}><Icone nome="usuarios" />Membros</button>
                <button className="btn pequeno" onClick={() => verLeitura(e)}><Icone nome="processos" />Ver processos</button>
                <button className="btn pequeno" onClick={() => ativar(e)}>{e.ativo ? 'Desativar' : 'Reativar'}</button>
              </div>
            </div>
          ))}
        </div>
      ) : <Vazio icone="balanca" titulo="Nenhum escritório" texto="Crie o primeiro pelo botão abaixo." />}
      <button className="fab" onClick={() => setNovo(true)}><Icone nome="mais_add" />Escritório</button>
      <Folha titulo={criado ? 'Acesso criado' : 'Novo escritório'} aberta={novo || Boolean(criado)} fechar={() => { setNovo(false); setCriado(null) }}>
        {criado ? (
          <div className="form">
            <div className="aviso info"><Icone nome="cadeado" /><div>Envie a senha provisória para <b>{criado.email}</b> por um canal seguro. Ela só aparece agora; no primeiro acesso, o sistema pede uma senha pessoal.</div></div>
            <div className="senha-gerada mono">{criado.senha}</div>
            <button className="btn primario bloco" onClick={() => copiar(criado.senha)}><Icone nome="copiar" />Copiar senha</button>
            <button className="btn bloco" onClick={() => { setCriado(null); setNovo(false) }}>Concluir</button>
          </div>
        ) : <NovoEscritorio aoCriar={(res, f) => { setCriado({ senha: res.senha_temporaria, email: f.admin_email }); setNovo(false); r.recarregar() }} />}
      </Folha>
      <Folha titulo="Novo advogado autônomo" aberta={autonomo} fechar={() => setAutonomo(false)}>
        {autonomo && <NovoAutonomo aoCriar={(res, email) => { setAutonomo(false); setCriado({ senha: res.senha_temporaria, email }); r.recarregar() }} />}
      </Folha>
      <Folha titulo={membros ? `Membros · ${membros.nome}` : ''} aberta={Boolean(membros)} fechar={() => setMembros(null)}>
        {membros && <Membros esc={membros} escritorios={lista} aoMudar={r.recarregar} />}
      </Folha>
    </>
  )
}
