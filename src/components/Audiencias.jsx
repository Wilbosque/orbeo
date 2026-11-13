import { useState } from 'react'
import { Link } from 'react-router-dom'
import * as api from '#backend'
import Icone from './Icone.jsx'
import { Campo, Segmentado, useCarregar, useToast } from './ui.jsx'
import { MODALIDADES, STATUS_AUD, TIPOS_AUD, diasAte, montarISO, rotuloQuando, separarISO } from '../lib/audiencia.js'
import { POLOS } from '../lib/formato.js'

export const AUD_VAZIA = { tipo: 'conciliacao', dia: '', hora: '', modalidade: 'presencial', local: '', link: '', observacoes: '' }

// Campos reutilizados no cadastro do processo e no formulário de audiência
export function CamposAudiencia({ a, set, erros = {} }) {
  return (
    <>
      <Campo rotulo="Tipo de audiência">
        <select className="entrada" value={a.tipo} onChange={e => set('tipo', e.target.value)}>
          {Object.entries(TIPOS_AUD).map(([v, r]) => <option key={v} value={v}>{r}</option>)}
        </select>
      </Campo>
      <div className="duas">
        <Campo rotulo="Data" obrigatorio erro={erros.dia}>
          <input className={`entrada ${erros.dia ? 'invalida' : ''}`} type="date" value={a.dia} onChange={e => set('dia', e.target.value)} />
        </Campo>
        <Campo rotulo="Hora (Brasília)" obrigatorio erro={erros.hora}>
          <input className={`entrada ${erros.hora ? 'invalida' : ''}`} type="time" value={a.hora} onChange={e => set('hora', e.target.value)} />
        </Campo>
      </div>
      <Campo rotulo="Modalidade">
        <Segmentado rotulo="Modalidade" valor={a.modalidade} onChange={v => set('modalidade', v)} opcoes={Object.entries(MODALIDADES)} />
      </Campo>
      {a.modalidade !== 'virtual' && (
        <Campo rotulo="Local"><input className="entrada" value={a.local || ''} onChange={e => set('local', e.target.value)} placeholder="Fórum, sala, endereço" /></Campo>
      )}
      {a.modalidade !== 'presencial' && (
        <Campo rotulo="Link da sala virtual"><input className="entrada" type="url" inputMode="url" value={a.link || ''} onChange={e => set('link', e.target.value)} placeholder="https://" /></Campo>
      )}
      <Campo rotulo="Observações"><textarea className="entrada" value={a.observacoes || ''} onChange={e => set('observacoes', e.target.value)} placeholder="Testemunhas, preposto, proposta de acordo…" /></Campo>
    </>
  )
}

export function validarAudiencia(a) {
  return { dia: !a.dia ? 'Informe a data.' : '', hora: !a.hora ? 'Informe a hora.' : '' }
}

// Formulário completo (nova, editar, a partir de sugestão)
export function AudienciaForm({ inicial, processoFixo, aoSalvar, aoExcluir, rotulo = 'Salvar audiência' }) {
  const toast = useToast()
  const { dia, hora } = separarISO(inicial?.data_hora)
  const [a, setA] = useState({ ...AUD_VAZIA, ...inicial, dia: inicial?.dia ?? dia, hora: inicial?.hora ?? hora })
  const [tocado, setTocado] = useState(false)
  const [salvando, setSalvando] = useState(false)
  const procs = useCarregar(() => (processoFixo ? Promise.resolve([]) : api.listarProcessos()), [processoFixo])
  const set = (k, v) => setA(x => ({ ...x, [k]: v }))
  const erros = { ...validarAudiencia(a), processo_id: !processoFixo && !a.processo_id ? 'Escolha o processo.' : '' }
  const e = k => (tocado ? erros[k] : '')

  async function salvar(ev) {
    ev.preventDefault(); setTocado(true)
    if (Object.values(erros).some(Boolean)) return
    setSalvando(true)
    try {
      await aoSalvar({ ...a, processo_id: processoFixo || a.processo_id, data_hora: montarISO(a.dia, a.hora) })
    } catch (err) { toast(err.message, 'erro') } finally { setSalvando(false) }
  }

  return (
    <form className="form" onSubmit={salvar} noValidate>
      {!processoFixo && (
        <Campo rotulo="Processo" obrigatorio erro={e('processo_id')}>
          <select className={`entrada ${e('processo_id') ? 'invalida' : ''}`} value={a.processo_id || ''} onChange={x => set('processo_id', x.target.value)}>
            <option value="">Selecione…</option>
            {(procs.dados || []).filter(p => p.situacao === 'ativo').map(p => <option key={p.id} value={p.id}>{p.cliente_nome} × {p.parte_contraria || '—'} · {p.numero_cnj}</option>)}
          </select>
        </Campo>
      )}
      <CamposAudiencia a={a} set={set} erros={{ dia: e('dia'), hora: e('hora') }} />
      {inicial?.id && (
        <>
          <Campo rotulo="Situação">
            <select className="entrada" value={a.status} onChange={x => set('status', x.target.value)}>
              {Object.entries(STATUS_AUD).map(([v, r]) => <option key={v} value={v}>{r}</option>)}
            </select>
          </Campo>
          {a.status !== 'agendada' && (
            <Campo rotulo="Resultado / o que aconteceu"><textarea className="entrada" value={a.resultado || ''} onChange={x => set('resultado', x.target.value)} placeholder="Ex.: acordo de R$ 2.500 em 3 parcelas; redesignada para…" /></Campo>
          )}
        </>
      )}
      <button className="btn primario bloco" disabled={salvando}>{salvando ? 'Salvando…' : rotulo}</button>
      {aoExcluir && <button type="button" className="btn perigo bloco" onClick={aoExcluir}><Icone nome="lixo" />Excluir audiência</button>}
    </form>
  )
}

// Cartão de audiência
export function ItemAudiencia({ a, onAbrir, mostrarProcesso = true }) {
  const n = diasAte(a.data_hora)
  const pendente = a.status === 'agendada' && new Date(a.data_hora) < new Date(Date.now() - 3 * 3600000)
  const urg = a.status === 'agendada' && n >= 0 && n <= 1 ? 'urgente' : a.status === 'agendada' && n >= 0 && n <= 7 ? 'breve' : ''
  return (
    <button className={`cartao aud ${urg} ${a.status !== 'agendada' ? 'encerrada' : ''}`} onClick={() => onAbrir?.(a)}>
      <div className="aud-hora">
        <b>{rotuloQuando(a.data_hora)}</b>
        <span>{TIPOS_AUD[a.tipo]}</span>
      </div>
      <div className="aud-corpo">
        {mostrarProcesso && <h3>{a.cliente}</h3>}
        {mostrarProcesso && <div className="linha">{POLOS[a.polo]} · × {a.parte_contraria || '—'}</div>}
        <div className="linha">{a.modalidade === 'virtual' ? 'Virtual' : a.local || MODALIDADES[a.modalidade]}{a.orgao_julgador && mostrarProcesso ? ` · ${a.orgao_julgador}` : ''}</div>
        <div className="cartao-rodape" style={{ marginTop: 6 }}>
          <span className="selo">{MODALIDADES[a.modalidade]}</span>
          {a.status !== 'agendada' && <span className="selo">{STATUS_AUD[a.status]}</span>}
          {pendente && <span className="selo alerta">Registrar resultado</span>}
          {urg === 'urgente' && !pendente && <span className="selo perigo">{n === 0 ? 'Hoje' : 'Amanhã'}</span>}
        </div>
      </div>
    </button>
  )
}

// Aviso no topo da tela inicial: audiências de hoje e amanhã
export function AvisoAudiencias({ lista }) {
  const proximas = lista.filter(a => a.status === 'agendada' && diasAte(a.data_hora) >= 0 && diasAte(a.data_hora) <= 1 && new Date(a.data_hora) > new Date(Date.now() - 2 * 3600000))
  if (!proximas.length) return null
  return (
    <div className="aviso-aud">
      <Icone nome="martelo" width="22" height="22" />
      <div style={{ flex: 1, minWidth: 0 }}>
        {proximas.map(a => (
          <div key={a.id} className="aviso-aud-item">
            <Link to={`/processos/${a.processo_id}`}><b>{rotuloQuando(a.data_hora)}</b> · {TIPOS_AUD[a.tipo]} · {a.cliente}</Link>
            {a.link && a.modalidade !== 'presencial' && <a className="btn pequeno" href={a.link} target="_blank" rel="noreferrer">Entrar na sala</a>}
          </div>
        ))}
      </div>
    </div>
  )
}
