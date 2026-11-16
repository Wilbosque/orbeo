import { useEffect, useState } from 'react'
import { Link, useNavigate, useSearchParams } from 'react-router-dom'
import * as api from '#backend'
import Icone from '../components/Icone.jsx'
import { Carregando, Erro, Folha, Segmentado, Topo, Vazio, useCarregar, useToast } from '../components/ui.jsx'
import { data as fmt } from '../lib/formato.js'
import { tribunalDoCNJ } from '../lib/cnj.js'

const POLO = { autor: 'Autor', reu: 'Réu' }
const STATUS = { pendente: 'Aguardando', visualizado: 'Visualizado', cadastrado: 'Cadastrado' }
const quando = iso => new Date(iso).toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo', day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' })
const poloLetra = p => { const l = String(p || '').toUpperCase(); return l.startsWith('A') ? 'Autor' : l.startsWith('P') ? 'Réu' : 'Parte' }
const norm = s => String(s || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase()
const tribunal = d => { const t = tribunalDoCNJ(d.numero_cnj); return t ? `${d.tribunal || t.sigla} · ${t.ramo}` : d.tribunal || '—' }

function Detalhe({ d, aoDecidir }) {
  const nav = useNavigate()
  const contraria = (d.partes || []).find(x => !norm(x.nome).includes(norm(d.termo)))
  function cadastrar() {
    const q = new URLSearchParams({ numero: d.numero_cnj, cliente: d.cliente_id })
    if (d.polo_cliente) q.set('polo', d.polo_cliente)
    if (contraria?.nome) q.set('parte', contraria.nome)
    if (d.orgao_julgador) q.set('orgao', d.orgao_julgador)
    if (d.classe) q.set('classe', d.classe)
    nav(`/processos/novo?${q}`)
  }
  return (
    <div className="form">
      <dl className="dados" style={{ margin: 0 }}>
        <div><dt>Cliente</dt><dd>{d.cliente_fantasia || d.cliente_nome}{d.polo_cliente ? ` · ${POLO[d.polo_cliente]}` : ''}</dd></div>
        <div><dt>Número do processo</dt><dd className="mono">{d.numero_cnj}</dd></div>
        <div><dt>Tribunal</dt><dd>{tribunal(d)}</dd></div>
        {d.orgao_julgador && <div><dt>Órgão</dt><dd>{d.orgao_julgador}</dd></div>}
        {d.classe && <div><dt>Classe</dt><dd>{d.classe}</dd></div>}
        <div><dt>Partes</dt><dd>{(d.partes || []).map((p, i) => <div key={i}><b>{poloLetra(p.polo)}</b> · {p.nome}</div>)}</dd></div>
        <div><dt>Última publicação</dt><dd>{fmt(d.ultima)}{d.ultimo_tipo ? ` · ${d.ultimo_tipo}` : ''}</dd></div>
      </dl>
      {d.trecho && <div className="trecho-pub">{d.trecho}</div>}
      <small className="muted">Identificado pela busca diária no DJEN com o nome “{d.termo}” em {quando(d.notificado_em)}. Confira no tribunal antes de cadastrar.</small>
      {d.link && <a className="btn bloco" href={d.link} target="_blank" rel="noreferrer"><Icone nome="exportar" />Consultar a publicação no tribunal</a>}
      <button className="btn primario bloco" onClick={cadastrar}><Icone nome="mais_add" />Cadastrar processo</button>
      <button className="btn bloco" onClick={() => aoDecidir(d, 'visualizado')}><Icone nome="certo" />Visualizado (não cadastrar agora)</button>
    </div>
  )
}

export default function Novos() {
  const toast = useToast()
  const [sp, setSp] = useSearchParams()
  const [aba, setAba] = useState('pendentes')
  const r = useCarregar(() => api.listarDescobertas({ historico: aba === 'historico' }), [aba])
  const [sel, setSel] = useState(null)
  const lista = r.dados || []

  // Vindo da notificação (#/novos?id=...): abre o processo direto
  useEffect(() => {
    const id = sp.get('id')
    if (id && aba === 'pendentes' && r.dados) { const d = r.dados.find(x => x.descoberta_id === id); if (d) setSel(d); setSp({}, { replace: true }) }
  }, [r.dados]) // eslint-disable-line react-hooks/exhaustive-deps

  async function decidir(d, status) {
    try { await api.decidirDescoberta(d.aviso_id, status); toast(status === 'visualizado' ? 'Marcado como visualizado. Fica registrado no histórico.' : 'Voltou para a lista.'); setSel(null); r.recarregar() }
    catch (e) { toast(e.message, 'erro') }
  }

  return (
    <>
      <Topo titulo="Processos novos" sub="Encontrados no DJEN pelo nome dos seus clientes" voltar="/" />
      <Segmentado rotulo="Ver" valor={aba} onChange={v => { setAba(v); setSel(null) }} opcoes={[['pendentes', 'Para decidir'], ['historico', 'Histórico']]} />
      <div style={{ height: 12 }} />
      {r.erro && <Erro erro={r.erro} tentar={r.recarregar} />}
      {r.carregando && !r.dados ? <Carregando n={2} /> : aba === 'pendentes' ? (
        lista.length ? (
          <div className="lista grade">
            {lista.map(d => (
              <button key={d.aviso_id} className="cartao novo-proc" onClick={() => setSel(d)}>
                <div className="cartao-topo"><b>{d.cliente_fantasia || d.cliente_nome}</b>{d.polo_cliente && <span className={`selo ${d.polo_cliente}`}>{POLO[d.polo_cliente]}</span>}</div>
                <div className="mono numero">{d.numero_cnj}</div>
                <div className="linha" style={{ whiteSpace: 'normal' }}>{tribunal(d)}{d.orgao_julgador ? ` · ${d.orgao_julgador}` : ''}</div>
                <div className="linha">Última publicação em {fmt(d.ultima)}{d.ultimo_tipo ? ` (${d.ultimo_tipo})` : ''} · avisado em {quando(d.notificado_em)}</div>
              </button>
            ))}
          </div>
        ) : <Vazio icone="certo" titulo="Nada para decidir" texto="A busca diária procura processos novos dos seus clientes no DJEN. Quando encontrar algum que ainda não está no Orbeo, ele aparece aqui e você recebe um aviso." />
      ) : (
        lista.length ? (
          <div className="cartao" style={{ padding: 0, overflowX: 'auto' }}>
            <table className="tabela-log">
              <thead><tr><th>Avisado em</th><th>Advogado avisado</th><th>Cliente</th><th>Processo</th><th>Situação</th></tr></thead>
              <tbody>
                {lista.map(d => (
                  <tr key={d.aviso_id}>
                    <td>{quando(d.notificado_em)}</td>
                    <td>{d.advogado_nome}{d.meu ? ' (você)' : ''}</td>
                    <td>{d.cliente_fantasia || d.cliente_nome}</td>
                    <td><span className="mono">{d.numero_cnj}</span><br /><small className="muted">{d.tribunal}</small></td>
                    <td>
                      <span className={`selo ${d.status === 'cadastrado' ? 'violeta' : d.status === 'pendente' ? 'alerta' : ''}`}>{STATUS[d.status]}</span>
                      {d.decidido_em && <><br /><small className="muted">{quando(d.decidido_em)}{d.decidido_por_nome ? ` · ${d.decidido_por_nome}` : ''}</small></>}
                      {d.processo_id && <><br /><Link className="link-btn" style={{ padding: 0 }} to={`/processos/${d.processo_id}`}>Abrir processo</Link></>}
                      {d.meu && d.status === 'visualizado' && !d.processo_id && <><br /><button className="link-btn" style={{ padding: 0 }} onClick={() => decidir(d, 'pendente')}>Voltar para decidir</button></>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : <Vazio icone="relogio" titulo="Sem histórico ainda" texto="Os avisos de processos novos e o que cada advogado decidiu ficam registrados aqui." />
      )}
      <Folha titulo="Processo novo identificado" aberta={Boolean(sel)} fechar={() => setSel(null)}>
        {sel && <Detalhe d={sel} aoDecidir={decidir} />}
      </Folha>
    </>
  )
}
