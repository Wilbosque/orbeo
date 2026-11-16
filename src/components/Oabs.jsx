import { useState } from 'react'
import * as api from '#backend'
import Icone from './Icone.jsx'
import { useCarregar, useToast } from './ui.jsx'
import { UFS } from '../lib/formato.js'

/** Lista e edita as OABs de um advogado (principal + suplementares). */
export default function Oabs({ advogadoId, aoMudar }) {
  const toast = useToast()
  const r = useCarregar(() => api.listarOabs(advogadoId), [advogadoId])
  const [abrir, setAbrir] = useState(false)
  const [n, setN] = useState('')
  const [uf, setUf] = useState('SP')
  const [ocupado, setOcupado] = useState(false)
  const lista = r.dados || []
  const ufsUsadas = new Set(lista.map(o => o.uf))

  async function fazer(fn, msg) {
    setOcupado(true)
    try { await fn(); toast(msg); r.recarregar(); aoMudar?.() } catch (e) { toast(e.message, 'erro') } finally { setOcupado(false) }
  }
  return (
    <div className="oabs">
      {lista.map(o => (
        <div key={o.id} className="oab-linha">
          <div style={{ flex: 1, minWidth: 0 }}>
            <b className="mono">{o.numero}/{o.uf}</b>
            <span className={`selo ${o.principal ? 'violeta' : ''}`} style={{ marginLeft: 8 }}>{o.principal ? 'Principal' : 'Suplementar'}</span>
          </div>
          {!o.principal && (
            <>
              <button type="button" className="btn pequeno" disabled={ocupado} onClick={() => fazer(() => api.tornarOabPrincipal(o.id), `OAB ${o.numero}/${o.uf} agora é a principal.`)}>Tornar principal</button>
              <button type="button" className="icone-btn" disabled={ocupado} aria-label={`Remover OAB ${o.numero}/${o.uf}`}
                onClick={() => window.confirm(`Remover a OAB ${o.numero}/${o.uf}?`) && fazer(() => api.removerOab(o.id), 'OAB removida.')}><Icone nome="lixo" /></button>
            </>
          )}
        </div>
      ))}
      {abrir ? (
        <div className="oab-nova">
          <input className="entrada mono" inputMode="numeric" placeholder="Número" value={n} onChange={e => setN(e.target.value)} aria-label="Número da OAB" />
          <select className="entrada" value={uf} onChange={e => setUf(e.target.value)} aria-label="UF da OAB">
            {UFS.map(u => <option key={u} disabled={ufsUsadas.has(u)}>{u}</option>)}
          </select>
          <button type="button" className="btn primario" disabled={ocupado || !n.trim()}
            onClick={() => fazer(async () => { await api.incluirOab(n.trim(), uf, advogadoId || null); setN(''); setAbrir(false) }, 'OAB incluída.')}>Incluir</button>
        </div>
      ) : (
        <button type="button" className="link-btn" onClick={() => setAbrir(true)}><Icone nome="mais_add" width="16" height="16" /> Incluir OAB de outra seccional</button>
      )}
      <small className="muted" style={{ display: 'block' }}>Uma inscrição por estado (principal ou suplementar). A principal aparece no seu nome no sistema.</small>
    </div>
  )
}
