import { useEffect, useMemo, useRef, useState } from 'react'
import * as api from '#backend'
import Icone from './Icone.jsx'
import { normalizar } from '../lib/formato.js'

const chave = s => normalizar(s || '').replace(/[^a-z0-9 ]/g, '')

/** Comarca / foro com busca na lista do tribunal. Aceita texto livre. */
export function CampoComarca({ tribunal, valor, onChange }) {
  const [lista, setLista] = useState([])
  const [aberta, setAberta] = useState(false)
  const [foco, setFoco] = useState(-1)
  const caixa = useRef(null)
  useEffect(() => {
    let vivo = true
    if (!tribunal) { setLista([]); return }
    api.listarComarcas(tribunal).then(l => vivo && setLista(l || [])).catch(() => vivo && setLista([]))
    return () => { vivo = false }
  }, [tribunal])
  useEffect(() => {
    const fora = e => { if (caixa.current && !caixa.current.contains(e.target)) setAberta(false) }
    document.addEventListener('pointerdown', fora)
    return () => document.removeEventListener('pointerdown', fora)
  }, [])
  const termo = chave(valor)
  const opcoes = useMemo(() => {
    if (!termo) return lista.slice(0, 60)
    const comeca = [], contem = []
    for (const n of lista) { const k = chave(n); if (k.startsWith(termo) || k.includes(' - ' + termo)) comeca.push(n); else if (k.includes(termo)) contem.push(n) }
    return [...comeca, ...contem].slice(0, 60)
  }, [lista, termo])
  const exato = lista.some(n => chave(n) === termo)
  function escolher(n) { onChange(n); setAberta(false); setFoco(-1) }
  function teclas(e) {
    if (!aberta && (e.key === 'ArrowDown' || e.key === 'ArrowUp')) { setAberta(true); return }
    if (e.key === 'ArrowDown') { e.preventDefault(); setFoco(f => Math.min(f + 1, opcoes.length - 1)) }
    else if (e.key === 'ArrowUp') { e.preventDefault(); setFoco(f => Math.max(f - 1, 0)) }
    else if (e.key === 'Enter' && aberta && foco >= 0) { e.preventDefault(); escolher(opcoes[foco]) }
    else if (e.key === 'Escape') setAberta(false)
  }
  const ehSP = (tribunal || '').toUpperCase() === 'TJSP'
  return (
    <div className="combo" ref={caixa}>
      <input className="entrada" value={valor || ''} autoComplete="off" role="combobox" aria-expanded={aberta} aria-autocomplete="list"
        placeholder={!tribunal ? 'Informe o tribunal primeiro' : ehSP ? 'Ex.: Campinas ou São Paulo - Foro Regional II - Santo Amaro' : 'Digite para buscar'}
        onChange={e => { onChange(e.target.value); setAberta(true); setFoco(-1) }} onFocus={() => setAberta(true)} onKeyDown={teclas} />
      {aberta && tribunal && opcoes.length > 0 && !(exato && opcoes.length === 1) && (
        <ul className="combo-lista" role="listbox">
          {opcoes.map((n, i) => (
            <li key={n} role="option" aria-selected={i === foco} className={i === foco ? 'foco' : ''}
              onPointerDown={e => { e.preventDefault(); escolher(n) }}>{n}</li>
          ))}
        </ul>
      )}
      {valor && lista.length > 0 && !exato && !aberta && <small className="muted">Não está na lista do {tribunal}: confira a grafia (vale para as suspensões da comarca).</small>}
    </div>
  )
}

/** Partes do processo nos dois polos. O cliente principal fica fixo no polo dele. */
export function CamposPartes({ partes, setPartes, cliente, polo, clientes }) {
  const meuPolo = polo === 'autor' ? 'ativo' : 'passivo'
  const [novo, setNovo] = useState({ ativo: '', passivo: '' })
  const porNome = useMemo(() => new Map((clientes || []).map(c => [chave(c.nome), c])), [clientes])
  function adicionar(p) {
    const nome = novo[p].trim()
    if (!nome) return
    const c = porNome.get(chave(nome)) || (clientes || []).find(x => x.nome_fantasia && chave(x.nome_fantasia) === chave(nome))
    if (c && (c.id === cliente?.id || partes.some(x => x.cliente_id === c.id))) { setNovo(v => ({ ...v, [p]: '' })); return }
    setPartes([...partes, { polo: p, nome: c ? c.nome : nome, cliente_id: c?.id || null }])
    setNovo(v => ({ ...v, [p]: '' }))
  }
  const remover = i => setPartes(partes.filter((_, j) => j !== i))
  const bloco = (p, titulo) => (
    <div className="partes-polo">
      <div className="partes-titulo">{titulo}</div>
      <ul className="partes-lista">
        {cliente && meuPolo === p && <li><span className="selo violeta">Cliente</span><b>{cliente.nome}</b></li>}
        {partes.map((x, i) => x.polo === p && (
          <li key={i}>{x.cliente_id && <span className="selo violeta">Cliente</span>}<span style={{ flex: 1 }}>{x.nome}</span>
            <button type="button" className="icone-btn" aria-label={`Retirar ${x.nome}`} onClick={() => remover(i)}><Icone nome="fechar" width="16" height="16" /></button></li>
        ))}
        {!partes.some(x => x.polo === p) && !(cliente && meuPolo === p) && <li className="muted">Nenhuma parte informada.</li>}
      </ul>
      <div className="partes-add">
        <input className="entrada" list="clientes-partes" value={novo[p]} placeholder="Nome da parte (ou de outro cliente)"
          onChange={e => setNovo(v => ({ ...v, [p]: e.target.value }))} onKeyDown={e => { if (e.key === 'Enter') { e.preventDefault(); adicionar(p) } }} />
        <button type="button" className="btn pequeno" onClick={() => adicionar(p)}><Icone nome="mais_add" />Incluir</button>
      </div>
    </div>
  )
  return (
    <div className="partes">
      {bloco('ativo', 'Polo ativo (autores)')}
      {bloco('passivo', 'Polo passivo (réus)')}
      <datalist id="clientes-partes">{(clientes || []).filter(c => c.id !== cliente?.id).map(c => <option key={c.id} value={c.nome} />)}</datalist>
    </div>
  )
}
