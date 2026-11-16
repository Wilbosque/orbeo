import { useMemo } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import * as api from '#backend'
import Icone from '../components/Icone.jsx'
import { Avatares, Carregando, Erro, Fab, Topo, Vazio, useCarregar } from '../components/ui.jsx'
import { POLOS, SITUACOES, normalizar } from '../lib/formato.js'
import { soDigitos } from '../lib/cnj.js'
import { diasAte, rotuloQuando } from '../lib/audiencia.js'

export function CartaoProcesso({ p }) {
  const compartilhado = p.advogados?.length > 1
  return (
    <Link to={`/processos/${p.id}`} className="cartao">
      <div className="cartao-topo">
        <span className="mono numero">{p.numero_cnj}</span>
        {p.novidades > 0 && <span className="selo novo">{p.novidades} nova{p.novidades > 1 ? 's' : ''}</span>}
      </div>
      <h3>{p.cliente_nome}</h3>
      <div className="linha">× {p.parte_contraria || 'Parte contrária não informada'}</div>
      <div className="linha">{p.tribunal}{p.orgao_julgador ? ` · ${p.orgao_julgador}` : ''}</div>
      <div className="cartao-rodape">
        <span className={`selo ${p.polo}`}>{POLOS[p.polo]}</span>
        {p.situacao !== 'ativo' && <span className="selo">{SITUACOES[p.situacao]}</span>}
        {p.tipo_acao && <span className="selo">{p.tipo_acao}</span>}
        {p.proxima_audiencia && <span className={`selo ${diasAte(p.proxima_audiencia) <= 1 ? 'perigo' : 'violeta'}`}><Icone nome="martelo" />{rotuloQuando(p.proxima_audiencia)}</span>}
        {compartilhado && <span className="selo" title="Processo compartilhado"><Icone nome="compartilhado" />Compartilhado</span>}
        <span style={{ marginLeft: 'auto' }}><Avatares advogados={p.advogados} /></span>
      </div>
    </Link>
  )
}

export default function Processos() {
  const [sp, setSp] = useSearchParams()
  const q = sp.get('q') || ''
  const situacao = sp.get('situacao') || ''
  const polo = sp.get('polo') || ''
  const cliente = sp.get('cliente') || ''
  const novidades = sp.get('novidades') === '1'
  const set = (k, v) => { const n = new URLSearchParams(sp); v ? n.set(k, v) : n.delete(k); setSp(n, { replace: true }) }

  const r = useCarregar(() => api.listarProcessos(), [])
  const lista = r.dados || []
  const clientes = useMemo(() => [...new Map(lista.map(p => [p.cliente_id, p.cliente_nome])).entries()]
    .sort((a, b) => a[1].localeCompare(b[1])), [lista])

  const filtrados = useMemo(() => {
    const t = normalizar(q), dig = soDigitos(q)
    return lista.filter(p =>
      (!situacao || p.situacao === situacao) && (!polo || p.polo === polo) &&
      (!cliente || p.cliente_id === cliente) && (!novidades || p.novidades > 0) &&
      (!q || (dig.length >= 4 && soDigitos(p.numero_cnj).includes(dig)) ||
        normalizar(`${p.cliente_nome} ${p.parte_contraria} ${p.orgao_julgador} ${p.tribunal} ${p.classe}`).includes(t)))
  }, [lista, q, situacao, polo, cliente, novidades])

  return (
    <>
      <Topo titulo="Processos" sub={r.dados ? `${filtrados.length} de ${lista.length}` : ' '}
        acoes={<Link to="/pesquisa" className="btn pequeno" title="Buscar processos novos no DJEN"><Icone nome="radar" />Buscar novos</Link>} />
      <div className="busca">
        <Icone nome="busca" />
        <input type="search" placeholder="Número, cliente, parte contrária, vara…" value={q} onChange={e => set('q', e.target.value)} aria-label="Buscar processos" />
      </div>
      <div className="chips" role="toolbar" aria-label="Filtros">
        <button className={`chip ${!situacao ? 'ativo' : ''}`} onClick={() => set('situacao', '')}>Todos</button>
        <button className={`chip ${situacao === 'ativo' ? 'ativo' : ''}`} onClick={() => set('situacao', situacao === 'ativo' ? '' : 'ativo')}>Ativos</button>
        <button className={`chip ${situacao === 'arquivado' ? 'ativo' : ''}`} onClick={() => set('situacao', situacao === 'arquivado' ? '' : 'arquivado')}>Arquivados</button>
        <button className={`chip ${novidades ? 'ativo' : ''}`} onClick={() => set('novidades', novidades ? '' : '1')}>Com novidades</button>
        <button className={`chip ${polo === 'reu' ? 'ativo' : ''}`} onClick={() => set('polo', polo === 'reu' ? '' : 'reu')}>Como réu</button>
        <button className={`chip ${polo === 'autor' ? 'ativo' : ''}`} onClick={() => set('polo', polo === 'autor' ? '' : 'autor')}>Como autor</button>
        <select className={`chip ${cliente ? 'ativo' : ''}`} value={cliente} onChange={e => set('cliente', e.target.value)} aria-label="Filtrar por cliente">
          <option value="">Cliente: todos</option>
          {clientes.map(([id, nome]) => <option key={id} value={id}>{nome}</option>)}
        </select>
      </div>

      {r.erro && <Erro erro={r.erro} tentar={r.recarregar} />}
      {r.carregando && !r.dados ? <Carregando /> :
        lista.length === 0 ? (
          <Vazio titulo="Nenhum processo ainda" texto="Cadastre o primeiro processo para começar o acompanhamento." >
            <Link to="/processos/novo" className="btn primario">Cadastrar processo</Link>
          </Vazio>
        ) : filtrados.length === 0 ? (
          <Vazio icone="busca" titulo="Nada encontrado" texto="Nenhum processo corresponde à busca ou aos filtros." />
        ) : (
          <div className="lista grade">{filtrados.map(p => <CartaoProcesso key={p.id} p={p} />)}</div>
        )}
      <Fab to={cliente ? `/processos/novo?cliente=${cliente}` : '/processos/novo'} rotulo="Processo" />
    </>
  )
}
