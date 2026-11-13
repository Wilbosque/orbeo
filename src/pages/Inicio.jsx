import { Link } from 'react-router-dom'
import * as api from '#backend'
import { usePerfil } from '../App.jsx'
import Icone from '../components/Icone.jsx'
import Logo from '../components/Logo.jsx'
import { Carregando, Erro, Topo, useCarregar } from '../components/ui.jsx'
import { POLOS, data } from '../lib/formato.js'

function saudacao() {
  const h = Number(new Intl.DateTimeFormat('pt-BR', { hour: 'numeric', hour12: false, timeZone: 'America/Sao_Paulo' }).format(new Date()))
  return h < 12 ? 'Bom dia' : h < 18 ? 'Boa tarde' : 'Boa noite'
}

function diasEntre(a, b) { return Math.round((new Date(b + 'T12:00') - new Date(a + 'T12:00')) / 86400000) }

function classificar(z, hoje) {
  if (z.prazo_fatal < hoje) { const d = diasEntre(z.prazo_fatal, hoje); return { cls: 'vencido', rot: 'Vencido', sub: `há ${d} dia${d > 1 ? 's' : ''}` } }
  if (z.prazo_fatal === hoje) return { cls: 'hoje', rot: 'Vence hoje', sub: 'prazo fatal' }
  const d = diasEntre(hoje, z.prazo_fatal)
  return { cls: 'elaborar', rot: 'Elaborar hoje', sub: `vence em ${d} dia${d > 1 ? 's' : ''}` }
}

function ItemPrazo({ z, hoje }) {
  const c = classificar(z, hoje)
  return (
    <Link to={`/processos/${z.processo_id}`} className={`cartao prazo ${c.cls}`}>
      <div className="corpo">
        <div className="tipo">{z.tipo}</div>
        <div className="ref">{z.cliente} · {POLOS[z.polo]}</div>
        <div className="ref mono">{z.numero_cnj}</div>
      </div>
      <div className="quando"><b>{c.rot}</b><span>{c.sub}</span><br /><span>{data(z.prazo_fatal)}</span></div>
    </Link>
  )
}

export default function Inicio() {
  const { perfil } = usePerfil()
  const r = useCarregar(() => Promise.all([api.resumo(), api.prazosDoDia(), api.listarProcessos()]), [])
  const [res, prazos, processos] = r.dados || []
  const hoje = api.hojeSP()
  const vencidos = (prazos || []).filter(z => z.prazo_fatal < hoje)
  const vencemHoje = (prazos || []).filter(z => z.prazo_fatal === hoje)
  const elaborarHoje = (prazos || []).filter(z => z.prazo_fatal > hoje)
  const comNovidade = (processos || []).filter(p => p.novidades > 0).slice(0, 5)
  const dataHoje = new Date().toLocaleDateString('pt-BR', { weekday: 'long', day: 'numeric', month: 'long', timeZone: 'America/Sao_Paulo' })

  return (
    <>
      <div className="so-celular topo-marca"><Logo /></div>
      <Topo titulo={`${saudacao()}, ${perfil.nome.split(' ')[0]}`} sub={dataHoje} />
      {r.erro && <Erro erro={r.erro} tentar={r.recarregar} />}
      {r.carregando && !r.dados ? <Carregando n={3} /> : res && (
        <>
          <div className="kpis">
            <a href="#prazos-do-dia" className={`kpi ${vencidos.length || vencemHoje.length ? 'alerta-kpi' : ''}`}>
              <span className="rotulo">Prazos do dia</span>
              <span className="valor">{vencemHoje.length + elaborarHoje.length}</span>
              {vencidos.length > 0 && <small>+ {vencidos.length} vencido{vencidos.length > 1 ? 's' : ''}</small>}
            </a>
            <Link to="/processos?situacao=ativo" className="kpi destaque"><span className="rotulo">Processos ativos</span><span className="valor">{res.ativos}</span></Link>
            <Link to="/processos?novidades=1" className="kpi"><span className="rotulo">Publicações novas</span><span className="valor">{res.publicacoesNovas}</span></Link>
            <Link to="/suspensoes" className="kpi"><span className="rotulo">Sugestões para confirmar</span><span className="valor">{res.sugestoesPendentes}</span></Link>
          </div>

          <div className="secao" id="prazos-do-dia"><h2>Prazos do dia</h2></div>
          {prazos.length === 0 ? (
            <div className="cartao muted" style={{ display: 'flex', gap: 10, alignItems: 'center' }}><Icone nome="certo" width="20" height="20" />Nenhum prazo vence ou está marcado para elaborar hoje.</div>
          ) : (
            <div className="lista">
              {[...vencidos, ...vencemHoje, ...elaborarHoje].map(z => <ItemPrazo key={z.id} z={z} hoje={hoje} />)}
            </div>
          )}

          <div className="secao"><h2>Processos com novidades</h2><Link className="link-btn" to="/processos?novidades=1">Ver todos</Link></div>
          {comNovidade.length === 0 ? (
            <div className="cartao muted">Nenhuma movimentação ou publicação nova nos seus processos.</div>
          ) : (
            <div className="lista">
              {comNovidade.map(p => (
                <Link key={p.id} to={`/processos/${p.id}`} className="cartao">
                  <div className="cartao-topo"><span className="mono numero">{p.numero_cnj}</span><span className="selo novo">{p.novidades} nova{p.novidades > 1 ? 's' : ''}</span></div>
                  <h3>{p.cliente_nome}</h3>
                  <div className="linha">{POLOS[p.polo]} · {p.parte_contraria || 'Parte contrária não informada'}</div>
                </Link>
              ))}
            </div>
          )}
        </>
      )}
    </>
  )
}
