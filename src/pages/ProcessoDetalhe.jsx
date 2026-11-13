import { useEffect, useRef, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import * as api from '#backend'
import { usePerfil } from '../App.jsx'
import Icone from '../components/Icone.jsx'
import { Carregando, Erro, Folha, Topo, Vazio, useCarregar, useToast } from '../components/ui.jsx'
import { POLOS, SITUACOES, data, iniciais, moeda } from '../lib/formato.js'

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

function LinhaDoTempo({ processoId, aoVer }) {
  const r = useCarregar(() => api.linhaDoTempo(processoId), [processoId])
  // Depois de mostrar, marca os andamentos como vistos (os "novos" continuam destacados nesta abertura)
  useEffect(() => {
    if (r.dados?.some(m => m.nova)) api.marcarVistas(processoId).then(aoVer).catch(() => {})
  }, [r.dados]) // eslint-disable-line react-hooks/exhaustive-deps
  if (r.erro) return <Erro erro={r.erro} />
  if (r.carregando) return <Carregando n={2} />
  if (!r.dados.length) return (
    <Vazio icone="relogio" titulo="Sem movimentações ainda"
      texto="Nenhum andamento encontrado no DataJud até agora. Use “Atualizar agora” ou aguarde a consulta automática da madrugada. As publicações do DJEN entram na próxima etapa." />
  )
  return (
    <ul className="tempo">
      {r.dados.map(m => (
        <li key={m.item_id} className={`${m.origem} ${m.nova ? 'nova' : ''}`}>
          <div className="quando">
            {new Date(m.quando).toLocaleDateString('pt-BR')} · {m.origem === 'publicacao' ? 'Publicação DJEN' : 'Andamento DataJud'}
            {m.nova && <span className="selo novo" style={{ marginLeft: 6, height: 18 }}>nova</span>}
          </div>
          <div className="titulo">{m.titulo}</div>
          {m.detalhe && <div className="detalhe">{m.detalhe}</div>}
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
  const tentouAuto = useRef(false)

  async function atualizar(auto = false) {
    setBuscando(true)
    try {
      const res = await api.atualizarDataJud(id)
      if (res.aviso) { if (!auto || !/há pouco/.test(res.aviso)) toast(res.aviso) }
      else if (res.importados) toast(`Histórico importado do DataJud: ${res.importados} andamento${res.importados > 1 ? 's' : ''}.`)
      else toast(res.novos ? `${res.novos} andamento${res.novos > 1 ? 's' : ''} novo${res.novos > 1 ? 's' : ''}.` : 'Nenhum andamento novo no DataJud.')
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
      <small className="muted" style={{ display: 'block', marginTop: 6 }}>
        {buscando && !p.datajud_sync_em ? 'Buscando o histórico no DataJud…'
          : p.datajud_sync_em ? `DataJud consultado ${haQuanto(p.datajud_sync_em)}. Os tribunais enviam os andamentos ao DataJud uma vez por dia.`
          : 'Ainda não consultado no DataJud.'}
      </small>

      <div className="secao"><h2>Dados do processo</h2></div>
      <div className="cartao">
        <dl className="dados" style={{ margin: 0 }}>
          <div><dt>Cliente</dt><dd><Link to={`/clientes/${p.cliente_id}`} style={{ color: 'var(--accent)' }}>{p.cliente_nome}</Link></dd></div>
          <div><dt>Tribunal</dt><dd>{p.tribunal}</dd></div>
          <div><dt>Órgão julgador</dt><dd>{p.orgao_julgador || '—'}</dd></div>
          <div><dt>Comarca</dt><dd>{p.comarca || '—'}</dd></div>
          <div><dt>Classe</dt><dd>{p.classe || '—'}</dd></div>
          <div><dt>Valor da causa</dt><dd>{moeda(p.valor_causa) || '—'}</dd></div>
          <div><dt>Distribuição</dt><dd>{data(p.data_distribuicao) || '—'}</dd></div>
          {p.observacoes && <div><dt>Observações</dt><dd style={{ whiteSpace: 'pre-wrap' }}>{p.observacoes}</dd></div>}
        </dl>
      </div>

      <div className="secao"><h2>Prazos</h2></div>
      <div className="cartao muted">O controle de prazos entra na próxima etapa, ligado às publicações deste processo.</div>

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

      <Folha titulo="Movimentações" aberta={verMov} fechar={() => setVerMov(false)}>
        <LinhaDoTempo processoId={id} aoVer={() => r.recarregar()} />
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
