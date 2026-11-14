import { useMemo, useState } from 'react'
import * as api from '#backend'
import Icone from '../components/Icone.jsx'
import { CumprirForm, ItemPrazoLista, PrazoForm } from '../components/Prazos.jsx'
import { Carregando, Erro, Folha, Topo, Vazio, useCarregar, useToast } from '../components/ui.jsx'
import { hojeSP } from '../lib/audiencia.js'
import { normalizar } from '../lib/formato.js'

const mais = (s, n) => { const d = new Date(s + 'T12:00'); d.setDate(d.getDate() + n); return d.toLocaleDateString('en-CA') }

export default function Prazos() {
  const toast = useToast()
  const [filtro, setFiltro] = useState('abertos')
  const [q, setQ] = useState('')
  const [form, setForm] = useState(null)
  const [cumprir, setCumprir] = useState(null)
  const r = useCarregar(() => api.listarPrazos(), [])
  const todos = r.dados || []
  const hoje = hojeSP()

  const lista = useMemo(() => {
    const t = normalizar(q)
    return todos.filter(z => !q || normalizar(`${z.tipo} ${z.cliente} ${z.numero_cnj} ${z.parte_contraria || ''}`).includes(t))
      .filter(z => filtro === 'cumpridos' ? z.status === 'cumprido' : z.status === 'aberto')
      .filter(z => filtro === 'vencidos' ? z.prazo_fatal < hoje : filtro === 'semana' ? z.prazo_fatal >= hoje && z.prazo_fatal <= mais(hoje, 7) : true)
  }, [todos, filtro, q, hoje])
  const abertos = todos.filter(z => z.status === 'aberto')
  const vencidos = abertos.filter(z => z.prazo_fatal < hoje).length

  const grupos = filtro === 'cumpridos' ? [['Cumpridos', [...lista].reverse()]] : [
    ['Vencidos', lista.filter(z => z.prazo_fatal < hoje)],
    ['Vencem hoje', lista.filter(z => z.prazo_fatal === hoje)],
    ['Próximos 7 dias', lista.filter(z => z.prazo_fatal > hoje && z.prazo_fatal <= mais(hoje, 7))],
    ['Mais adiante', lista.filter(z => z.prazo_fatal > mais(hoje, 7))],
  ].filter(([, l]) => l.length)

  async function salvar(z) {
    const salvo = await api.salvarPrazo(z)
    toast(`${z.id ? 'Prazo atualizado' : 'Prazo cadastrado'}. Fatal: ${salvo.prazo_fatal.split('-').reverse().join('/')}.`)
    setForm(null); r.recarregar()
  }
  async function marcarCumprido(z, data) {
    try { await api.cumprirPrazo(z.id, data); toast('Prazo marcado como cumprido.'); setCumprir(null); r.recarregar() } catch (e) { toast(e.message, 'erro') }
  }
  async function excluir(z) {
    if (!window.confirm('Excluir este prazo?')) return
    try { await api.excluirPrazo(z.id); toast('Prazo excluído.'); setForm(null); r.recarregar() } catch (e) { toast(e.message, 'erro') }
  }

  return (
    <>
      <Topo titulo="Prazos" sub={r.dados ? `${abertos.length} em aberto${vencidos ? ` · ${vencidos} vencido${vencidos > 1 ? 's' : ''}` : ''}` : ' '} />
      <div className="busca"><Icone nome="busca" /><input type="search" placeholder="Tipo, cliente, número…" value={q} onChange={e => setQ(e.target.value)} aria-label="Buscar prazos" /></div>
      <div className="chips">
        {[['abertos', 'Em aberto'], ['semana', 'Próximos 7 dias'], ['vencidos', `Vencidos${vencidos ? ` (${vencidos})` : ''}`], ['cumpridos', 'Cumpridos']].map(([v, t]) =>
          <button key={v} className={`chip ${filtro === v ? 'ativo' : ''}`} onClick={() => setFiltro(v)}>{t}</button>)}
      </div>
      {r.erro && <Erro erro={r.erro} tentar={r.recarregar} />}
      {r.carregando && !r.dados ? <Carregando n={3} /> : grupos.length === 0 ? (
        <Vazio icone="relogio" titulo={filtro === 'cumpridos' ? 'Nenhum prazo cumprido ainda' : 'Nenhum prazo em aberto'} texto="Cadastre pelo botão abaixo ou dentro do processo." />
      ) : grupos.map(([titulo, l]) => (
        <div key={titulo}>
          <div className="secao"><h2>{titulo} ({l.length})</h2></div>
          <div className="lista">{l.map(z => <ItemPrazoLista key={z.id} z={z} onAbrir={x => setForm({ inicial: x })} onCumprir={setCumprir} />)}</div>
        </div>
      ))}
      <button className="fab" onClick={() => setForm({ inicial: {} })}><Icone nome="mais_add" />Prazo</button>

      <Folha titulo={form?.inicial?.id ? 'Editar prazo' : 'Novo prazo'} aberta={Boolean(form)} fechar={() => setForm(null)}>
        {form && <>
          {form.inicial?.id && <div className="muted" style={{ marginTop: -8, marginBottom: 12 }}>{form.inicial.cliente} · {form.inicial.numero_cnj}</div>}
          {form.inicial?.status === 'cumprido' && <button className="btn bloco" style={{ marginBottom: 12 }} onClick={async () => { await api.reabrirPrazo(form.inicial.id); toast('Prazo reaberto.'); setForm(null); r.recarregar() }}>Reabrir prazo</button>}
          <PrazoForm key={form.inicial?.id || 'novo'} inicial={form.inicial} processoFixo={form.inicial?.processo_id}
            aoSalvar={salvar} aoExcluir={form.inicial?.id ? () => excluir(form.inicial) : null} />
        </>}
      </Folha>
      <Folha titulo="Prazo cumprido" aberta={Boolean(cumprir)} fechar={() => setCumprir(null)}>
        {cumprir && <CumprirForm z={cumprir} aoConfirmar={d => marcarCumprido(cumprir, d)} />}
      </Folha>
    </>
  )
}
