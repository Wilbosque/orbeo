import { useState } from 'react'
import Icone from './Icone.jsx'
import { Campo, Carregando, Erro, useCarregar } from './ui.jsx'

/**
 * Saída de um advogado do escritório: quem assume os processos que só ele acompanha,
 * quais processos ele pode levar para o espaço autônomo e (se não tiver outro espaço) o que fazer com o login.
 *  carregarPrevia(): { processos: [{id, numero_cnj, cliente, exclusivo}], prazos_abertos, outros_espacos }
 *  equipe: membros do escritório de origem (para escolher o sucessor)
 *  modo: 'remover' (sócio) | 'remanejar' (dono, o destino já é outro escritório)
 */
export default function Saida({ alvo, carregarPrevia, equipe, modo = 'remover', aoConfirmar, rotulo }) {
  const r = useCarregar(carregarPrevia, [alvo.id])
  const [sucessor, setSucessor] = useState('')
  const [levar, setLevar] = useState([])
  const [destino, setDestino] = useState('autonomo')
  const [enviando, setEnviando] = useState(false)
  const [erro, setErro] = useState('')
  if (r.erro) return <Erro erro={r.erro} tentar={r.recarregar} />
  if (r.carregando || !r.dados) return <Carregando n={2} />
  const { processos = [], prazos_abertos = 0, outros_espacos = [] } = r.dados
  const exclusivos = processos.filter(p => p.exclusivo)
  const candidatos = (equipe || []).filter(a => a.id !== alvo.id && a.ativo !== false && a.papel !== 'estagiario')
  const semOutroEspaco = modo === 'remover' && !outros_espacos.length
  const alternar = id => setLevar(l => (l.includes(id) ? l.filter(x => x !== id) : [...l, id]))
  const precisaSucessor = exclusivos.length > 0 || prazos_abertos > 0

  async function confirmar() {
    setErro('')
    if (exclusivos.length && !sucessor) return setErro('Escolha quem assume os processos que só este advogado acompanha.')
    if (destino === 'excluir_login' && levar.length) return setErro('Para levar processos, mantenha o login como advogado autônomo.')
    setEnviando(true)
    try { await aoConfirmar({ sucessor_id: sucessor || null, levar, destino: semOutroEspaco ? destino : 'manter' }) }
    catch (e) { setErro(e.message) } finally { setEnviando(false) }
  }
  return (
    <div className="form">
      {erro && <div className="aviso erro"><Icone nome="alerta" />{erro}</div>}
      <div className="aviso info"><Icone nome="info" />
        <div>{alvo.nome} deixa de ver os processos deste escritório. Os processos <b>continuam no escritório</b>.
          {outros_espacos.length ? <> Ele segue usando o Orbeo em: {outros_espacos.map(e => e.tipo === 'autonomo' ? 'espaço autônomo' : e.nome).join(', ')}.</> : null}</div>
      </div>

      <Campo rotulo={`Quem assume${exclusivos.length ? ` os ${exclusivos.length} processo(s) que só ele acompanha` : ''}${prazos_abertos ? ` e ${prazos_abertos} prazo(s) em aberto` : ''}`}
        obrigatorio={exclusivos.length > 0} ajuda={precisaSucessor ? 'O sucessor passa a ver esses processos e vira responsável pelos prazos e audiências em aberto dele.' : 'Nenhum processo exclusivo nem prazo em aberto.'}>
        <select className="entrada" value={sucessor} onChange={e => setSucessor(e.target.value)} disabled={!precisaSucessor}>
          <option value="">{precisaSucessor ? 'Selecione…' : 'Não é necessário'}</option>
          {candidatos.map(a => <option key={a.id} value={a.id}>{a.nome}</option>)}
        </select>
      </Campo>

      {processos.length > 0 && (
        <div>
          <b style={{ fontSize: '.92rem' }}>Autorizar a levar para o espaço autônomo dele</b>
          <small className="muted" style={{ display: 'block', margin: '4px 0 8px' }}>Marque os processos que vão junto (por exemplo, quando o cliente acompanha o advogado). É feita uma cópia com andamentos, publicações, prazos, audiências e anotações; o original fica no escritório.</small>
          <div className="lista-checks">
            {processos.map(p => (
              <label key={p.id} className="caixa-check compacta">
                <input type="checkbox" checked={levar.includes(p.id)} onChange={() => alternar(p.id)} />
                <div><b className="mono">{p.numero_cnj}</b><span>{p.cliente}{p.exclusivo ? ' · só ele acompanha' : ''}</span></div>
              </label>
            ))}
          </div>
        </div>
      )}

      {semOutroEspaco && (
        <div>
          <b style={{ fontSize: '.92rem' }}>Ele não tem outro espaço no Orbeo. E o login?</b>
          <label className="caixa-check compacta" style={{ marginTop: 8 }}>
            <input type="radio" name="destino" checked={destino === 'autonomo'} onChange={() => setDestino('autonomo')} />
            <div><b>Manter como advogado autônomo</b><span>Ele continua entrando no Orbeo, só com os processos dele.</span></div>
          </label>
          <label className="caixa-check compacta">
            <input type="radio" name="destino" checked={destino === 'excluir_login'} onChange={() => setDestino('excluir_login')} disabled={levar.length > 0} />
            <div><b>Excluir o login</b><span>Ele não consegue mais entrar. {levar.length ? 'Indisponível ao levar processos.' : 'Não pode ser desfeito.'}</span></div>
          </label>
        </div>
      )}
      <button className={`btn bloco ${destino === 'excluir_login' && semOutroEspaco ? 'perigo' : 'primario'}`} disabled={enviando} onClick={confirmar}>
        {enviando ? 'Processando…' : rotulo || (destino === 'excluir_login' && semOutroEspaco ? 'Remover e excluir o login' : 'Remover do escritório')}
      </button>
    </div>
  )
}
