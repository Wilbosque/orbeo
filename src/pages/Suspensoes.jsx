import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import * as api from '#backend'
import Icone from '../components/Icone.jsx'
import { Campo, Carregando, Erro, Folha, Segmentado, Topo, Vazio, useCarregar, useToast } from '../components/ui.jsx'
import { data as fmtData } from '../lib/formato.js'
import {
  ABRANGENCIAS, FONTES, TIPOS, TRIBUNAIS, baixarArquivo, cobre, gerarICS, gradeDoMes, iso,
  relevante, rotuloAbrangencia, rotuloPeriodo,
} from '../lib/suspensao.js'

const MESES = ['Janeiro', 'Fevereiro', 'Março', 'Abril', 'Maio', 'Junho', 'Julho', 'Agosto', 'Setembro', 'Outubro', 'Novembro', 'Dezembro']
const SEMANA = ['D', 'S', 'T', 'Q', 'Q', 'S', 'S']
const hoje = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo' }).format(new Date())

// ---------- Peças ----------
function SeloTipo({ tipo }) {
  const t = TIPOS[tipo] || TIPOS.ato
  return <span className="selo" style={{ background: t.fundo, color: t.cor, borderColor: 'transparent' }}>{t.rotulo}</span>
}

export function ItemSuspensao({ s, onAbrir }) {
  const t = TIPOS[s.tipo] || TIPOS.ato
  return (
    <button className="cartao susp" onClick={() => onAbrir?.(s)} style={{ borderLeftColor: t.cor }}>
      <div className="cartao-topo"><b>{rotuloPeriodo(s)}</b><span className="faint" style={{ fontSize: '.78rem' }}>{FONTES[s.fonte]}</span></div>
      <h3>{s.motivo}</h3>
      <div className="linha">{rotuloAbrangencia(s)}{s.numero_ato ? ` · ${s.numero_ato}` : ''}</div>
      <div className="cartao-rodape"><SeloTipo tipo={s.tipo} />{s.hora_inicio && <span className="selo">Parcial</span>}</div>
    </button>
  )
}

function PrazosAfetados({ s }) {
  const pronta = s?.data_inicio && (s.abrangencia === 'nacional' || s.tribunal)
  const r = useCarregar(() => (pronta ? api.prazosAfetados(s) : Promise.resolve([])),
    [s?.data_inicio, s?.data_fim, s?.abrangencia, s?.tribunal, s?.comarca])
  if (!pronta || r.carregando || !r.dados) return null
  const lista = r.dados.filter(z => z.prazo_fatal >= s.data_inicio)
  if (!lista.length) return <div className="aviso info"><Icone nome="certo" />Nenhum prazo seu em aberto é alcançado por esta suspensão.</div>
  return (
    <div className="aviso alerta">
      <Icone nome="alerta" />
      <div>
        <b>{lista.length} prazo{lista.length > 1 ? 's' : ''} seu{lista.length > 1 ? 's' : ''} em aberto pode{lista.length > 1 ? 'm' : ''} mudar:</b>
        <ul style={{ margin: '6px 0 0', paddingLeft: 18 }}>
          {lista.slice(0, 5).map(z => <li key={z.id}><Link to={`/processos/${z.processo_id}`}>{z.tipo}</Link> · {z.cliente} · vence {fmtData(z.prazo_fatal)}</li>)}
        </ul>
        {lista.length > 5 && <small>e mais {lista.length - 5}.</small>}
      </div>
    </div>
  )
}

const VAZIO = { abrangencia: 'tribunal', tribunal: '', comarca: '', orgao: '', data_inicio: '', data_fim: '', hora_inicio: '', tipo: 'ato', motivo: '', numero_ato: '', link_ato: '' }

export function SuspensaoForm({ inicial, aoSalvar, aoExcluir, rotuloSalvar = 'Salvar suspensão', somenteLeitura }) {
  const [f, setF] = useState({ ...VAZIO, ...inicial, hora_inicio: inicial?.hora_inicio ? String(inicial.hora_inicio).slice(0, 5) : '' })
  const [parcial, setParcial] = useState(Boolean(inicial?.hora_inicio))
  const [tocado, setTocado] = useState(false)
  const [salvando, setSalvando] = useState(false)
  const set = (k, v) => setF(x => ({ ...x, [k]: v }))
  const precisaComarca = ['comarca', 'orgao'].includes(f.abrangencia)
  const erros = {
    tribunal: f.abrangencia !== 'nacional' && !f.tribunal ? 'Informe o tribunal.' : '',
    comarca: precisaComarca && !f.comarca ? 'Informe a comarca.' : '',
    orgao: f.abrangencia === 'orgao' && !f.orgao ? 'Informe a vara.' : '',
    data_inicio: !f.data_inicio ? 'Informe a data.' : '',
    data_fim: f.data_fim && f.data_fim < f.data_inicio ? 'O fim não pode ser antes do início.' : '',
    motivo: !f.motivo.trim() ? 'Descreva o motivo.' : '',
  }
  const temErro = Object.values(erros).some(Boolean)

  async function salvar(e) {
    e.preventDefault(); setTocado(true)
    if (temErro || somenteLeitura) return
    setSalvando(true)
    try { await aoSalvar({ ...f, tribunal: f.tribunal.toUpperCase().trim(), hora_inicio: parcial ? f.hora_inicio : '', data_fim: f.data_fim || f.data_inicio }) }
    finally { setSalvando(false) }
  }
  const e = k => (tocado ? erros[k] : '')

  return (
    <form className="form" onSubmit={salvar} noValidate>
      {somenteLeitura && <div className="aviso info"><Icone nome="info" />Regra nacional automática (lei federal ou CPC). Não pode ser alterada.</div>}
      <fieldset disabled={somenteLeitura} style={{ border: 0, padding: 0, margin: 0, display: 'grid', gap: 16 }}>
        <Campo rotulo="Abrangência">
          <Segmentado rotulo="Abrangência" valor={f.abrangencia} onChange={v => set('abrangencia', v)} opcoes={ABRANGENCIAS} />
        </Campo>
        {f.abrangencia !== 'nacional' && (
          <Campo rotulo="Tribunal" obrigatorio erro={e('tribunal')} ajuda="Sigla: TJBA, TJSP, TRT2, TRF1…">
            <input className={`entrada ${e('tribunal') ? 'invalida' : ''}`} list="lista-tribunais" value={f.tribunal || ''} onChange={x => set('tribunal', x.target.value.toUpperCase())} autoComplete="off" />
            <datalist id="lista-tribunais">{TRIBUNAIS.map(t => <option key={t} value={t} />)}</datalist>
          </Campo>
        )}
        {precisaComarca && (
          <Campo rotulo="Comarca / subseção" obrigatorio erro={e('comarca')}>
            <input className={`entrada ${e('comarca') ? 'invalida' : ''}`} value={f.comarca || ''} onChange={x => set('comarca', x.target.value)} />
          </Campo>
        )}
        {f.abrangencia === 'orgao' && (
          <Campo rotulo="Vara / órgão" obrigatorio erro={e('orgao')}>
            <input className={`entrada ${e('orgao') ? 'invalida' : ''}`} value={f.orgao || ''} onChange={x => set('orgao', x.target.value)} />
          </Campo>
        )}
        <div className="duas">
          <Campo rotulo="Início" obrigatorio erro={e('data_inicio')}>
            <input className={`entrada ${e('data_inicio') ? 'invalida' : ''}`} type="date" value={f.data_inicio} onChange={x => set('data_inicio', x.target.value)} />
          </Campo>
          <Campo rotulo="Fim" erro={erros.data_fim} ajuda="Vazio = só um dia">
            <input className={`entrada ${erros.data_fim ? 'invalida' : ''}`} type="date" value={f.data_fim || ''} min={f.data_inicio} onChange={x => set('data_fim', x.target.value)} />
          </Campo>
        </div>
        <label className="caixa-check">
          <input type="checkbox" checked={parcial} onChange={x => setParcial(x.target.checked)} />
          <div><b>Só parte do dia</b><span>Ex.: expediente suspenso a partir das 11h</span></div>
        </label>
        {parcial && (
          <Campo rotulo="A partir de"><input className="entrada" type="time" value={f.hora_inicio} onChange={x => set('hora_inicio', x.target.value)} /></Campo>
        )}
        <Campo rotulo="Tipo">
          <select className="entrada" value={f.tipo} onChange={x => set('tipo', x.target.value)}>
            {Object.entries(TIPOS).map(([v, t]) => <option key={v} value={v}>{t.rotulo}</option>)}
          </select>
        </Campo>
        <Campo rotulo="Motivo" obrigatorio erro={e('motivo')}>
          <input className={`entrada ${e('motivo') ? 'invalida' : ''}`} value={f.motivo} onChange={x => set('motivo', x.target.value)} placeholder="Ex.: Feriado municipal, indisponibilidade do PJe" />
        </Campo>
        <Campo rotulo="Ato que determinou">
          <input className="entrada" value={f.numero_ato || ''} onChange={x => set('numero_ato', x.target.value)} placeholder="Ex.: Decreto Judiciário nº 1.511/2026" />
        </Campo>
        <Campo rotulo="Link do ato">
          <input className="entrada" type="url" inputMode="url" value={f.link_ato || ''} onChange={x => set('link_ato', x.target.value)} placeholder="https://" />
        </Campo>
      </fieldset>
      {f.link_ato && somenteLeitura && <a className="link-btn" href={f.link_ato} target="_blank" rel="noreferrer">Abrir ato</a>}
      <PrazosAfetados s={{ ...f, data_fim: f.data_fim || f.data_inicio }} />
      {!somenteLeitura && <button className="btn primario bloco" disabled={salvando}>{salvando ? 'Salvando…' : rotuloSalvar}</button>}
      {aoExcluir && !somenteLeitura && <button type="button" className="btn perigo bloco" onClick={aoExcluir}><Icone nome="lixo" />Excluir suspensão</button>}
    </form>
  )
}

// ---------- Revisão das sugestões ----------
function CartaoSugestao({ sg, aoDecidir }) {
  const toast = useToast()
  const [ajustando, setAjustando] = useState(false)
  const [abertoTrecho, setAbertoTrecho] = useState(false)
  const d = sg.dados
  async function confirmar(ajustes) {
    try { await api.confirmarSugestaoSuspensao(sg.id, ajustes); toast('Suspensão confirmada e incluída no calendário.'); aoDecidir() }
    catch (e) { toast(e.message, 'erro') }
  }
  async function rejeitar() {
    try { await api.rejeitarSugestao(sg.id); toast('Sugestão rejeitada.'); aoDecidir() } catch (e) { toast(e.message, 'erro') }
  }
  if (ajustando) return (
    <div className="cartao">
      <div className="cartao-topo" style={{ marginBottom: 10 }}><b>Ajustar antes de confirmar</b><button className="link-btn" onClick={() => setAjustando(false)}>Voltar</button></div>
      <SuspensaoForm inicial={d} rotuloSalvar="Confirmar com ajustes" aoSalvar={f => {
        const ajustes = Object.fromEntries(Object.entries(f).filter(([k, v]) => (d[k] ?? '') !== (v ?? '')))
        return confirmar(Object.keys(ajustes).length ? ajustes : null)
      }} />
    </div>
  )
  return (
    <div className="cartao" style={{ borderLeft: `5px solid ${(TIPOS[d.tipo] || TIPOS.ato).cor}` }}>
      <div className="cartao-topo"><b>{rotuloPeriodo(d)}</b><SeloTipo tipo={d.tipo} /></div>
      <h3>{d.motivo}</h3>
      <div className="linha" style={{ whiteSpace: 'normal' }}>{rotuloAbrangencia(d)}{d.numero_ato ? ` · ${d.numero_ato}` : ''}</div>
      {sg.justificativa && (
        <div style={{ marginTop: 8 }}>
          <button className="link-btn" onClick={() => setAbertoTrecho(!abertoTrecho)}>{abertoTrecho ? 'Ocultar trecho do ato' : 'Ver trecho do ato'}</button>
          {abertoTrecho && <blockquote className="trecho">{sg.justificativa}</blockquote>}
        </div>
      )}
      {d.link_ato && <a className="link-btn" href={d.link_ato} target="_blank" rel="noreferrer" style={{ display: 'inline-block' }}>Abrir ato no site do tribunal</a>}
      <div style={{ marginTop: 8 }}><PrazosAfetados s={{ ...d, data_fim: d.data_fim || d.data_inicio }} /></div>
      <div className="acoes-sugestao">
        <button className="btn pequeno perigo" onClick={rejeitar}>Rejeitar</button>
        <button className="btn pequeno" onClick={() => setAjustando(true)}>Ajustar</button>
        <button className="btn pequeno primario" onClick={() => confirmar(null)}>Confirmar</button>
      </div>
    </div>
  )
}

// ---------- Calendário ----------
function Calendario({ ano, mes, lista, aoEscolherDia }) {
  const grade = useMemo(() => gradeDoMes(ano, mes), [ano, mes])
  const h = hoje()
  return (
    <div className="calendario" role="grid" aria-label={`${MESES[mes]} de ${ano}`}>
      {SEMANA.map((d, i) => <div key={i} className="cal-sem" role="columnheader">{d}</div>)}
      {grade.map(c => {
        const doDia = lista.filter(s => cobre(s, c.data))
        return (
          <button key={c.data} role="gridcell" onClick={() => aoEscolherDia(c.data)}
            className={`cal-dia ${c.doMes ? '' : 'fora'} ${c.fimDeSemana ? 'fds' : ''} ${c.data === h ? 'hoje' : ''} ${doDia.length ? 'tem' : ''}`}
            aria-label={`${c.dia}${doDia.length ? `, ${doDia.length} suspensão(ões)` : ''}`}>
            <span className="num">{c.dia}</span>
            <span className="cal-marcas">
              {doDia.slice(0, 3).map(s => {
                const t = TIPOS[s.tipo] || TIPOS.ato
                return <span key={s.id} className="cal-marca" style={{ background: t.fundo, color: t.cor, borderColor: t.cor }} title={`${rotuloAbrangencia(s)}: ${s.motivo}`}>
                  <span className="cal-marca-txt">{s.abrangencia === 'nacional' ? 'Nacional' : s.tribunal}{s.hora_inicio ? ' ½' : ''}</span>
                </span>
              })}
              {doDia.length > 3 && <span className="mais-marcas">+{doDia.length - 3}</span>}
            </span>
          </button>
        )
      })}
    </div>
  )
}

// ---------- Página ----------
export default function Suspensoes() {
  const toast = useToast()
  const agora = new Date()
  const [ano, setAno] = useState(agora.getFullYear())
  const [mes, setMes] = useState(agora.getMonth())
  const [modo, setModo] = useState('calendario')
  const [filtro, setFiltro] = useState('meus')
  const [dia, setDia] = useState(null)
  const [form, setForm] = useState(null)        // {inicial} para nova/editar
  const [revisar, setRevisar] = useState(false)

  const ini = modo === 'calendario' ? gradeDoMes(ano, mes)[0].data : hoje()
  const fim = modo === 'calendario' ? gradeDoMes(ano, mes)[41].data : iso(new Date(agora.getFullYear() + 1, agora.getMonth() + 1, 0))
  const r = useCarregar(() => Promise.all([api.listarSuspensoes(ini, fim), api.sugestoesSuspensao(), api.tribunaisEmUso()]), [ini, fim])
  const [todas, sugestoes, emUso] = r.dados || [[], [], []]
  useEffect(() => { if (sugestoes.length === 0) setRevisar(false) }, [sugestoes.length])

  const tribunaisFiltro = [...new Set(emUso.map(t => t.tribunal))].sort()
  const lista = todas.filter(s => filtro === 'todos' ? true : filtro === 'meus' ? relevante(s, emUso)
    : s.abrangencia === 'nacional' || s.tribunal === filtro)
  const doMes = lista.filter(s => s.data_fim >= iso(new Date(ano, mes, 1)) && s.data_inicio <= iso(new Date(ano, mes + 1, 0)))

  function navegar(delta) { const d = new Date(ano, mes + delta, 1); setAno(d.getFullYear()); setMes(d.getMonth()) }
  function exportar() {
    baixarArquivo(gerarICS(lista), `suspensoes-${modo === 'calendario' ? `${ano}-${String(mes + 1).padStart(2, '0')}` : 'proximos-12-meses'}.ics`, 'text/calendar')
    toast('Arquivo .ics gerado. Abra-o para importar no Google Agenda ou no calendário do celular.')
  }
  async function salvar(f) {
    try { await api.salvarSuspensao(f); toast(f.id ? 'Suspensão atualizada.' : 'Suspensão cadastrada.'); setForm(null); setDia(null); r.recarregar() }
    catch (e) { toast(e.message, 'erro') }
  }
  async function excluir(s) {
    if (!window.confirm('Excluir esta suspensão? Os prazos que dependem dela podem mudar.')) return
    try { await api.excluirSuspensao(s.id); toast('Suspensão excluída.'); setForm(null); setDia(null); r.recarregar() }
    catch (e) { toast(e.message, 'erro') }
  }
  const abrir = s => setForm({ inicial: s })
  const doDiaEscolhido = dia ? lista.filter(s => cobre(s, dia)) : []

  return (
    <>
      <Topo titulo="Suspensões de prazo" sub="Feriados, recessos e atos dos tribunais" voltar="/ajustes"
        acoes={<>
          <button className="icone-btn" onClick={exportar} aria-label="Exportar para calendário (.ics)" title="Exportar para Google Agenda (.ics)"><Icone nome="exportar" /></button>
          <button className="icone-btn" onClick={() => setForm({ inicial: { data_inicio: hoje() } })} aria-label="Cadastrar suspensão"><Icone nome="mais_add" /></button>
        </>} />

      {sugestoes.length > 0 && (
        <button className="cartao faixa-sugestoes" onClick={() => setRevisar(true)}>
          <Icone nome="radar" width="24" height="24" />
          <div style={{ flex: 1 }}><b>{sugestoes.length} suspens{sugestoes.length > 1 ? 'ões encontradas' : 'ão encontrada'} nos diários</b>
            <div className="linha">Revise e confirme para entrar no calendário e na contagem dos prazos.</div></div>
          <Icone nome="seta" width="20" height="20" />
        </button>
      )}

      <div style={{ display: 'grid', gap: 10, marginTop: 12 }}>
        <Segmentado rotulo="Modo de visualização" valor={modo} onChange={setModo} opcoes={[['calendario', 'Calendário'], ['lista', 'Próximos 12 meses']]} />
        <div className="chips" style={{ paddingBottom: 0 }}>
          <button className={`chip ${filtro === 'meus' ? 'ativo' : ''}`} onClick={() => setFiltro('meus')} title="Nacionais e tribunais onde há processos ativos">Meus tribunais</button>
          {tribunaisFiltro.map(t => <button key={t} className={`chip ${filtro === t ? 'ativo' : ''}`} onClick={() => setFiltro(t)}>{t}</button>)}
          <button className={`chip ${filtro === 'todos' ? 'ativo' : ''}`} onClick={() => setFiltro('todos')}>Todos os tribunais</button>
        </div>
      </div>

      {r.erro && <Erro erro={r.erro} tentar={r.recarregar} />}
      {r.carregando && !r.dados ? <Carregando n={2} /> : modo === 'calendario' ? (
        <>
          <div className="cal-topo">
            <button className="icone-btn" onClick={() => navegar(-1)} aria-label="Mês anterior"><Icone nome="voltar" /></button>
            <h2>{MESES[mes]} {ano}</h2>
            <button className="icone-btn" onClick={() => navegar(1)} aria-label="Próximo mês"><Icone nome="seta" /></button>
            <button className="btn pequeno" onClick={() => { setAno(agora.getFullYear()); setMes(agora.getMonth()) }}>Hoje</button>
          </div>
          <Calendario ano={ano} mes={mes} lista={lista} aoEscolherDia={setDia} />
          <div className="legenda">{Object.entries(TIPOS).map(([k, t]) => <span key={k}><i style={{ background: t.cor }} />{t.rotulo}</span>)}<span>½ = parte do dia</span></div>
          <div className="secao"><h2>Neste mês ({doMes.length})</h2></div>
          {doMes.length === 0 ? <div className="cartao muted">Nenhuma suspensão neste mês para o filtro escolhido.</div>
            : <div className="lista grade">{doMes.map(s => <ItemSuspensao key={s.id} s={s} onAbrir={abrir} />)}</div>}
        </>
      ) : (
        lista.length === 0 ? <Vazio icone="relogio" titulo="Nenhuma suspensão nos próximos 12 meses" /> :
          <div className="lista grade" style={{ marginTop: 12 }}>{lista.map(s => <ItemSuspensao key={s.id} s={s} onAbrir={abrir} />)}</div>
      )}

      <Folha titulo={dia ? new Date(dia + 'T12:00').toLocaleDateString('pt-BR', { weekday: 'long', day: 'numeric', month: 'long' }) : ''} aberta={Boolean(dia) && !form} fechar={() => setDia(null)}>
        {doDiaEscolhido.length === 0 ? <p className="muted" style={{ marginTop: 0 }}>Nenhuma suspensão neste dia{filtro !== 'todos' ? ' para o filtro escolhido' : ''}.</p>
          : <div className="lista">{doDiaEscolhido.map(s => <ItemSuspensao key={s.id} s={s} onAbrir={abrir} />)}</div>}
        <button className="btn primario bloco" style={{ marginTop: 14 }} onClick={() => setForm({ inicial: { data_inicio: dia } })}><Icone nome="mais_add" />Cadastrar suspensão neste dia</button>
      </Folha>

      <Folha titulo={form?.inicial?.id ? (form.inicial.fonte === 'regra' ? 'Suspensão nacional' : 'Editar suspensão') : 'Nova suspensão'} aberta={Boolean(form)} fechar={() => setForm(null)}>
        {form && <SuspensaoForm key={form.inicial?.id || form.inicial?.data_inicio} inicial={form.inicial} aoSalvar={salvar}
          somenteLeitura={form.inicial?.fonte === 'regra'} aoExcluir={form.inicial?.id ? () => excluir(form.inicial) : null} />}
      </Folha>

      <Folha titulo="Sugestões encontradas nos diários" aberta={revisar} fechar={() => setRevisar(false)}>
        <p className="muted" style={{ marginTop: 0 }}>A varredura leu os atos dos tribunais e encontrou estas suspensões. Nada entra no calendário nem muda prazo sem a sua confirmação. A decisão vale para os dois advogados.</p>
        <div className="lista">{sugestoes.map(sg => <CartaoSugestao key={sg.id} sg={sg} aoDecidir={r.recarregar} />)}</div>
      </Folha>
    </>
  )
}
