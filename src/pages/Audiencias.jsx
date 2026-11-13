import { useMemo, useState } from 'react'
import * as api from '#backend'
import Icone from '../components/Icone.jsx'
import { AudienciaForm, ItemAudiencia } from '../components/Audiencias.jsx'
import { Carregando, Erro, Folha, Segmentado, Topo, Vazio, useCarregar, useToast } from '../components/ui.jsx'
import { TIPOS_AUD, diaSP, gerarICSAudiencias, hojeSP, rotuloDia, separarISO } from '../lib/audiencia.js'
import { baixarArquivo, gradeDoMes } from '../lib/suspensao.js'

const MESES = ['Janeiro', 'Fevereiro', 'Março', 'Abril', 'Maio', 'Junho', 'Julho', 'Agosto', 'Setembro', 'Outubro', 'Novembro', 'Dezembro']

function agrupar(lista) {
  const g = new Map()
  for (const a of lista) { const d = diaSP(a.data_hora); if (!g.has(d)) g.set(d, []); g.get(d).push(a) }
  return [...g.entries()]
}

function CalendarioAud({ lista, ano, mes, aoDia }) {
  const grade = useMemo(() => gradeDoMes(ano, mes), [ano, mes])
  const h = hojeSP()
  return (
    <div className="calendario">
      {['D', 'S', 'T', 'Q', 'Q', 'S', 'S'].map((d, i) => <div key={i} className="cal-sem">{d}</div>)}
      {grade.map(c => {
        const doDia = lista.filter(a => diaSP(a.data_hora) === c.data)
        return (
          <button key={c.data} onClick={() => aoDia(c.data)} className={`cal-dia ${c.doMes ? '' : 'fora'} ${c.fimDeSemana ? 'fds' : ''} ${c.data === h ? 'hoje' : ''} ${doDia.length ? 'tem' : ''}`}>
            <span className="num">{c.dia}</span>
            <span className="cal-marcas">
              {doDia.slice(0, 3).map(a => (
                <span key={a.id} className="cal-marca" style={{ background: '#eeecff', color: '#5a48f0', borderColor: '#6c5bff' }}>
                  <span className="cal-marca-txt">{separarISO(a.data_hora).hora} {a.cliente.split(' ')[0]}</span>
                </span>
              ))}
              {doDia.length > 3 && <span className="mais-marcas">+{doDia.length - 3}</span>}
            </span>
          </button>
        )
      })}
    </div>
  )
}

export default function Audiencias() {
  const toast = useToast()
  const [modo, setModo] = useState('proximas')
  const agora = new Date()
  const [ano, setAno] = useState(agora.getFullYear())
  const [mes, setMes] = useState(agora.getMonth())
  const [form, setForm] = useState(null)
  const [dia, setDia] = useState(null)
  const [sugAberta, setSugAberta] = useState(null)

  const r = useCarregar(() => Promise.all([api.listarAudiencias(), api.sugestoesAudiencia()]), [])
  const [todas, sugestoes] = r.dados || [[], []]
  const limite = new Date(Date.now() - 3 * 3600000).toISOString()
  const proximas = todas.filter(a => a.status === 'agendada' && a.data_hora >= limite)
  const pendentes = todas.filter(a => a.status === 'agendada' && a.data_hora < limite)
  const passadas = todas.filter(a => a.status !== 'agendada').reverse()

  async function salvar(a) {
    await api.salvarAudiencia(a)
    toast(a.id ? 'Audiência atualizada.' : 'Audiência cadastrada.'); setForm(null); setDia(null); r.recarregar()
  }
  async function excluir(a) {
    if (!window.confirm('Excluir esta audiência?')) return
    try { await api.excluirAudiencia(a.id); toast('Audiência excluída.'); setForm(null); r.recarregar() } catch (e) { toast(e.message, 'erro') }
  }
  async function aceitar(sg, a) {
    await api.aceitarSugestaoAudiencia(sg, a); toast('Audiência cadastrada a partir da sugestão.'); setSugAberta(null); r.recarregar()
  }
  async function rejeitar(sg) {
    try { await api.rejeitarSugestao(sg.id); toast('Sugestão descartada.'); setSugAberta(null); r.recarregar() } catch (e) { toast(e.message, 'erro') }
  }
  function exportar() {
    if (!proximas.length) return toast('Não há audiências futuras para exportar.')
    baixarArquivo(gerarICSAudiencias(proximas), 'audiencias-orbeo.ics', 'text/calendar')
    toast('Arquivo .ics gerado, com lembretes 1 dia e 2 horas antes. Abra para importar na sua agenda.')
  }
  const abrir = a => setForm({ inicial: a })
  const navegar = d => { const x = new Date(ano, mes + d, 1); setAno(x.getFullYear()); setMes(x.getMonth()) }

  return (
    <>
      <Topo titulo="Audiências" sub={r.dados ? `${proximas.length} agendada${proximas.length === 1 ? '' : 's'}${pendentes.length ? ` · ${pendentes.length} sem resultado` : ''}` : ' '}
        acoes={<button className="icone-btn" onClick={exportar} aria-label="Exportar para agenda (.ics)" title="Exportar para Google Agenda (.ics)"><Icone nome="exportar" /></button>} />

      {sugestoes.length > 0 && (
        <div className="lista" style={{ marginBottom: 12 }}>
          {sugestoes.map(sg => (
            <button key={sg.id} className="cartao faixa-sugestoes" onClick={() => setSugAberta(sg)}>
              <Icone nome="radar" width="24" height="24" />
              <div style={{ flex: 1, minWidth: 0 }}><b>Audiência designada · {sg.processo.cliente_nome}</b>
                <div className="linha">O DataJud indica audiência de {TIPOS_AUD[sg.dados.tipo]?.toLowerCase()} no processo {sg.processo.numero_cnj}. Informe a data e a hora.</div></div>
              <Icone nome="seta" width="20" height="20" />
            </button>
          ))}
        </div>
      )}

      <Segmentado rotulo="Visualização" valor={modo} onChange={setModo}
        opcoes={[['proximas', 'Próximas'], ['calendario', 'Calendário'], ['passadas', 'Realizadas']]} />

      {r.erro && <Erro erro={r.erro} tentar={r.recarregar} />}
      {r.carregando && !r.dados ? <Carregando n={3} /> : modo === 'proximas' ? (
        proximas.length === 0 ? <Vazio icone="martelo" titulo="Nenhuma audiência agendada" texto="Cadastre pelo botão abaixo ou no próprio processo." /> :
          agrupar(proximas).map(([d, lista]) => (
            <div key={d}>
              <div className="secao"><h2>{rotuloDia(d)}</h2></div>
              <div className="lista grade">{lista.map(a => <ItemAudiencia key={a.id} a={a} onAbrir={abrir} />)}</div>
            </div>
          ))
      ) : modo === 'calendario' ? (
        <>
          <div className="cal-topo">
            <button className="icone-btn" onClick={() => navegar(-1)} aria-label="Mês anterior"><Icone nome="voltar" /></button>
            <h2>{MESES[mes]} {ano}</h2>
            <button className="icone-btn" onClick={() => navegar(1)} aria-label="Próximo mês"><Icone nome="seta" /></button>
            <button className="btn pequeno" onClick={() => { setAno(agora.getFullYear()); setMes(agora.getMonth()) }}>Hoje</button>
          </div>
          <CalendarioAud lista={todas.filter(a => a.status !== 'cancelada')} ano={ano} mes={mes} aoDia={setDia} />
        </>
      ) : (
        <>
          {pendentes.length > 0 && (
            <>
              <div className="secao"><h2>Aguardando registro do resultado</h2></div>
              <div className="lista grade">{pendentes.map(a => <ItemAudiencia key={a.id} a={a} onAbrir={abrir} />)}</div>
            </>
          )}
          <div className="secao"><h2>Histórico</h2></div>
          {passadas.length === 0 ? <div className="cartao muted">Nenhuma audiência encerrada ainda.</div> :
            <div className="lista grade">{passadas.map(a => <ItemAudiencia key={a.id} a={a} onAbrir={abrir} />)}</div>}
        </>
      )}

      <button className="fab" onClick={() => setForm({ inicial: {} })}><Icone nome="mais_add" />Audiência</button>

      <Folha titulo={dia ? rotuloDia(dia) : ''} aberta={Boolean(dia) && !form} fechar={() => setDia(null)}>
        {(() => { const l = todas.filter(a => dia && diaSP(a.data_hora) === dia); return l.length
          ? <div className="lista">{l.map(a => <ItemAudiencia key={a.id} a={a} onAbrir={abrir} />)}</div>
          : <p className="muted" style={{ marginTop: 0 }}>Nenhuma audiência neste dia.</p> })()}
        <button className="btn primario bloco" style={{ marginTop: 14 }} onClick={() => setForm({ inicial: { dia } })}><Icone nome="mais_add" />Cadastrar audiência neste dia</button>
      </Folha>

      <Folha titulo={form?.inicial?.id ? 'Audiência' : 'Nova audiência'} aberta={Boolean(form)} fechar={() => setForm(null)}>
        {form && (
          <>
            {form.inicial?.id && (
              <div className="muted" style={{ marginTop: -8, marginBottom: 12 }}>
                {form.inicial.cliente} · {form.inicial.numero_cnj}
                {form.inicial.link && <> · <a className="link-btn" href={form.inicial.link} target="_blank" rel="noreferrer">Entrar na sala</a></>}
              </div>
            )}
            <AudienciaForm key={form.inicial?.id || 'nova'} inicial={form.inicial} processoFixo={form.inicial?.processo_id}
              aoSalvar={salvar} aoExcluir={form.inicial?.id ? () => excluir(form.inicial) : null} />
          </>
        )}
      </Folha>

      <Folha titulo="Cadastrar audiência sugerida" aberta={Boolean(sugAberta)} fechar={() => setSugAberta(null)}>
        {sugAberta && (
          <>
            <div className="aviso info" style={{ marginBottom: 12 }}><Icone nome="info" /><div>{sugAberta.justificativa}</div></div>
            <AudienciaForm inicial={{ tipo: sugAberta.dados.tipo }} processoFixo={sugAberta.processo_id} rotulo="Cadastrar audiência" aoSalvar={a => aceitar(sugAberta, a)} />
            <button className="btn bloco" style={{ marginTop: 10 }} onClick={() => rejeitar(sugAberta)}>Não é audiência nova · descartar</button>
          </>
        )}
      </Folha>
    </>
  )
}
