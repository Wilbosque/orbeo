import { useEffect, useRef, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import * as api from '#backend'
import { usePerfil } from '../App.jsx'
import Icone from '../components/Icone.jsx'
import { Carregando, Erro, Folha, Topo, Vazio, useCarregar, useToast } from '../components/ui.jsx'
import { POLOS, SITUACOES, data, iniciais, moeda } from '../lib/formato.js'
import { AudienciaForm, ItemAudiencia } from '../components/Audiencias.jsx'
import { CumprirForm, ItemPrazoLista, PrazoForm } from '../components/Prazos.jsx'
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
        {x.link && <a className="link-btn" href={x.link} target="_blank" rel="noreferrer">Documento no tribunal</a>}
        {x.status === 'prazo_criado'
          ? <span className="selo">Prazo criado</span>
          : <button className="btn pequeno primario" onClick={() => aoCriarPrazo(m)}><Icone nome="mais_add" />Criar prazo</button>}
      </div>
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
  if (r.carregando) return <Carregando n={2} />
  if (!r.dados.length) return (
    <Vazio icone="relogio" titulo="Sem movimentações ainda"
      texto="Nenhum andamento no DataJud nem publicação no DJEN até agora. Use “Atualizar agora” ou aguarde a consulta automática da madrugada." />
  )
  return (
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
            <div key={i} className="anotacao"><b>{a.tipo === 'dispositivo' ? 'Dispositivo' : a.tipo === 'explicacao' ? 'Explicação' : 'Observação'}</b>{a.texto}</div>
          ))}
        </li>
      ))}
    </ul>
  )
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
        acoes={<Link to={`/processos/${id}/editar`} className="icone-btn" aria-label="Editar processo"><Icone nome="editar" /></Link>} />

      <div className="cartao">
        <div className="cartao-topo">
          <span className="mono numero" style={{ fontSize: '1.02rem' }}>{p.numero_cnj}</span>
          <button className="icone-btn" onClick={copiar} aria-label="Copiar número"><Icone nome="copiar" /></button>
        </div>
        <div className="linha" style={{ whiteSpace: 'normal' }}>× {p.parte_contraria || 'Parte contrária não informada'}</div>
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

      <div className="secao"><h2>Audiências</h2><button className="btn pequeno" onClick={() => setFormAud({})}>+ Audiência</button></div>
      {auds.dados?.length ? (
        <div className="lista">{auds.dados.map(a => <ItemAudiencia key={a.id} a={a} mostrarProcesso={false} onAbrir={x => setFormAud(x)} />)}</div>
      ) : <div className="cartao muted">Nenhuma audiência cadastrada para este processo.</div>}

      <div className="secao"><h2>Prazos</h2><button className="btn pequeno" onClick={() => setFormPrazo({})}>+ Prazo</button></div>
      {przs.dados?.length ? (
        <div className="lista">{[...przs.dados].sort((a, b) => (a.status === b.status ? 0 : a.status === 'aberto' ? -1 : 1)).map(z =>
          <ItemPrazoLista key={z.id} z={z} mostrarProcesso={false} onAbrir={x => setFormPrazo(x)} onCumprir={setCumprir} />)}</div>
      ) : <div className="cartao muted">Nenhum prazo cadastrado para este processo.</div>}

      <div className="secao">
        <h2>Advogados ({p.advogados.length})</h2>
        {foraDoProcesso.length > 0 && <button className="btn pequeno" onClick={() => setFolhaAdv(true)}>Incluir</button>}
      </div>
      <div className="lista">
        {p.advogados.map(a => (
          <div key={a.id} className="cartao" style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '10px 14px' }}>
            <span className="avatar" style={{ width: 36, height: 36 }}>{iniciais(a.nome)}</span>
            <div style={{ flex: 1 }}><b>{a.nome}</b>{a.id === perfil.id && <span className="muted"> (você)</span>}</div>
            {p.advogados.length > 1 && <button className="btn pequeno perigo" onClick={() => retirar(a)}>{a.id === perfil.id ? 'Sair' : 'Retirar'}</button>}
          </div>
        ))}
      </div>
      <small className="muted" style={{ display: 'block', marginTop: 8 }}>Só os advogados listados enxergam este processo, as publicações, os prazos e as anotações dele.</small>

      <div style={{ marginTop: 28 }}>
        <button className="btn perigo bloco" onClick={excluir}><Icone nome="lixo" />Excluir processo</button>
      </div>

      <Folha titulo={formAud?.id ? 'Audiência' : 'Nova audiência'} aberta={Boolean(formAud)} fechar={() => setFormAud(null)}>
        {formAud && <AudienciaForm key={formAud.id || 'nova'} inicial={formAud} processoFixo={id}
          aoSalvar={async a => { await api.salvarAudiencia(a); toast(a.id ? 'Audiência atualizada.' : 'Audiência cadastrada.'); setFormAud(null); auds.recarregar() }}
          aoExcluir={formAud.id ? async () => { if (!window.confirm('Excluir esta audiência?')) return; await api.excluirAudiencia(formAud.id); toast('Audiência excluída.'); setFormAud(null); auds.recarregar() } : null} />}
      </Folha>

      <Folha titulo={formPrazo?.id ? 'Editar prazo' : 'Novo prazo'} aberta={Boolean(formPrazo)} fechar={() => setFormPrazo(null)}>
        {formPrazo && <PrazoForm key={formPrazo.id || 'novo'} inicial={formPrazo} processoFixo={id}
          aoSalvar={async z => { const s = await api.salvarPrazo(z); toast(`Prazo salvo. Fatal: ${s.prazo_fatal.split('-').reverse().join('/')}.`); setFormPrazo(null); przs.recarregar(); r.recarregar() }}
          aoExcluir={formPrazo.id ? async () => { if (!window.confirm('Excluir este prazo?')) return; await api.excluirPrazo(formPrazo.id); toast('Prazo excluído.'); setFormPrazo(null); przs.recarregar() } : null} />}
      </Folha>
      <Folha titulo="Prazo cumprido" aberta={Boolean(cumprir)} fechar={() => setCumprir(null)}>
        {cumprir && <CumprirForm z={cumprir} aoConfirmar={async d => { await api.cumprirPrazo(cumprir.id, d); toast('Prazo marcado como cumprido.'); setCumprir(null); przs.recarregar() }} />}
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
              <div style={{ flex: 1 }}><b>{a.nome}</b><div className="linha">OAB {a.oab_numero}/{a.oab_uf}</div></div>
              <Icone nome="mais_add" width="20" height="20" />
            </button>
          ))}
        </div>
      </Folha>
    </>
  )
}
