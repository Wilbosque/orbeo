import { useState } from 'react'
import * as api from '#backend'
import Icone from '../components/Icone.jsx'
import { Campo } from '../components/ui.jsx'
import { UFS } from '../lib/formato.js'
import { TelaCentral } from './Login.jsx'

export default function PrimeiroAcesso({ aoSalvar }) {
  const [f, setF] = useState({ nome: '', oab_numero: '', oab_uf: 'BA' })
  const [erro, setErro] = useState('')
  const [salvando, setSalvando] = useState(false)
  const set = k => e => setF({ ...f, [k]: e.target.value })

  async function salvar(e) {
    e.preventDefault()
    setSalvando(true); setErro('')
    try { aoSalvar(await api.salvarPerfil({ ...f, nome: f.nome.trim(), oab_numero: f.oab_numero.replace(/\D/g, '') })) }
    catch (err) { setErro(err.message) }
    finally { setSalvando(false) }
  }

  return (
    <TelaCentral subtitulo="Só no primeiro acesso. A OAB é usada para buscar as suas publicações no DJEN.">
      <form className="form" onSubmit={salvar} style={{ marginTop: 18 }}>
        <h1>Seu cadastro</h1>
        {erro && <div className="aviso erro"><Icone nome="alerta" />{erro}</div>}
        <Campo rotulo="Nome completo" obrigatorio>
          <input className="entrada" value={f.nome} onChange={set('nome')} required autoComplete="name" />
        </Campo>
        <div className="duas">
          <Campo rotulo="Nº da OAB" obrigatorio>
            <input className="entrada mono" inputMode="numeric" value={f.oab_numero} onChange={set('oab_numero')} required />
          </Campo>
          <Campo rotulo="UF" obrigatorio>
            <select className="entrada" value={f.oab_uf} onChange={set('oab_uf')}>{UFS.map(u => <option key={u}>{u}</option>)}</select>
          </Campo>
        </div>
        <button className="btn primario bloco" disabled={salvando}>{salvando ? 'Salvando…' : 'Continuar'}</button>
      </form>
    </TelaCentral>
  )
}
