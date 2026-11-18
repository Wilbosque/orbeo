import { useEffect, useRef, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import * as api from '#backend'
import { usePerfil } from '../App.jsx'
import Icone from '../components/Icone.jsx'
import { Carregando, Erro, Folha, Topo, Vazio, useCarregar, useToast } from '../components/ui.jsx'
import { MOTIVOS_BAIXA, POLOS, SITUACOES, data, iniciais, moeda, oabsTexto } from '../lib/formato.js'
import { Campo } from '../components/ui.jsx'
import { AudienciaForm, ItemAudiencia } from '../components/Audiencias.jsx'
import { CumprirForm, ItemPrazoLista, PainelPrazo } from '../components/Prazos.jsx'
import { INSTANCIAS, RITOS, prazoNoTexto } from '../lib/prazo.js'

const diasDesde = iso => Math.floor((Date.now() - new Date(iso)) / 86400000)

function haQuanto(iso) {
  if (!iso) return null
  const min = Math.round((Date.now() - new Date(iso)) / 60000)
  if (min < 1) return 'agora há pouco'
  if (min < 60) return `há ${min} min`
  const h = Math.round(min / 60)
  if (h < 24) return `há ${h} h`
  const d = Math.round(h / 24)
  return d === 1 ? 'ontem' : `há ${d} dias`
}

function Publicacao({ m, aoCriarPrazo }) {
  const [aberta, setAberta] = useState(false)
  const x = m.extra || {}
  const texto = m.detalhe || ''
  const longo = texto.length > 420
  return (
    <>
      <div className="titulo">{m.titulo}{x.tipo_comunicacao && x.tipo_comunicacao !== m.titulo ? ` · ${x.tipo_comunicacao}` : ''}</div>
      {x.orgao && <div className="detalhe" style={{ fontWeight: 500 }}>{x.orgao}</div>}
      <div className="detalhe" style={{ whiteSpace: 'pre-wrap' }}>{aberta || !longo ? texto : `${texto.slice(0, 420).trim()}…`}</div>
      <div className="pub-acoes">
        {longo && <button className="link-btn" onClick={() => setAberta(v => !v)}>{aberta ? 'Recolher' : 'Ler inteiro teor'}</button>}
        {x.status === 'prazo_criado'
          ? <span className="selo">Prazo criado</span>
          : <button className="btn pequeno primario" onClick={() => aoCriarPrazo(m)}><Icone nome="mais_add" />Criar prazo</button>}
      </div>
    </>
  )
}

function NovaObservacao({ processoId, aoSalvar }) {
  const toast = useToast()
  const [texto, setTexto] = useState('')
  const [salvando, setSalvando] = useState(false)
  async function salvar() {
    if (!texto.trim()) return
    setSalvando(true)
    try { await api.registrarObservacao(processoId, texto); setTexto(''); toast('Observação registrada.'); aoSalvar() }
    catch (e) { toast(e.message, 'erro') } finally { setSalvando(false) }
  }
  return (
    <div className="nova-obs">
      <textarea className="entrada" rows={2} value={texto} onChange={e => setTexto(e.target.value)}
        placeholder="Registrar observação (ex.: cliente enviou documentos, ligação com a parte contrária…)" />
      <button className="btn pequeno primario" disabled={salvando || !texto.trim()} onClick={salvar}><Icone nome="mais_add" />{salvando ? 'Salvando…' : 'Registrar observação'}</button>
    </div>
  )
}

const quandoObs = iso => new Date(iso).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit', timeZone: 'America/Sao_Paulo' })

/** Observações da equipe: lista própria, separada das movimentações do tribunal */
function Observacoes({ processoId }) {
  const { perfil } = usePerfil()
  const toast = useToast()
  const r = useCarregar(() => api.listarObservacoes(processoId), [processoId])
  const [nova, setNova] = useState(false)
  const [todas, setTodas] = useState(false)
  async function apagar(m) {
    if (!window.confirm('Excluir esta observação?')) return
    try { await api.excluirObservacao(m.item_id); toast('Observação excluída.'); r.recarregar() } catch (e) { toast(e.message, 'erro') }
  }
  const lista = r.dados || []
  const visiveis = todas ? lista : lista.slice(0, 3)
  return (
    <>
      <div className="secao"><h2>Observações{lista.length ? ` (${lista.length})` : ''}</h2>
        <button className="btn pequeno" onClick={() => setNova(v => !v)}>{nova ? 'Fechar' : '+ Observação'}</button></div>
      {nova && <NovaObservacao processoId={processoId} aoSalvar={() => { setNova(false); r.recarregar() }} />}
      {r.erro ? <Erro erro={r.erro} /> : r.carregando && !r.dados ? <Carregando n={1} /> : !lista.length ? (
        <div className="cartao muted">Nenhuma observação registrada. Use para anotar contatos com o cliente, combinados, documentos recebidos.</div>
      ) : (
        <div className="cartao">
          <ul className="tempo obs">
            {visiveis.map(m => (
              <li key={m.item_id} className="observacao">
                <div className="quando">{quandoObs(m.quando)} · <b>{m.extra?.autor_nome || 'usuário'}</b></div>
                <div className="detalhe" style={{ whiteSpace: 'pre-wrap', color: 'var(--text)' }}>{m.detalhe}</div>
                {m.extra?.autor_id === perfil.id && <button className="link-btn" style={{ marginTop: 4 }} onClick={() => apagar(m)}>Excluir</button>}
              </li>
            ))}
          </ul>
          {lista.length > 3 && <button className="link-btn" onClick={() => setTodas(v => !v)}>{todas ? 'Mostrar menos' : `Ver todas (${lista.length})`}</button>}
        </div>
      )}
    </>
  )
}

function LinhaDoTempo({ processoId, aoVer, aoCriarPrazo }) {
  const r = useCarregar(() => api.linhaDoTempo(processoId), [processoId])
  // Depois de mostrar, marca os andamentos como vistos (os "novos" continuam destacados nesta abertura)
  useEffect(() => {
    if (r.dados?.some(m => m.nova)) api.marcarVistas(processoId).then(aoVer).catch(() => {})
  }, [r.dados]) // eslint-disable-line react-hooks/exhaustive-deps
  if (r.erro) return <Erro erro={r.erro} />
  if (r.carregando && !r.dados) return <Carregando n={2} />
  return (
    <>
    {!r.dados.length ? (
      <Vazio icone="relogio" titulo="Sem movimentações ainda"
        texto="Nenhum andamento no DataJud nem publicação no DJEN até agora. Use “Atualizar agora” ou aguarde a consulta automática da madrugada." />
    ) : (
    <ul className="tempo">
      {r.dados.map(m => (
        <li key={m.item_id} className={`${m.origem} ${m.nova ? 'nova' : ''}`}>
          <div className="quando">
            {new Date(m.quando).toLocaleDateString('pt-BR')} · {m.origem === 'publicacao' ? 'Publicação DJEN' : 'Andamento DataJud'}
            {m.nova && <span className="selo novo" style={{ marginLeft: 6, height: 18 }}>nova</span>}
          </div>
          {m.origem === 'publicacao' ? <Publicacao m={m} aoCriarPrazo={aoCriarPrazo} /> : (
            <>
              <div className="titulo">{m.titulo}</div>
              {m.detalhe && <div className="detalhe">{m.detalhe}</div>}
            </>
          )}
          {m.anotacoes?.map((a, i) => (
            <div key={i} className="anotacao"><b>{a.tipo === 'dispositivo' ? 'Dispositivo' : a.tipo === 'explicacao' ? 'Explicação' : 'Observação'}{a.autor_nome ? ` · ${a.autor_nome}` : ''}</b>{a.texto}</div>
          ))}
        </li>
      ))}
    </ul>
    )}
    </>
  )
}

function DarBaixa({ p, aoConcluir }) {
  const toast = useToast()
  const hoje = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo' }).format(new Date())
  const [d, setD] = useState(hoje)
  const [motivo, setMotivo] = useState('')
  const [outro, setOutro] = useState('')
  const [obs, setObs] = useState('')
  const [cancelar, setCancelar] = useState(true)
  const [salvando, setSalvando] = useState(false)
  const motivoFinal = motivo === 'Outro' ? outro.trim() : motivo
  async function confirmar() {
    if (!motivoFinal) { toast('Informe o motivo da baixa.', 'erro'); return }
    setSalvando(true)
    try {
      const n = await api.darBaixa(p.id, d, motivoFinal, obs, cancelar)
      toast(`Processo baixado.${n ? ` ${n} prazo${n > 1 ? 's' : ''} em aberto cancelado${n > 1 ? 's' : ''}.` : ''}`); aoConcluir()
    } catch (e) { toast(e.message, 'erro') } finally { setSalvando(false) }
  }
  return (
    <div className="form">
      <p className="muted" style={{ margin: 0 }}>O processo sai da lista de ativos e deixa de ser consultado no DataJud e no DJEN. Tudo fica guardado e você pode reativar depois.</p>
      <Campo rotulo="Data da baixa" obrigatorio><input className="entrada" type="date" value={d} onChange={e => setD(e.target.value)} /></Campo>
      <Campo rotulo="Motivo" obrigatorio>
        <select className="entrada" value={motivo} onChange={e => setMotivo(e.target.value)}>
          <option value="">Selecione…</option>{MOTIVOS_BAIXA.map(m => <option key={m}>{m}</option>)}
        </select>
      </Campo>
      {motivo === 'Outro' && <Campo rotulo="Qual?" obrigatorio><input className="entrada" value={outro} onChange={e => setOutro(e.target.value)} /></Campo>}
      <Campo rotulo="Observação (opcional)"><textarea className="entrada" rows={2} value={obs} onChange={e => setObs(e.target.value)} /></Campo>
      {p.prazos_abertos > 0 && (
        <label className="caixa-check"><input type="checkbox" checked={cancelar} onChange={e => setCancelar(e.target.checked)} />
          <div><b>Cancelar {p.prazos_abertos} prazo{p.prazos_abertos > 1 ? 's' : ''} em aberto e as audiências futuras</b><span>Saem das listas e dos avisos. Ficam no histórico.</span></div></label>
      )}
      <button className="btn primario bloco" disabled={salvando} onClick={confirmar}>{salvando ? 'Salvando…' : 'Dar baixa no processo'}</button>
    </div>
  )
}

function Partes({ p }) {
  const partes = p.partes?.length ? p.partes : [
    { polo: p.polo === 'autor' ? 'ativo' : 'passivo', nome: p.cliente_nome, cliente_id: p.cliente_id },
    ...(p.parte_contraria ? [{ polo: p.polo === 'autor' ? 'passivo' : 'ativo', nome: p.parte_contraria }] : []),
  ]
  const bloco = (polo, titulo) => {
    const l = partes.filter(x => x.polo === polo)
    return (
      <div><dt>{titulo}{l.length > 1 ? ` (${l.length})` : ''}</dt>
        <dd>{l.length ? l.map((x, i) => <div key={i}>{x.cliente_id ? <Link to={`/clientes/${x.cliente_id}`} style={{ color: 'var(--accent)' }}>{x.nome}</Link> : x.nome}</div>) : '—'}</dd></div>
    )
  }
  return <>{bloco('ativo', 'Polo ativo')}{bloco('passivo', 'Polo passivo')}</>
}

export default function ProcessoDetalhe() {
  const { id } = useParams()
  const nav = useNavigate()
  const toast = useToast()
  const { perfil } = usePerfil()
  const r = useCarregar(() => Promise.all([api.obterProcesso(id), api.listarAdvogados()]), [id])
  const [p, advogados] = r.dados || []
  const [verMov, setVerMov] = useState(false)
  const [buscando, setBuscando] = useState(false)
  const auds = useCarregar(() => api.listarAudiencias({ processo_id: id, decrescente: true }), [id])
  const [formAud, setFormAud] = useState(null)
  const przs = useCarregar(() => api.listarPrazos({ processo_id: id }), [id])
  const [formPrazo, setFormPrazo] = useState(null)
  const [cumprir, setCumprir] = useState(null)
  const tentouAuto = useRef(false)

  async function atualizar(auto = false) {
    setBuscando(true)
    try {
      const res = await api.atualizarDataJud(id)
      const partes = []
      if (res.importados) partes.push(`Histórico do DataJud: ${res.importados} andamento${res.importados > 1 ? 's' : ''}`)
      else if (res.novos) partes.push(`${res.novos} andamento${res.novos > 1 ? 's' : ''} novo${res.novos > 1 ? 's' : ''}`)
      if (res.publicacoes_novas) partes.push(`${res.publicacoes_novas} publicação${res.publicacoes_novas > 1 ? 'ões' : ''} nova${res.publicacoes_novas > 1 ? 's' : ''} no DJEN`)
      if (res.aviso) { if (!auto || !/há pouco/.test(res.aviso)) partes.push(res.aviso) }
      if (res.erro_datajud) partes.push(`DataJud: ${res.erro_datajud}`)
      if (res.erro_djen) partes.push(`DJEN: ${res.erro_djen}`)
      if (!partes.length && !auto) partes.push('Nada novo no DataJud nem no DJEN.')
      if (partes.length) toast(partes.join(' · '), res.erro_datajud || res.erro_djen ? 'erro' : undefined)
      r.recarregar()
    } catch (e) { toast(e.message, 'erro') }
    finally { setBuscando(false) }
  }
  // Processo recém-cadastrado: busca o histórico sozinho na primeira abertura
  useEffect(() => {
    const proc = r.dados?.[0]
    if (proc && !proc.datajud_sync_em && !tentouAuto.current) { tentouAuto.current = true; atualizar(true) }
  }, [r.dados]) // eslint-disable-line react-hooks/exhaustive-deps
  const [folhaAdv, setFolhaAdv] = useState(false)
  const [folhaBaixa, setFolhaBaixa] = useState(false)
  async function reativar() {
    if (!window.confirm('Reativar este processo? Ele volta à lista de ativos e às consultas do DataJud e do DJEN.')) return
    try { await api.reativarProcesso(id); toast('Processo reativado.'); r.recarregar() } catch (e) { toast(e.message, 'erro') }
  }

  async function copiar() {
    try { await navigator.clipboard.writeText(p.numero_cnj); toast('Número copiado.') } catch { toast('Não foi possível copiar.', 'erro') }
  }
  async function incluir(a) {
    try { await api.incluirColega(id, a.id); toast(`${a.nome} incluído(a) no processo.`); setFolhaAdv(false); r.recarregar() }
    catch (e) { toast(e.message, 'erro') }
  }
  async function retirar(a) {
    const souEu = a.id === perfil.id
    const msg = souEu ? 'Sair deste processo? Você deixará de vê-lo.' : `Retirar ${a.nome} do processo? Ela(e) deixará de vê-lo.`
    if (!window.confirm(msg)) return
    try { await api.removerAdvogado(id, a.id); toast('Advogado retirado.'); souEu ? nav('/processos', { replace: true }) : r.recarregar() }
    catch (e) { toast(e.message, 'erro') }
  }
  async function excluir() {
    if (!window.confirm('Excluir este processo e tudo o que está ligado a ele (prazos, publicações, anotações)? Essa ação não pode ser desfeita.')) return
    try { await api.excluirProcesso(id); toast('Processo excluído.'); nav('/processos', { replace: true }) }
    catch (e) { toast(e.message, 'erro') }
  }

  if (r.erro) return <><Topo titulo="Processo" voltar="/processos" /><Erro erro={r.erro} tentar={r.recarregar} /></>
  if (r.carregando && !r.dados) return <><Topo titulo="Processo" voltar="/processos" /><Carregando n={3} /></>
  if (!p) return <><Topo titulo="Processo" voltar="/processos" /><Erro erro={{ message: 'Processo não encontrado ou sem acesso.' }} /></>

  const foraDoProcesso = advogados.filter(a => !p.advogados.some(x => x.id === a.id))
  return (
    <>
      <Topo titulo={p.cliente_nome} sub={`${POLOS[p.polo]} · ${p.tribunal}`} voltar="/processos"
        acoes={<Link to={`/processos/${id}/editar`} className="icone-btn so-editor" aria-label="Editar processo"><Icone nome="editar" /></Link>} />

      <div className="cartao">
        <div className="cartao-topo">
          <span className="mono numero" style={{ fontSize: '1.02rem' }}>{p.numero_cnj}</span>
          <button className="icone-btn" onClick={copiar} aria-label="Copiar número"><Icone nome="copiar" /></button>
        </div>
        <div className="linha" style={{ whiteSpace: 'normal' }}>× {p.parte_contraria || 'Parte contrária não informada'}</div>
        {p.situacao === 'baixado' && (
          <div className="aviso info" style={{ marginTop: 10 }}><Icone nome="info" />
            <div>Baixado em <b>{data(p.baixa_data)}</b>{p.baixa_por_nome ? ` por ${p.baixa_por_nome}` : ''} · {p.baixa_motivo}</div></div>
        )}
        <div className="cartao-rodape">
          <span className={`selo ${p.polo}`}>{POLOS[p.polo]}</span>
          <span className="selo">{SITUACOES[p.situacao]}</span>
          {p.tipo_acao && <span className="selo">{p.tipo_acao}</span>}
          {p.novidades > 0 && <span className="selo novo">{p.novidades} nova{p.novidades > 1 ? 's' : ''}</span>}
        </div>
      </div>

      <div className="acoes-processo">
        <button className="btn" onClick={() => setVerMov(true)}>
          <Icone nome="relogio" />Ver movimentações{p.novidades > 0 ? ` (${p.novidades} nova${p.novidades > 1 ? 's' : ''})` : ''}
        </button>
        <button className="btn" onClick={() => atualizar(false)} disabled={buscando} title="Consultar o DataJud agora">
          <Icone nome="atualizar" className={buscando ? 'girando' : ''} />{buscando ? 'Consultando…' : 'Atualizar agora'}
        </button>
      </div>
      <div className="status-fontes">
        {buscando && !p.datajud_sync_em ? <small className="muted">Buscando o histórico no DataJud e as publicações no DJEN…</small> : (
          <>
            <small className="muted"><b>DJEN</b> (publicações): {p.djen_sync_em ? `consultado ${haQuanto(p.djen_sync_em)}` : 'ainda não consultado'}.</small>
            <small className="muted"><b>DataJud</b> (andamentos): {p.datajud_sync_em ? `consultado ${haQuanto(p.datajud_sync_em)}` : 'ainda não consultado'}
              {p.datajud_atualizado_em && <>; o tribunal atualizou este processo no DataJud em <b>{data(p.datajud_atualizado_em.slice(0, 10))}</b>
                {diasDesde(p.datajud_atualizado_em) > 7 && <span style={{ color: 'var(--warn)' }}> (base atrasada: andamentos depois dessa data ainda não chegaram ao DataJud)</span>}</>}.
            </small>
          </>
        )}
      </div>

      <div className="secao"><h2>Dados do processo</h2></div>
      <div className="cartao">
        <dl className="dados" style={{ margin: 0 }}>
          <div><dt>Cliente</dt><dd><Link to={`/clientes/${p.cliente_id}`} style={{ color: 'var(--accent)' }}>{p.cliente_nome}</Link></dd></div>
          <Partes p={p} />
          <div><dt>Tribunal</dt><dd>{p.tribunal}</dd></div>
          <div><dt>Órgão julgador</dt><dd>{p.orgao_julgador || '—'}</dd></div>
          <div><dt>Comarca</dt><dd>{p.comarca || '—'}</dd></div>
          <div><dt>Rito</dt><dd>{RITOS[p.rito] || '—'}</dd></div>
          <div><dt>Instância</dt><dd>{INSTANCIAS[p.instancia || '1g']}</dd></div>
          <div><dt>Classe</dt><dd>{p.classe || '—'}</dd></div>
          <div><dt>Valor da causa</dt><dd>{moeda(p.valor_causa) || '—'}</dd></div>
          <div><dt>Distribuição</dt><dd>{data(p.data_distribuicao) || '—'}</dd></div>
          {p.observacoes && <div><dt>Observações</dt><dd style={{ whiteSpace: 'pre-wrap' }}>{p.observacoes}</dd></div>}
        </dl>
      </div>

      <Observacoes key={p.situacao} processoId={id} />

      <div className="secao"><h2>Audiências</h2><button className="btn pequeno so-editor" onClick={() => setFormAud({})}>+ Audiência</button></div>
      {auds.dados?.length ? (
        <div className="lista">{auds.dados.map(a => <ItemAudiencia key={a.id} a={a} mostrarProcesso={false} onAbrir={x => setFormAud(x)} />)}</div>
      ) : <div className="cartao muted">Nenhuma audiência cadastrada para este processo.</div>}

      <div className="secao"><h2>Prazos</h2><button className="btn pequeno so-editor" onClick={() => setFormPrazo({})}>+ Prazo</button></div>
      {przs.dados?.length ? (
        <div className="lista">{[...przs.dados].sort((a, b) => (a.status === b.status ? 0 : a.status === 'aberto' ? -1 : 1)).map(z =>
          <ItemPrazoLista key={z.id} z={z} mostrarProcesso={false} onAbrir={x => setFormPrazo(x)} onCumprir={setCumprir} />)}</div>
      ) : <div className="cartao muted">Nenhum prazo cadastrado para este processo.</div>}

      <div className="secao">
        <h2>Advogados ({p.advogados.length})</h2>
        {foraDoProcesso.length > 0 && <button className="btn pequeno so-editor" onClick={() => setFolhaAdv(true)}>Incluir</button>}
      </div>
      <div className="lista">
        {p.advogados.map(a => (
          <div key={a.id} className="cartao" style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '10px 14px' }}>
            <span className="avatar" style={{ width: 36, height: 36 }}>{iniciais(a.nome)}</span>
            <div style={{ flex: 1 }}><b>{a.nome}</b>{a.id === perfil.id && <span className="muted"> (você)</span>}</div>
            {p.advogados.length > 1 && <button className="btn pequeno perigo so-editor" onClick={() => retirar(a)}>{a.id === perfil.id ? 'Sair' : 'Retirar'}</button>}
          </div>
        ))}
      </div>
      <small className="muted" style={{ display: 'block', marginTop: 8 }}>Só os advogados listados enxergam este processo, as publicações, os prazos e as anotações dele.</small>

      <div style={{ marginTop: 28, display: 'grid', gap: 10 }} className="so-editor">
        {p.situacao === 'baixado'
          ? <button className="btn bloco" onClick={reativar}><Icone nome="atualizar" />Reativar processo</button>
          : <button className="btn bloco" onClick={() => setFolhaBaixa(true)}><Icone nome="certo" />Dar baixa no processo</button>}
        <button className="btn perigo bloco" onClick={excluir}><Icone nome="lixo" />Excluir processo</button>
      </div>
      <Folha titulo="Dar baixa no processo" aberta={folhaBaixa} fechar={() => setFolhaBaixa(false)}>
        {folhaBaixa && <DarBaixa p={p} aoConcluir={() => { setFolhaBaixa(false); r.recarregar(); przs.recarregar(); auds.recarregar() }} />}
      </Folha>

      <Folha titulo={formAud?.id ? 'Audiência' : 'Nova audiência'} aberta={Boolean(formAud)} fechar={() => setFormAud(null)}>
        {formAud && <AudienciaForm key={formAud.id || 'nova'} inicial={formAud} processoFixo={id}
          aoSalvar={async a => { await api.salvarAudiencia(a); toast(a.id ? 'Audiência atualizada.' : 'Audiência cadastrada.'); setFormAud(null); auds.recarregar() }}
          aoExcluir={formAud.id ? async () => { if (!window.confirm('Excluir esta audiência?')) return; await api.excluirAudiencia(formAud.id); toast('Audiência excluída.'); setFormAud(null); auds.recarregar() } : null} />}
      </Folha>

      <Folha titulo={formPrazo?.id ? 'Prazo' : 'Novo prazo'} aberta={Boolean(formPrazo)} fechar={() => setFormPrazo(null)}>
        {formPrazo && <PainelPrazo inicial={formPrazo} processoFixo={id}
          aoReabrir={async () => { await api.reabrirPrazo(formPrazo.id); toast('Prazo reaberto.'); setFormPrazo(null); przs.recarregar() }}
          aoCumprir={z => { setFormPrazo(null); setCumprir(z) }}
          aoSalvar={async z => { const s = await api.salvarPrazo(z); toast(`Prazo salvo. Fatal: ${s.prazo_fatal.split('-').reverse().join('/')}.`); setFormPrazo(null); przs.recarregar(); r.recarregar() }}
          aoExcluir={formPrazo.id ? async () => { if (!window.confirm('Excluir este prazo?')) return; await api.excluirPrazo(formPrazo.id); toast('Prazo excluído.'); setFormPrazo(null); przs.recarregar() } : null} />}
      </Folha>
      <Folha titulo="Prazo cumprido" aberta={Boolean(cumprir)} fechar={() => setCumprir(null)}>
        {cumprir && <CumprirForm z={cumprir} aoConfirmar={async (d, obs) => { await api.cumprirPrazo(cumprir.id, d, obs); toast('Prazo marcado como cumprido.'); setCumprir(null); przs.recarregar() }} />}
      </Folha>

      <Folha titulo="Movimentações" aberta={verMov} fechar={() => setVerMov(false)}>
        <LinhaDoTempo processoId={id} aoVer={() => r.recarregar()} aoCriarPrazo={m => {
          const sug = prazoNoTexto(m.detalhe)
          setVerMov(false)
          setFormPrazo({
            publicacao_id: m.item_id, data_recebimento: m.extra?.disponibilizacao, origem_contagem: 'disponibilizacao',
            dias: sug?.dias ? String(sug.dias) : '', contagem: sug?.contagem || 'uteis', trecho: sug?.trecho,
            observacoes: `Publicação DJEN de ${data(m.extra?.disponibilizacao)}: ${m.titulo}`,
          })
        }} />
      </Folha>
      <Folha titulo="Incluir advogado" aberta={folhaAdv} fechar={() => setFolhaAdv(false)}>
        <p className="muted" style={{ marginTop: 0 }}>A pessoa incluída passa a ver este processo e o cadastro do cliente.</p>
        <div className="lista">
          {foraDoProcesso.map(a => (
            <button key={a.id} className="cartao" onClick={() => incluir(a)} style={{ display: 'flex', gap: 12, alignItems: 'center' }}>
              <span className="avatar" style={{ width: 36, height: 36 }}>{iniciais(a.nome)}</span>
              <div style={{ flex: 1 }}><b>{a.nome}</b><div className="linha">{oabsTexto(a)}</div></div>
              <Icone nome="mais_add" width="20" height="20" />
            </button>
          ))}
        </div>
      </Folha>
    </>
  )
}
