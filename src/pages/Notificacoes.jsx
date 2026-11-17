import { useEffect, useState } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import * as api from '#backend'
import { usePerfil } from '../App.jsx'
import Icone from '../components/Icone.jsx'
import { Campo, Carregando, Erro, Segmentado, Topo, Vazio, useCarregar, useToast } from '../components/ui.jsx'
import { CartaoAparelho } from './Ajustes.jsx'
import { avisarMudancaNotificacoes } from '../components/Sino.jsx'

const ICONE = { prazos: 'relogio', audiencia: 'martelo', publicacao: 'processos', novos: 'radar', sugestoes: 'calendario', teste: 'sino' }

function quando(iso) {
  const d = new Date(iso), agora = new Date()
  const min = Math.round((agora - d) / 60000)
  if (min < 1) return 'agora'
  if (min < 60) return `há ${min} min`
  const mesmoDia = d.toLocaleDateString('pt-BR', { timeZone: 'America/Sao_Paulo' }) === agora.toLocaleDateString('pt-BR', { timeZone: 'America/Sao_Paulo' })
  const hora = d.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit', timeZone: 'America/Sao_Paulo' })
  if (mesmoDia) return `hoje, ${hora}`
  return `${d.toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit', timeZone: 'America/Sao_Paulo' })}, ${hora}`
}

function Recebidas() {
  const nav = useNavigate()
  const toast = useToast()
  const r = useCarregar(() => api.listarNotificacoes(), [])
  const lista = r.dados || []
  const naoLidas = lista.filter(n => !n.lida_em).length
  async function abrir(n) {
    if (!n.lida_em) { await api.marcarNotificacoesLidas([n.id]).catch(() => {}); avisarMudancaNotificacoes() }
    if (n.url) nav((n.url || '#/').replace(/^#/, '') || '/')
  }
  async function todas() {
    try { await api.marcarNotificacoesLidas(null); avisarMudancaNotificacoes(); r.recarregar(); toast('Todas marcadas como lidas.') } catch (e) { toast(e.message, 'erro') }
  }
  if (r.erro) return <Erro erro={r.erro} tentar={r.recarregar} />
  if (r.carregando && !r.dados) return <Carregando n={4} />
  if (!lista.length) return <Vazio icone="sino" titulo="Nenhuma notificação ainda" texto="Os avisos de prazos, audiências, publicações e processos novos aparecem aqui, mesmo que o celular não receba." />
  return (
    <>
      {naoLidas > 0 && (
        <div style={{ display: 'flex', alignItems: 'center', margin: '4px 0 10px' }}>
          <span className="muted" style={{ flex: 1 }}>{naoLidas} não lida{naoLidas > 1 ? 's' : ''}</span>
          <button className="link-btn" onClick={todas}>Marcar todas como lidas</button>
        </div>
      )}
      <div className="lista">
        {lista.map(n => (
          <button key={n.id} className={`cartao notificacao ${n.lida_em ? '' : 'nao-lida'}`} onClick={() => abrir(n)}>
            <span className="notif-icone"><Icone nome={ICONE[n.tipo] || 'sino'} width="18" height="18" /></span>
            <span className="notif-corpo">
              <span className="notif-topo"><b>{n.titulo}</b><small>{quando(n.criado_em)}</small></span>
              {n.texto && <span className="notif-texto">{n.texto}</span>}
              {n.push_aparelhos > 0
                ? <small className="notif-entrega ok"><Icone nome="certo" width="13" height="13" />Chegou em {n.push_aparelhos} aparelho{n.push_aparelhos > 1 ? 's' : ''}</small>
                : n.push_motivo && <small className="notif-entrega falhou"><Icone nome="alerta" width="13" height="13" />Não chegou ao celular: {n.push_motivo}</small>}
            </span>
            {!n.lida_em && <span className="ponto-novo" aria-label="Não lida" />}
          </button>
        ))}
      </div>
    </>
  )
}

const HORAS = (de, ate) => Array.from({ length: ate - de + 1 }, (_, i) => de + i)

function Interruptor({ titulo, texto, valor, onChange, icone }) {
  return (
    <label className="caixa-check pref">
      <input type="checkbox" checked={valor} onChange={e => onChange(e.target.checked)} />
      <span style={{ flex: 1 }}><b><Icone nome={icone} width="15" height="15" style={{ verticalAlign: '-2px', marginRight: 6 }} />{titulo}</b><span>{texto}</span></span>
    </label>
  )
}

function Preferencias() {
  const { perfil } = usePerfil()
  const toast = useToast()
  const [p, setP] = useState(null)
  const [salvando, setSalvando] = useState(false)
  const [aparelhos, setAparelhos] = useState([])
  useEffect(() => { api.minhasPreferencias().then(setP).catch(e => toast(e.message, 'erro')); api.meusAparelhos().then(setAparelhos).catch(() => {}) }, [])
  if (!p) return <Carregando n={3} />
  const muda = (k, v) => setP({ ...p, [k]: v })
  const temVisaoGeral = perfil.espacos?.some(e => e.visao_geral) || perfil.visao_geral
  async function salvar() {
    setSalvando(true)
    try { await api.salvarPreferencias(p); toast('Preferências salvas. Valem a partir da próxima rodada de avisos.') }
    catch (e) { toast(e.message, 'erro') } finally { setSalvando(false) }
  }
  return (
    <>
      <CartaoAparelho />
      {aparelhos.length > 0 && (
        <div className="cartao" style={{ marginTop: 10 }}>
          <b>Aparelhos que recebem os seus avisos</b>
          <ul className="avisos-lista">
            {aparelhos.map(a => (
              <li key={a.id}><Icone nome="sino" width="16" height="16" />
                <span><b>{a.aparelho || 'Aparelho'}</b> · ativado em {new Date(a.criado_em).toLocaleDateString('pt-BR')}
                  {a.ultimo_envio ? ` · último aviso ${quando(a.ultimo_envio)}` : ' · ainda não recebeu aviso'}
                  {a.falhas > 0 && <span style={{ color: 'var(--perigo, #DC2626)' }}> · {a.falhas} falha{a.falhas > 1 ? 's' : ''} seguida{a.falhas > 1 ? 's' : ''}</span>}</span>
              </li>
            ))}
          </ul>
        </div>
      )}

      <div className="secao"><h2>O que você quer receber</h2></div>
      <p className="muted" style={{ marginTop: -4 }}>Vale só para você, em todos os seus aparelhos. Tudo também fica registrado em Recebidas.</p>
      <div className="lista">
        <div className="cartao">
          <Interruptor icone="relogio" titulo="Prazos" texto="Um resumo por dia com os prazos que vencem." valor={p.prazos} onChange={v => muda('prazos', v)} />
          {p.prazos && (
            <div className="pref-detalhes">
              <div className="duas">
                <Campo rotulo="Horário do resumo">
                  <select value={p.prazos_hora} onChange={e => muda('prazos_hora', +e.target.value)}>{HORAS(5, 12).map(h => <option key={h} value={h}>{h}h</option>)}</select>
                </Campo>
                <Campo rotulo="Quais prazos">
                  <select value={p.prazos_dias} onChange={e => muda('prazos_dias', +e.target.value)}>
                    <option value={0}>vencem hoje</option><option value={1}>hoje e amanhã</option>
                    <option value={2}>próximos 2 dias</option><option value={3}>próximos 3 dias</option><option value={5}>próximos 5 dias</option>
                  </select>
                </Campo>
              </div>
              <label className="caixa-check compacta"><input type="checkbox" checked={p.prazos_elaborar} onChange={e => muda('prazos_elaborar', e.target.checked)} />
                <span><b>Avisar também os prazos marcados para elaborar hoje</b></span></label>
            </div>
          )}
        </div>

        <div className="cartao">
          <Interruptor icone="martelo" titulo="Audiências" texto="Lembretes antes de cada audiência." valor={p.audiencias} onChange={v => muda('audiencias', v)} />
          {p.audiencias && (
            <div className="pref-detalhes duas">
              <Campo rotulo="Na véspera">
                <select value={p.aud_vespera_hora ?? ''} onChange={e => muda('aud_vespera_hora', e.target.value === '' ? null : +e.target.value)}>
                  <option value="">não avisar</option>{HORAS(12, 22).map(h => <option key={h} value={h}>às {h}h</option>)}
                </select>
              </Campo>
              <Campo rotulo="No dia">
                <select value={p.aud_horas_antes} onChange={e => muda('aud_horas_antes', +e.target.value)}>
                  <option value={0}>não avisar</option>{[1, 2, 3, 4, 6, 12].map(h => <option key={h} value={h}>{h} hora{h > 1 ? 's' : ''} antes</option>)}
                </select>
              </Campo>
            </div>
          )}
        </div>

        <div className="cartao"><Interruptor icone="processos" titulo="Publicações novas no DJEN" texto="Assim que a consulta diária encontrar (entre 6h e 8h)." valor={p.publicacoes} onChange={v => muda('publicacoes', v)} /></div>
        <div className="cartao"><Interruptor icone="radar" titulo="Processos novos de clientes" texto="Quando a busca diária no DJEN (8h) encontrar um processo de cliente que ainda não está no Orbeo." valor={p.novos} onChange={v => muda('novos', v)} /></div>
        <div className="cartao">
          <Interruptor icone="calendario" titulo="Sugestões para confirmar" texto="Suspensões de prazo e audiências aguardando confirmação." valor={p.sugestoes} onChange={v => muda('sugestoes', v)} />
          {p.sugestoes && (
            <div className="pref-detalhes">
              <Campo rotulo="Horário">
                <select value={p.sugestoes_hora} onChange={e => muda('sugestoes_hora', +e.target.value)}>{HORAS(6, 20).map(h => <option key={h} value={h}>{h}h</option>)}</select>
              </Campo>
            </div>
          )}
        </div>

        {temVisaoGeral && (
          <div className="cartao">
            <b>De quais processos</b>
            <p className="muted" style={{ margin: '4px 0 10px' }}>Você tem visão geral no escritório e pode receber avisos de todos os processos, não só dos seus.</p>
            <Segmentado rotulo="Abrangência" valor={p.escopo} onChange={v => muda('escopo', v)} opcoes={[['meus', 'Só os meus'], ['escritorio', 'Todos do escritório']]} />
          </div>
        )}
      </div>
      <button className="btn primario bloco" style={{ marginTop: 14 }} disabled={salvando} onClick={salvar}>{salvando ? 'Salvando…' : 'Salvar preferências'}</button>
    </>
  )
}

export default function Notificacoes() {
  const [params, setParams] = useSearchParams()
  const aba = params.get('aba') === 'preferencias' ? 'preferencias' : 'recebidas'
  return (
    <>
      <Topo titulo="Notificações" sub="Seus avisos e o que você quer receber" voltar="/" />
      <div style={{ marginBottom: 12 }}>
        <Segmentado rotulo="Seção" valor={aba} onChange={v => setParams(v === 'recebidas' ? {} : { aba: v }, { replace: true })}
          opcoes={[['recebidas', 'Recebidas'], ['preferencias', 'O que receber']]} />
      </div>
      {aba === 'recebidas' ? <Recebidas /> : <Preferencias />}
    </>
  )
}
