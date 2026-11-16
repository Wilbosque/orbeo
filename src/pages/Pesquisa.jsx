import { useEffect, useState } from 'react'
import { Link, useNavigate, useSearchParams } from 'react-router-dom'
import * as api from '#backend'
import Icone from '../components/Icone.jsx'
import { Campo, Erro, Topo, Vazio, useCarregar } from '../components/ui.jsx'
import { data as fmt } from '../lib/formato.js'
import { TRIBUNAIS } from '../lib/suspensao.js'

const hoje = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo' }).format(new Date())
const menos = (iso, n) => { const d = new Date(iso + 'T12:00'); d.setDate(d.getDate() - n); return d.toLocaleDateString('en-CA') }
const PERIODOS = [['todo', 'Sem limite'], ['7', '7 dias'], ['30', '30 dias'], ['90', '90 dias'], ['365', '1 ano'], ['outro', 'Escolher datas']]
const POLO_ROT = { autor: 'Autor', reu: 'Réu' }
const poloLetra = p => { const l = String(p || '').toUpperCase(); return l.startsWith('A') ? 'Autor' : l.startsWith('P') ? 'Réu' : '' }
const norm = s => String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()

function Resultado({ p, nome, clienteId, aoCadastrar }) {
  const contraria = p.partes.find(x => !norm(x.nome).includes(norm(nome)) && (!p.polo_pesquisado || poloLetra(x.polo) !== POLO_ROT[p.polo_pesquisado]))
  return (
    <div className="cartao resultado-pesquisa">
      <div className="cartao-topo">
        <span className="mono numero">{p.numero_cnj}</span>
        {p.processo_id ? <span className="selo">Já no Orbeo</span> : p.polo_pesquisado && <span className={`selo ${p.polo_pesquisado}`}>{POLO_ROT[p.polo_pesquisado]}</span>}
      </div>
      <div className="linha" style={{ whiteSpace: 'normal' }}>{[p.tribunal, p.orgao_julgador].filter(Boolean).join(' · ')}</div>
      {p.classe && <div className="linha" style={{ whiteSpace: 'normal' }}>{p.classe}</div>}
      <ul className="partes">
        {p.partes.slice(0, 6).map((x, i) => <li key={i}><b>{poloLetra(x.polo) || 'Parte'}</b> {x.nome}</li>)}
        {p.partes.length > 6 && <li className="muted">e mais {p.partes.length - 6}</li>}
      </ul>
      <div className="linha" style={{ whiteSpace: 'normal' }}>
        {p.publicacoes} publicaç{p.publicacoes > 1 ? 'ões' : 'ão'} no período · última em {fmt(p.ultima)}{p.ultimo_tipo ? ` (${p.ultimo_tipo})` : ''}
      </div>
      {p.ultimo_trecho && <div className="trecho">{p.ultimo_trecho}{p.ultimo_trecho.length >= 280 ? '…' : ''}</div>}
      <div className="pub-acoes">
        {p.link && <a className="link-btn" href={p.link} target="_blank" rel="noreferrer">Documento no tribunal</a>}
        {p.processo_id
          ? <Link className="btn pequeno" to={`/processos/${p.processo_id}`}>Abrir no Orbeo</Link>
          : <button className="btn pequeno primario" onClick={() => aoCadastrar(p, contraria, clienteId)}><Icone nome="mais_add" />Cadastrar processo</button>}
      </div>
    </div>
  )
}

export default function Pesquisa() {
  const [sp] = useSearchParams()
  const nav = useNavigate()
  const clientes = useCarregar(() => api.listarClientes(), [])
  const [clienteId, setClienteId] = useState(sp.get('cliente') || '')
  const termos = useCarregar(() => (clienteId ? api.termosDoCliente(clienteId) : Promise.resolve([])), [clienteId])
  const [nome, setNome] = useState('')
  const [periodo, setPeriodo] = useState('todo')
  const [datas, setDatas] = useState({ inicio: '', fim: '' })
  const [tribunal, setTribunal] = useState('')
  const [estado, setEstado] = useState({ buscando: false, erro: null, res: null, nomeBuscado: '' })

  // Ao escolher um cliente, preenche o nome (o 1º nome de busca cadastrado ou a razão social)
  useEffect(() => {
    if (!clienteId) return
    const c = (clientes.dados || []).find(x => x.id === clienteId)
    const t = termos.dados?.[0]?.valor
    if (t || c) setNome(t || c.nome)
  }, [clienteId, termos.dados, clientes.dados])

  async function buscar(e) {
    e?.preventDefault()
    if (nome.trim().length < 4) { setEstado(s => ({ ...s, erro: { message: 'Digite pelo menos 4 letras do nome.' } })); return }
    setEstado({ buscando: true, erro: null, res: null, nomeBuscado: nome.trim() })
    try {
      const f = { nome: nome.trim(), tribunal: tribunal || null }
      if (periodo === 'outro') { f.inicio = datas.inicio || null; f.fim = datas.fim || null }
      else if (periodo !== 'todo') { f.fim = hoje(); f.inicio = menos(f.fim, Number(periodo)) }
      const res = await api.pesquisarDJEN(f)
      setEstado({ buscando: false, erro: null, res, nomeBuscado: nome.trim() })
    } catch (err) { setEstado({ buscando: false, erro: err, res: null, nomeBuscado: '' }) }
  }

  function cadastrar(p, contraria, cid) {
    const q = new URLSearchParams({ numero: p.numero_cnj })
    if (cid) q.set('cliente', cid)
    if (p.polo_pesquisado) q.set('polo', p.polo_pesquisado)
    if (contraria?.nome) q.set('parte', contraria.nome)
    if (p.orgao_julgador) q.set('orgao', p.orgao_julgador)
    if (p.classe) q.set('classe', p.classe)
    nav(`/processos/novo?${q}`)
  }

  const { buscando, erro, res, nomeBuscado } = estado
  const novos = res?.processos.filter(p => !p.processo_id) || []
  const jaTenho = res?.processos.filter(p => p.processo_id) || []
  return (
    <>
      <Topo titulo="Buscar processos" sub="Publicações no DJEN pelo nome da parte" voltar="/processos" />
      <form className="form cartao" onSubmit={buscar} noValidate>
        <Campo rotulo="Cliente (opcional)" ajuda="Escolha um cliente para buscar pelo nome dele, ou deixe em branco e digite qualquer nome.">
          <select className="entrada" value={clienteId} onChange={e => { setClienteId(e.target.value); if (!e.target.value) setNome('') }}>
            <option value="">Qualquer pessoa ou empresa</option>
            {(clientes.dados || []).map(c => <option key={c.id} value={c.id}>{c.nome_fantasia || c.nome}</option>)}
          </select>
        </Campo>
        {termos.dados?.length > 1 && (
          <div className="chips" style={{ margin: 0, padding: 0 }}>
            {termos.dados.map(t => <button type="button" key={t.id} className={`chip ${nome === t.valor ? 'ativo' : ''}`} onClick={() => setNome(t.valor)}>{t.valor}</button>)}
          </div>
        )}
        <Campo rotulo="Nome da parte" obrigatorio ajuda="Como aparece no processo. Ex.: MARQUES TURISMO LTDA. Nomes muito comuns trazem muitos resultados.">
          <input className="entrada" value={nome} onChange={e => setNome(e.target.value)} placeholder="Nome da pessoa ou empresa" autoCapitalize="characters" />
        </Campo>
        <div className="duas">
          <Campo rotulo="Período (opcional)">
            <select className="entrada" value={periodo} onChange={e => setPeriodo(e.target.value)}>
              {PERIODOS.map(([v, r]) => <option key={v} value={v}>{r}</option>)}
            </select>
          </Campo>
          <Campo rotulo="Tribunal (opcional)">
            <input className="entrada" list="lista-trib-pesq" value={tribunal} onChange={e => setTribunal(e.target.value.toUpperCase())} placeholder="Todos" autoComplete="off" />
            <datalist id="lista-trib-pesq">{TRIBUNAIS.map(t => <option key={t} value={t} />)}</datalist>
          </Campo>
        </div>
        {periodo === 'outro' && (
          <div className="duas">
            <Campo rotulo="De"><input className="entrada" type="date" value={datas.inicio} max={datas.fim || hoje()} onChange={e => setDatas(d => ({ ...d, inicio: e.target.value }))} /></Campo>
            <Campo rotulo="Até"><input className="entrada" type="date" value={datas.fim} min={datas.inicio} max={hoje()} onChange={e => setDatas(d => ({ ...d, fim: e.target.value }))} /></Campo>
          </div>
        )}
        <button className="btn primario bloco" disabled={buscando}><Icone nome="busca" />{buscando ? 'Buscando no DJEN…' : 'Buscar'}</button>
        {buscando && <small className="muted">Respeitando o limite do DJEN, buscas grandes podem levar até 1 minuto.</small>}
      </form>

      {erro && <Erro erro={erro} />}
      {res && (
        <>
          <div className="secao"><h2>{novos.length} processo{novos.length !== 1 ? 's' : ''} fora do Orbeo</h2></div>
          <small className="muted" style={{ display: 'block', marginBottom: 10 }}>
            {res.publicacoes} publicaç{res.publicacoes !== 1 ? 'ões' : 'ão'} com “{nomeBuscado}”
            {res.inicio || res.fim ? ` entre ${res.inicio ? fmt(res.inicio) : 'o início do DJEN'} e ${fmt(res.fim || hoje())}` : ' em todo o DJEN'}.
            {res.truncado && ` Muitos resultados: foram lidas as ${res.publicacoes} mais recentes${res.coberto_desde ? ` (desde ${fmt(res.coberto_desde)})` : ''}. Para ir mais longe, escolha um tribunal ou um período.`}
          </small>
          {novos.length ? <div className="lista grade">{novos.map(p => <Resultado key={p.numero_cnj} p={p} nome={nomeBuscado} clienteId={clienteId} aoCadastrar={cadastrar} />)}</div>
            : <Vazio icone="busca" titulo="Nada novo" texto="Todos os processos encontrados já estão no Orbeo, ou não houve publicação no período." />}
          {jaTenho.length > 0 && (
            <>
              <div className="secao"><h2>Já no Orbeo ({jaTenho.length})</h2></div>
              <div className="lista grade">{jaTenho.map(p => <Resultado key={p.numero_cnj} p={p} nome={nomeBuscado} clienteId={clienteId} aoCadastrar={cadastrar} />)}</div>
            </>
          )}
        </>
      )}
      {!res && !erro && !buscando && (
        <small className="muted" style={{ display: 'block', marginTop: 12 }}>
          A busca encontra processos em que a pessoa ou empresa aparece em alguma publicação do DJEN (citação, intimação, sentença…).
          Sem período, procura em todo o DJEN. Processos que nunca tiveram publicação não aparecem.
        </small>
      )}
    </>
  )
}
