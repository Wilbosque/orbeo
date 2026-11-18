import { useEffect, useMemo, useState } from 'react'
import * as api from '#backend'
import { usePerfil } from '../App.jsx'
import Icone from './Icone.jsx'
import { Campo, Segmentado, useCarregar, useToast } from './ui.jsx'
import { GRUPOS, INSTANCIAS, REGRA_RITO, RITOS, calcularPrazo, diaSemana, inferirRito, limiteDoTipo, tipicoDoTipo, tiposDoRito } from '../lib/prazo.js'
import { POLOS, data as fmt } from '../lib/formato.js'
import { TIPOS_AUD, diaSP, hojeSP, rotuloQuando } from '../lib/audiencia.js'

const mais = (s, n) => { const d = new Date(s + 'T12:00'); d.setDate(d.getDate() + n); return d.toLocaleDateString('en-CA') }
const PADRAO = { tipo: '', tipoOutro: '', data_recebimento: '', origem_contagem: 'intimacao', dias: '', contagem: 'uteis',
  calculo_auto: true, prazo_fatal: '', data_elaboracao: '', observacoes: '' }

// Junta dias seguidos com o mesmo motivo: "21/12 a 20/01 · Suspensão de prazos de fim de ano"
function agruparConsiderados(lista) {
  const out = []
  for (const c of lista) {
    const u = out[out.length - 1]
    if (u && u.motivo === c.motivo && mais(u.ate, 1) <= c.dia && Math.round((new Date(c.dia) - new Date(u.ate)) / 86400000) <= 4) u.ate = c.dia
    else out.push({ de: c.dia, ate: c.dia, motivo: c.motivo })
  }
  return out
}

export const PAPEIS = { admin: 'Sócio administrador', advogado: 'Advogado', estagiario: 'Estagiário' }

export function PrazoForm({ inicial, processoFixo, aoSalvar, aoExcluir }) {
  const toast = useToast()
  const { perfil } = usePerfil()
  const equipe = useCarregar(() => api.listarAdvogados(), [])
  const [z, setZ] = useState({
    ...PADRAO, data_recebimento: hojeSP(), ...inicial,
    tipo: inicial?.tipo || '', tipoOutro: '', dias: inicial?.dias ?? '', prazo_fatal: inicial?.prazo_fatal || '',
    data_elaboracao: inicial?.data_elaboracao || '', audiencia_id: inicial?.audiencia_id || '',
    responsavel_id: inicial?.id ? (inicial.responsavel_id || '') : (inicial?.responsavel_id || perfil.id),
  })
  const [salvando, setSalvando] = useState(false)
  const [tocado, setTocado] = useState(false)
  const set = (k, v) => setZ(x => ({ ...x, [k]: v }))
  const [numero, setNumero] = useState(inicial?.numero_cnj || '')
  const processoId = processoFixo || z.processo_id

  const base = useCarregar(() => Promise.all([
    processoFixo ? api.obterProcesso(processoFixo).then(p => [p]) : api.listarProcessos(),
    z.data_recebimento ? api.listarSuspensoes(z.data_recebimento, mais(z.data_recebimento, 420)) : Promise.resolve([]),
  ]), [processoFixo, z.data_recebimento])
  const [procs = [], suspensoes = []] = base.dados || []
  const proc = procs.find(p => p.id === processoId)
  const rito = proc?.rito || inferirRito(proc?.tribunal, proc?.classe, proc?.orgao_julgador)
  const catalogo = tiposDoRito(rito)
  const auds = useCarregar(() => (processoId ? api.listarAudiencias({ processo_id: processoId, status: 'agendada' }) : Promise.resolve([])), [processoId])

  // Tipo escolhido no catálogo do rito (ou "Outro")
  const itemTipo = catalogo.find(c => c.tipo === z.tipo) || (z.tipo ? { tipo: 'Outro' } : null)
  const ehOutro = itemTipo?.tipo === 'Outro'
  const ligadoAudiencia = Boolean(itemTipo?.audiencia)
  const emHoras = z.origem_contagem === 'ato'

  // Edição de prazo com tipo fora do catálogo → mostra como "Outro"
  useEffect(() => {
    if (inicial?.tipo && proc && !catalogo.some(c => c.tipo === inicial.tipo)) setZ(x => ({ ...x, tipo: 'Outro', tipoOutro: inicial.tipo }))
  }, [proc?.id]) // eslint-disable-line react-hooks/exhaustive-deps

  function escolherTipo(t) {
    const c = catalogo.find(x => x.tipo === t) || {}
    setZ(x => ({
      ...x, tipo: t, dias: c.dias ?? (x.publicacao_id ? x.dias : ''), audiencia_id: c.audiencia ? (auds.dados?.[0]?.id || '') : '',
      origem_contagem: c.origem || (x.origem_contagem === 'ato' ? 'intimacao' : x.origem_contagem),
      contagem: c.contagem || 'uteis', calculo_auto: c.audiencia ? false : true,
    }))
  }

  const previa = useMemo(() => (z.calculo_auto && !ligadoAudiencia && proc
    ? calcularPrazo({ data: z.data_recebimento, origem: z.origem_contagem, dias: Number(z.dias), contagem: z.contagem }, suspensoes, proc) : null),
  [z.calculo_auto, ligadoAudiencia, z.data_recebimento, z.origem_contagem, z.dias, z.contagem, suspensoes, proc])
  const audEscolhida = (auds.dados || []).find(a => a.id === z.audiencia_id)

  const limite = limiteDoTipo(itemTipo)
  const tipico = tipicoDoTipo(itemTipo, rito)
  const fatalFinal = ligadoAudiencia ? (audEscolhida ? diaSP(audEscolhida.data_hora) : '') : z.calculo_auto ? previa?.fatal : z.prazo_fatal
  const tipoFinal = ehOutro ? z.tipoOutro.trim() : z.tipo
  const erros = {
    processo: !processoId ? 'Escolha o processo.' : '',
    tipo: !tipoFinal ? 'Escolha o tipo do prazo.' : '',
    data: !z.data_recebimento ? 'Informe a data.' : '',
    dias: z.calculo_auto && !ligadoAudiencia && !emHoras
      ? (!(Number(z.dias) > 0) ? 'Informe os dias.' : Number(z.dias) > limite ? `No máximo ${limite} dias para este tipo.` : '') : '',
    elaboracao: z.data_elaboracao && fatalFinal && z.data_elaboracao > fatalFinal ? `Não pode ser depois do prazo fatal (${fmt(fatalFinal)}).` : '',
    fatal: !z.calculo_auto && !ligadoAudiencia && !z.prazo_fatal ? 'Informe o prazo fatal.' : '',
    audiencia: ligadoAudiencia && !z.audiencia_id ? 'Escolha a audiência (ou cadastre-a no processo antes).' : '',
  }
  const e = k => (tocado ? erros[k] : '')

  async function salvar(ev) {
    ev.preventDefault(); setTocado(true)
    if (Object.values(erros).some(Boolean)) return
    setSalvando(true)
    try {
      await aoSalvar({ ...z, responsavel_id: z.responsavel_id || null, tipo: tipoFinal, processo_id: processoId, audiencia_id: ligadoAudiencia ? z.audiencia_id : null,
        calculo_auto: ligadoAudiencia ? false : z.calculo_auto, prazo_fatal: ligadoAudiencia ? audEscolhida && diaSP(audEscolhida.data_hora) : z.prazo_fatal })
    } catch (err) { toast(err.message, 'erro') } finally { setSalvando(false) }
  }

  return (
    <form className="form" onSubmit={salvar} noValidate>
      {!processoFixo && (() => {
        const dig = numero.replace(/\D/g, '')
        const achado = dig.length === 20 ? procs.find(p => p.numero_cnj.replace(/\D/g, '') === dig) : null
        const msg = !dig ? '' : dig.length < 20 ? `Faltam ${20 - dig.length} dígito${20 - dig.length > 1 ? 's' : ''}.`
          : !achado ? 'Nenhum processo cadastrado com este número. Cadastre o processo antes de lançar o prazo.'
          : achado.situacao === 'baixado' ? 'Este processo está baixado. Reative-o para lançar prazos.' : ''
        return (
          <Campo rotulo="Número do processo" obrigatorio erro={msg || (tocado && !z.processo_id ? 'Digite o número de um processo cadastrado.' : '')}
            ajuda={!dig ? 'Pode digitar com ou sem pontos e traços.' : ''}>
            <input className={`entrada mono ${msg ? 'invalida' : ''}`} inputMode="numeric" autoComplete="off" placeholder="0000000-00.0000.0.00.0000" value={numero}
              onChange={x => {
                const v = x.target.value; setNumero(v)
                const d = v.replace(/\D/g, '')
                const p = d.length === 20 ? procs.find(q => q.numero_cnj.replace(/\D/g, '') === d && q.situacao !== 'baixado') : null
                if ((p?.id || '') !== (z.processo_id || '')) { set('processo_id', p?.id || ''); set('tipo', '') }
              }} />
            {achado && !msg && (
              <div className="processo-achado"><Icone nome="certo" width="16" height="16" />
                <span><b>{achado.cliente_nome}</b> × {achado.parte_contraria || '—'}<br /><small className="muted">{achado.tribunal}{achado.comarca ? ` · ${achado.comarca}` : ''}{achado.orgao_julgador ? ` · ${achado.orgao_julgador}` : ''}</small></span>
              </div>
            )}
          </Campo>
        )
      })()}
      {z.publicacao_id && (
        <div className="aviso info"><Icone nome="info" />
          <div>Prazo da publicação disponibilizada no DJEN em {fmt(z.data_recebimento)}.{inicial?.trecho ? <> No texto: “{inicial.trecho}”.</> : ' O texto não indica a quantidade de dias: confira e informe.'}</div>
        </div>
      )}
      {proc && <div className="regra-rito"><b>{RITOS[rito]}</b> · {INSTANCIAS[proc.instancia || '1g']} · {REGRA_RITO[rito]}</div>}

      <Campo rotulo="Tipo de prazo" obrigatorio erro={e('tipo')}>
        <select className={`entrada ${e('tipo') ? 'invalida' : ''}`} value={z.tipo} onChange={x => escolherTipo(x.target.value)} disabled={!proc}>
          <option value="">{proc ? 'Selecione…' : 'Escolha o processo primeiro'}</option>
          {GRUPOS.map(g => {
            const itens = catalogo.filter(c => c.grupo === g)
            return itens.length ? <optgroup key={g} label={g}>{itens.map(c => <option key={c.tipo} value={c.tipo}>{c.tipo}</option>)}</optgroup> : null
          })}
        </select>
      </Campo>
      {ehOutro && (
        <Campo rotulo="Qual prazo?" obrigatorio erro={e('tipo')}><input className="entrada" value={z.tipoOutro} onChange={x => set('tipoOutro', x.target.value)} placeholder="Ex.: Juntada de procuração" /></Campo>
      )}

      {ligadoAudiencia ? (
        <>
          <Campo rotulo="Audiência" obrigatorio erro={e('audiencia')} ajuda="A contestação vence no dia da audiência. Se a audiência for redesignada, o prazo acompanha sozinho.">
            <select className={`entrada ${e('audiencia') ? 'invalida' : ''}`} value={z.audiencia_id} onChange={x => set('audiencia_id', x.target.value)}>
              <option value="">{auds.dados?.length ? 'Selecione…' : 'Nenhuma audiência agendada neste processo'}</option>
              {(auds.dados || []).map(a => <option key={a.id} value={a.id}>{rotuloQuando(a.data_hora)} · {TIPOS_AUD[a.tipo]}</option>)}
            </select>
          </Campo>
          {audEscolhida && <div className="previa-prazo"><div className="previa-linha destaque"><span>Prazo fatal</span><b>{fmt(diaSP(audEscolhida.data_hora))} · na audiência</b></div></div>}
          <Campo rotulo="Data da citação / intimação" ajuda="Usada no indicador de tempo entre o recebimento e o cumprimento.">
            <input className="entrada" type="date" value={z.data_recebimento} onChange={x => set('data_recebimento', x.target.value)} />
          </Campo>
        </>
      ) : (
        <>
          {!emHoras && (
            <Campo rotulo="A contagem parte de">
              <Segmentado rotulo="Origem da contagem" valor={z.origem_contagem} onChange={v => set('origem_contagem', v)}
                opcoes={[['intimacao', 'Intimação / ciência'], ['disponibilizacao', 'Disponibilização DJEN']]} />
            </Campo>
          )}
          <Campo rotulo={emHoras ? 'Data da interposição do recurso' : z.origem_contagem === 'intimacao' ? 'Data da intimação ou ciência' : 'Data da disponibilização no DJEN'} obrigatorio erro={e('data')}
            ajuda={emHoras ? 'Prazo em horas, contado do próprio ato (independe de intimação). Se terminar em dia sem expediente, prorroga para o próximo dia útil.'
              : z.origem_contagem === 'disponibilizacao' ? 'A publicação é o 1º dia útil seguinte; a contagem começa no dia útil depois dela.' : 'A contagem começa no 1º dia útil seguinte.'}>
            <input className={`entrada ${e('data') ? 'invalida' : ''}`} type="date" value={z.data_recebimento} onChange={x => set('data_recebimento', x.target.value)} />
          </Campo>

          {!emHoras && (
            <label className="caixa-check">
              <input type="checkbox" checked={z.calculo_auto} onChange={x => set('calculo_auto', x.target.checked)} />
              <div><b>Calcular o prazo fatal automaticamente</b><span>Pelos dias do prazo, fins de semana, feriados e suspensões cadastradas. Se surgir uma suspensão nova, o prazo é recalculado sozinho.</span></div>
            </label>
          )}

          {z.calculo_auto ? (
            <>
              {!emHoras && (
                <div className="duas">
                  <Campo rotulo={`Dias (máx. ${limite})`} obrigatorio erro={e('dias')}
                    ajuda={itemTipo?.nota}>
                    <input className={`entrada ${e('dias') ? 'invalida' : ''}`} type="number" min="1" max={limite} inputMode="numeric" value={z.dias} placeholder="—" onChange={x => set('dias', x.target.value)} />
                  </Campo>
                  <Campo rotulo="Contagem">
                    <select className="entrada" value={z.contagem} onChange={x => set('contagem', x.target.value)}>
                      <option value="uteis">Dias úteis</option><option value="corridos">Dias corridos</option>
                    </select>
                  </Campo>
                </div>
              )}
              {!emHoras && tipico && String(tipico) !== String(z.dias) && (
                <button type="button" className="btn pequeno" style={{ justifySelf: 'start' }} onClick={() => set('dias', String(tipico))}>
                  Usar o prazo típico: {tipico} dias
                </button>
              )}
              {previa ? (
                <div className="previa-prazo">
                  {!emHoras && <div className="previa-linha"><span>Início da contagem</span><b>{fmt(previa.inicio)} ({diaSemana(previa.inicio)})</b></div>}
                  {previa.publicacao && <div className="previa-linha"><span>Publicação considerada</span><b>{fmt(previa.publicacao)}</b></div>}
                  <div className="previa-linha destaque"><span>Prazo fatal</span><b>{fmt(previa.fatal)} ({diaSemana(previa.fatal)})</b></div>
                  {previa.considerados.length > 0 && (
                    <div className="previa-cons">
                      <span>Dias que não contaram ou prorrogaram:</span>
                      <ul>{agruparConsiderados(previa.considerados).map(c => <li key={c.de}>{fmt(c.de)}{c.ate !== c.de ? ` a ${fmt(c.ate)}` : ''} · {c.motivo}</li>)}</ul>
                    </div>
                  )}
                  <small>Prévia. O valor oficial é calculado pelo banco ao salvar, com as mesmas regras.</small>
                </div>
              ) : proc && z.tipo && z.data_recebimento ? <small className="muted">Informe os dias para ver o prazo fatal.</small> : null}
            </>
          ) : (
            <Campo rotulo="Prazo fatal" obrigatorio erro={e('fatal')}>
              <input className={`entrada ${e('fatal') ? 'invalida' : ''}`} type="date" value={z.prazo_fatal} onChange={x => set('prazo_fatal', x.target.value)} />
            </Campo>
          )}
        </>
      )}

      <Campo rotulo="Responsável" ajuda="Quem vai cuidar do prazo. O estagiário designado vê o processo e pode dar o cumprimento, com observação.">
        <select className="entrada" value={z.responsavel_id || ''} onChange={x => set('responsavel_id', x.target.value)}>
          <option value="">Sem responsável definido</option>
          {(equipe.dados || []).filter(a => a.ativo !== false).map(a => <option key={a.id} value={a.id}>{a.nome}{a.id === perfil.id ? ' (você)' : ''} · {PAPEIS[a.papel] || 'Advogado'}</option>)}
        </select>
      </Campo>
      <Campo rotulo="Quando pretende elaborar" erro={e('elaboracao') || erros.elaboracao} ajuda="Aparece em “Prazos do dia” nesta data. Não pode ser depois do prazo fatal.">
        <input className={`entrada ${erros.elaboracao ? 'invalida' : ''}`} type="date" value={z.data_elaboracao} max={fatalFinal || undefined} onChange={x => set('data_elaboracao', x.target.value)} />
      </Campo>
      <Campo rotulo="Observações"><textarea className="entrada" value={z.observacoes || ''} onChange={x => set('observacoes', x.target.value)} /></Campo>

      <button className="btn primario bloco" disabled={salvando}>{salvando ? 'Salvando…' : inicial?.id ? 'Salvar prazo' : 'Cadastrar prazo'}</button>
      {aoExcluir && <button type="button" className="btn perigo bloco" onClick={aoExcluir}><Icone nome="lixo" />Excluir prazo</button>}
    </form>
  )
}

export function ItemPrazoLista({ z, onAbrir, onCumprir, mostrarProcesso = true }) {
  const { perfil } = usePerfil()
  const podeCumprir = perfil.papel !== 'estagiario' || z.responsavel_id === perfil.id
  const hoje = hojeSP()
  const dias = Math.round((new Date(z.prazo_fatal + 'T12:00') - new Date(hoje + 'T12:00')) / 86400000)
  const cls = z.status === 'cumprido' ? 'cumprido' : dias < 0 ? 'vencido' : dias === 0 ? 'hoje' : dias <= 3 ? 'elaborar' : ''
  const rot = z.status === 'cumprido' ? `Cumprido ${fmt(z.data_cumprimento)}` : dias < 0 ? `Vencido há ${-dias} dia${dias < -1 ? 's' : ''}` : dias === 0 ? 'Vence hoje' : dias === 1 ? 'Vence amanhã' : `Vence em ${dias} dias`
  return (
    <div className={`cartao prazo ${cls}`}>
      <button className="corpo" onClick={() => onAbrir?.(z)}>
        <div className="tipo">{z.tipo}</div>
        {mostrarProcesso && <div className="ref">{z.cliente} · {POLOS[z.polo]}</div>}
        {mostrarProcesso && <div className="ref mono">{z.numero_cnj}</div>}
        <div className="ref">
          Fatal {fmt(z.prazo_fatal)}{z.data_elaboracao && z.status !== 'cumprido' ? ` · elaborar ${fmt(z.data_elaboracao)}` : ''}
          {z.audiencia_id ? ` · na audiência${z.audiencia_data_hora ? ` (${rotuloQuando(z.audiencia_data_hora)})` : ''}`
            : z.origem_contagem === 'ato' ? ' · prazo em horas' : z.calculo_auto && z.dias ? ` · ${z.dias} dias ${z.contagem === 'uteis' ? 'úteis' : 'corridos'}` : ''}
        </div>
        {z.responsavel_nome && <div className="ref">Responsável: {z.responsavel_id === perfil.id ? 'você' : z.responsavel_nome}{z.responsavel_papel === 'estagiario' ? ' (estagiário)' : ''}</div>}
        {z.status === 'cumprido' && z.cumprimento_obs && <div className="ref" style={{ fontStyle: 'italic' }}>“{z.cumprimento_obs.length > 90 ? z.cumprimento_obs.slice(0, 90) + '…' : z.cumprimento_obs}”{z.cumprido_por_nome ? ` · ${z.cumprido_por_nome}` : ''}</div>}
        {z.prazo_fatal_anterior && z.status === 'aberto' && <div className="ref" style={{ color: 'var(--warn)', fontWeight: 600 }}>{z.audiencia_id ? 'Audiência redesignada' : 'Recalculado por suspensão'}: era {fmt(z.prazo_fatal_anterior)}</div>}
      </button>
      <div className="quando">
        <b>{rot}</b>
        {z.status === 'aberto' && onCumprir && podeCumprir && <button className="btn pequeno" onClick={() => onCumprir(z)} style={{ marginTop: 6 }}><Icone nome="certo" />Cumprido</button>}
      </div>
    </div>
  )
}

export function CumprirForm({ z, aoConfirmar }) {
  const [data, setData] = useState(hojeSP())
  const [obs, setObs] = useState('')
  return (
    <div className="form">
      <div className="muted" style={{ marginTop: -8 }}>{z.tipo} · {z.cliente} · fatal {fmt(z.prazo_fatal)}</div>
      <Campo rotulo="Data do protocolo / cumprimento"><input className="entrada" type="date" value={data} max={hojeSP()} onChange={e => setData(e.target.value)} /></Campo>
      {data > z.prazo_fatal && <div className="aviso alerta"><Icone nome="alerta" />A data informada é posterior ao prazo fatal.</div>}
      <Campo rotulo="Observação (opcional)" ajuda="Instruções ou o que foi feito. Fica no histórico do prazo, com o seu nome.">
        <textarea className="entrada" value={obs} onChange={e => setObs(e.target.value)} placeholder="Ex.: Protocolado no PJe às 15h. Acompanhar a intimação da parte contrária." />
      </Campo>
      <button className="btn primario bloco" onClick={() => aoConfirmar(data, obs.trim() || null)}><Icone nome="certo" />Marcar como cumprido</button>
    </div>
  )
}

// ---------- Histórico do prazo (quem lançou, cumpriu, observou) ----------
const ACOES = { criado: 'Lançado', cumprido: 'Cumprido', reaberto: 'Reaberto', responsavel: 'Responsável alterado', observacao: 'Observação', editado: 'Editado' }
export function HistoricoPrazo({ z }) {
  const { perfil } = usePerfil()
  const toast = useToast()
  const r = useCarregar(() => api.historicoPrazo(z.id), [z.id])
  const [texto, setTexto] = useState('')
  const [enviando, setEnviando] = useState(false)
  const podeObservar = perfil.papel !== 'estagiario' || z.responsavel_id === perfil.id
  async function observar() {
    setEnviando(true)
    try { await api.observarPrazo(z.id, texto.trim()); setTexto(''); r.recarregar(); toast('Observação registrada.') } catch (e) { toast(e.message, 'erro') } finally { setEnviando(false) }
  }
  return (
    <div className="historico-prazo">
      <div className="secao" style={{ marginTop: 20 }}><h2>Histórico do prazo</h2></div>
      <ul className="hist">
        {(r.dados || []).map(h => (
          <li key={h.id}>
            <div className="quando">{new Date(h.em).toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo', day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' })} · {h.autor_nome || '—'}</div>
            <b>{ACOES[h.acao] || h.acao}</b>
            {h.texto && <div className="texto">{h.texto}</div>}
          </li>
        ))}
      </ul>
      {podeObservar && (
        <div className="form" style={{ marginTop: 10 }}>
          <textarea className="entrada" value={texto} onChange={e => setTexto(e.target.value)} placeholder="Escrever observação ou instrução…" />
          <button type="button" className="btn bloco" disabled={enviando || !texto.trim()} onClick={observar}>Registrar observação</button>
        </div>
      )}
    </div>
  )
}

/** Painel do prazo: formulário (advogados) ou leitura (estagiário), sempre com o histórico */
export function PainelPrazo({ inicial, processoFixo, aoSalvar, aoExcluir, aoReabrir, aoCumprir }) {
  const { perfil } = usePerfil()
  const estagiario = perfil.papel === 'estagiario'
  if (estagiario && inicial?.id) {
    const z = inicial
    return (
      <div className="form">
        <dl className="dados" style={{ margin: 0 }}>
          <div><dt>Prazo</dt><dd>{z.tipo}</dd></div>
          <div><dt>Processo</dt><dd>{z.cliente} · <span className="mono">{z.numero_cnj}</span></dd></div>
          <div><dt>Prazo fatal</dt><dd>{fmt(z.prazo_fatal)}</dd></div>
          {z.data_elaboracao && <div><dt>Elaborar em</dt><dd>{fmt(z.data_elaboracao)}</dd></div>}
          <div><dt>Responsável</dt><dd>{z.responsavel_nome || '—'}</dd></div>
          {z.observacoes && <div><dt>Observações</dt><dd style={{ whiteSpace: 'pre-wrap' }}>{z.observacoes}</dd></div>}
        </dl>
        {z.status === 'aberto' && z.responsavel_id === perfil.id && <button className="btn primario bloco" onClick={() => aoCumprir?.(z)}><Icone nome="certo" />Dar cumprimento</button>}
        <HistoricoPrazo z={z} />
      </div>
    )
  }
  return (
    <>
      {inicial?.id && <div className="muted" style={{ marginTop: -8, marginBottom: 12 }}>{inicial.cliente} · {inicial.numero_cnj}</div>}
      {inicial?.status === 'cumprido' && aoReabrir && <button className="btn bloco" style={{ marginBottom: 12 }} onClick={aoReabrir}>Reabrir prazo</button>}
      <PrazoForm key={inicial?.id || 'novo'} inicial={inicial} processoFixo={processoFixo} aoSalvar={aoSalvar} aoExcluir={aoExcluir} />
      {inicial?.id && <HistoricoPrazo z={inicial} />}
    </>
  )
}
