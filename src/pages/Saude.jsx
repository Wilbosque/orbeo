import * as api from '#backend'
import Icone from '../components/Icone.jsx'
import { Carregando, Erro, Topo, Vazio, useCarregar } from '../components/ui.jsx'

const COR = { ok: 'var(--ok)', parcial: '#f59e0b', erro: 'var(--danger)', rodando: 'var(--violeta)' }
const ROT = { ok: 'Concluída', parcial: 'Parcial', erro: 'Erro', rodando: 'Em andamento' }
const FONTE = { datajud: 'DataJud', djen: 'DJEN' }

export default function Saude() {
  const r = useCarregar(() => api.saudeConsultas(), [])
  const lista = r.dados || []
  const ultimaOk = lista.find(x => x.status === 'ok' || x.status === 'parcial')
  return (
    <>
      <Topo titulo="Saúde das consultas" sub="Rodadas automáticas no DataJud e no DJEN" voltar="/ajustes"
        acoes={<button className="icone-btn" onClick={r.recarregar} aria-label="Recarregar"><Icone nome="atualizar" /></button>} />
      <div className="aviso info" style={{ marginBottom: 12 }}>
        <Icone nome="info" />
        <div>O DataJud é consultado todos os dias entre 03h e 06h, em lotes, abaixo do limite do CNJ. Se nenhuma rodada aparecer por mais de um dia, o agendamento pode não estar ativo.</div>
      </div>
      {ultimaOk && (
        <div className="kpis" style={{ marginBottom: 6 }}>
          <div className="kpi"><span className="rotulo">Última rodada</span><span className="valor" style={{ fontSize: '1.2rem' }}>{new Date(ultimaOk.iniciada_em).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' })}</span></div>
          <div className="kpi"><span className="rotulo">Novidades nas últimas rodadas</span><span className="valor">{lista.slice(0, 10).reduce((s, x) => s + (x.novidades || 0), 0)}</span></div>
        </div>
      )}
      {r.erro && <Erro erro={r.erro} tentar={r.recarregar} />}
      {r.carregando && !r.dados ? <Carregando n={3} /> : lista.length === 0 ? (
        <Vazio icone="saude" titulo="Nenhuma rodada registrada ainda" texto="A primeira rodada automática acontece na próxima madrugada, depois que o agendamento for ativado." />
      ) : (
        <div className="lista">
          {lista.map(x => (
            <div key={x.id} className="cartao sinc">
              <span className="ponto" style={{ background: COR[x.status] }} title={ROT[x.status]} />
              <div style={{ minWidth: 0 }}>
                <b>{FONTE[x.fonte] || x.fonte} · {ROT[x.status]}</b>
                <div className="linha" style={{ whiteSpace: 'normal' }}>{x.mensagem}</div>
              </div>
              <div style={{ textAlign: 'right', fontSize: '.8rem' }} className="muted">
                {new Date(x.iniciada_em).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' })}<br />
                {x.requisicoes} consulta{x.requisicoes === 1 ? '' : 's'} · {x.novidades} nova{x.novidades === 1 ? '' : 's'}
              </div>
            </div>
          ))}
        </div>
      )}
    </>
  )
}
