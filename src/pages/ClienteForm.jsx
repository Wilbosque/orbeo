import { useEffect, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import * as api from '#backend'
import Icone from '../components/Icone.jsx'
import { Campo, Carregando, Erro, Segmentado, Topo, useCarregar, useToast } from '../components/ui.jsx'
import { formatarDoc, validarDoc } from '../lib/documento.js'
import { mascararTelefone } from '../lib/formato.js'

const VAZIO = { tipo: 'PJ', nome: '', nome_fantasia: '', cpf_cnpj: '', email: '', telefone: '', observacoes: '' }

// Sugestão de termos para o DJEN: nome sem "LTDA", "S.A." etc. e nome fantasia
export function sugerirTermos(c) {
  const limpar = s => (s || '').toUpperCase()
    .replace(/\b(LTDA|EIRELI|S\/?A|S\.A\.|ME|EPP|SA)\b\.?/g, '').replace(/[-–,.]+$/, '').replace(/\s+/g, ' ').trim()
  return [...new Set([limpar(c.nome_fantasia), limpar(c.nome)].filter(t => t.length >= 4))]
}

function CamposCliente({ f, set, tocado, erros }) {
  return (
    <>
      <Campo rotulo="Tipo">
        <Segmentado rotulo="Tipo de cliente" valor={f.tipo} onChange={v => set('tipo', v)} opcoes={[['PJ', 'Empresa'], ['PF', 'Pessoa física']]} />
      </Campo>
      <Campo rotulo={f.tipo === 'PJ' ? 'Razão social' : 'Nome completo'} obrigatorio erro={tocado.nome ? erros.nome : ''}>
        <input className={`entrada ${tocado.nome && erros.nome ? 'invalida' : ''}`} value={f.nome} onChange={e => set('nome', e.target.value)} autoComplete="off" />
      </Campo>
      {f.tipo === 'PJ' && (
        <Campo rotulo="Nome fantasia">
          <input className="entrada" value={f.nome_fantasia || ''} onChange={e => set('nome_fantasia', e.target.value)} autoComplete="off" />
        </Campo>
      )}
      <Campo rotulo={f.tipo === 'PJ' ? 'CNPJ' : 'CPF'} erro={erros.cpf_cnpj}>
        <input className={`entrada mono ${erros.cpf_cnpj ? 'invalida' : ''}`} inputMode={f.tipo === 'PF' ? 'numeric' : 'text'}
          value={f.cpf_cnpj || ''} onChange={e => set('cpf_cnpj', formatarDoc(e.target.value, f.tipo))}
          placeholder={f.tipo === 'PJ' ? '00.000.000/0000-00' : '000.000.000-00'} autoComplete="off" />
      </Campo>
    </>
  )
}

function validar(f) {
  const docCompleto = f.cpf_cnpj && f.cpf_cnpj.replace(/[^0-9A-Z]/gi, '').length >= (f.tipo === 'PF' ? 11 : 14)
  return {
    nome: !f.nome.trim() ? 'Informe o nome.' : '',
    cpf_cnpj: docCompleto && !validarDoc(f.cpf_cnpj, f.tipo) ? `${f.tipo === 'PF' ? 'CPF' : 'CNPJ'} inválido. Confira os dígitos.` : '',
  }
}

// Cadastro rápido, usado dentro do formulário de processo
export function ClienteRapido({ aoSalvar }) {
  const [f, setF] = useState(VAZIO)
  const [tocado, setTocado] = useState({})
  const [erro, setErro] = useState('')
  const [salvando, setSalvando] = useState(false)
  const set = (k, v) => setF(x => ({ ...x, [k]: v }))
  const erros = validar(f)
  async function salvar() {
    setTocado({ nome: true })
    if (erros.nome || erros.cpf_cnpj) return
    setSalvando(true)
    try { aoSalvar(await api.salvarCliente(f, f.tipo === 'PJ' ? sugerirTermos(f) : [])) }
    catch (e) { setErro(e.message) } finally { setSalvando(false) }
  }
  return (
    <div className="form">
      {erro && <div className="aviso erro"><Icone nome="alerta" />{erro}</div>}
      <CamposCliente f={f} set={set} tocado={tocado} erros={erros} />
      {f.tipo === 'PJ' && <small className="muted">As publicações com o nome desta empresa serão monitoradas no DJEN. Você pode ajustar os nomes depois, no cadastro do cliente.</small>}
      <button type="button" className="btn primario bloco" onClick={salvar} disabled={salvando}>{salvando ? 'Salvando…' : 'Salvar cliente'}</button>
    </div>
  )
}

export default function ClienteForm() {
  const { id } = useParams()
  const editando = Boolean(id)
  const nav = useNavigate()
  const toast = useToast()
  const base = useCarregar(() => editando ? Promise.all([api.obterCliente(id), api.termosDoCliente(id)]) : Promise.resolve([null, []]), [id])
  const [existente, termosAtuais] = base.dados || []

  const [f, setF] = useState(VAZIO)
  const [monitorar, setMonitorar] = useState(true)
  const [termos, setTermos] = useState([])
  const [termosEditados, setTermosEditados] = useState(false)
  const [novoTermo, setNovoTermo] = useState('')
  const [tocado, setTocado] = useState({})
  const [salvando, setSalvando] = useState(false)
  const [erro, setErro] = useState('')

  useEffect(() => {
    if (existente) {
      setF({ ...VAZIO, ...existente })
      setTermos(termosAtuais.map(t => t.valor)); setMonitorar(termosAtuais.length > 0); setTermosEditados(true)
    }
  }, [existente, termosAtuais])

  const set = (k, v) => setF(x => ({ ...x, [k]: v }))
  useEffect(() => { if (!termosEditados) setTermos(sugerirTermos(f)) }, [f.nome, f.nome_fantasia, termosEditados]) // eslint-disable-line
  useEffect(() => { if (!editando) setMonitorar(f.tipo === 'PJ') }, [f.tipo, editando])

  const erros = validar(f)

  function addTermo() {
    const t = novoTermo.trim().toUpperCase()
    if (t.length >= 4 && !termos.includes(t)) { setTermos([...termos, t]); setTermosEditados(true) }
    setNovoTermo('')
  }

  async function salvar(e) {
    e.preventDefault()
    setTocado({ nome: true })
    if (erros.nome || erros.cpf_cnpj) return
    setSalvando(true); setErro('')
    try {
      const salvo = await api.salvarCliente({ ...f, id: editando ? id : undefined }, monitorar ? termos : [])
      toast(editando ? 'Cliente atualizado.' : 'Cliente cadastrado.')
      nav(`/clientes/${salvo.id}`, { replace: true })
    } catch (err) { setErro(err.message) } finally { setSalvando(false) }
  }

  if (base.erro) return <><Topo titulo="Cliente" voltar="/clientes" /><Erro erro={base.erro} /></>
  if (base.carregando) return <><Topo titulo={editando ? 'Editar cliente' : 'Novo cliente'} voltar="/clientes" /><Carregando n={3} /></>
  if (editando && !existente) return <><Topo titulo="Cliente" voltar="/clientes" /><Erro erro={{ message: 'Cliente não encontrado ou sem acesso.' }} /></>

  return (
    <>
      <Topo titulo={editando ? 'Editar cliente' : 'Novo cliente'} voltar="/clientes" />
      <form className="form" onSubmit={salvar} noValidate>
        {erro && <div className="aviso erro" role="alert"><Icone nome="alerta" />{erro}</div>}
        <CamposCliente f={f} set={set} tocado={tocado} erros={erros} />
        <div className="duas">
          <Campo rotulo="E-mail">
            <input className="entrada" type="email" inputMode="email" value={f.email || ''} onChange={e => set('email', e.target.value)} autoComplete="off" />
          </Campo>
          <Campo rotulo="Telefone">
            <input className="entrada" inputMode="tel" value={f.telefone || ''} onChange={e => set('telefone', mascararTelefone(e.target.value))} autoComplete="off" />
          </Campo>
        </div>

        <label className="caixa-check">
          <input type="checkbox" checked={monitorar} onChange={e => setMonitorar(e.target.checked)} />
          <div><b>Monitorar publicações no DJEN pelo nome</b><span>Encontra processos novos deste cliente, mesmo antes de você cadastrá-los. Só você recebe o resultado da sua busca.</span></div>
        </label>
        {monitorar && (
          <Campo rotulo="Nomes buscados no DJEN" ajuda="Inclua variações usadas nos processos (razão social, nome fantasia, nome antigo).">
            <div className="termos">
              {termos.map(t => (
                <span key={t} className="termo">{t}
                  <button type="button" aria-label={`Remover ${t}`} onClick={() => { setTermos(termos.filter(x => x !== t)); setTermosEditados(true) }}><Icone nome="fechar" /></button>
                </span>
              ))}
              {termos.length === 0 && <small className="muted">Nenhum nome ainda.</small>}
            </div>
            <div style={{ display: 'flex', gap: 8 }}>
              <input className="entrada" value={novoTermo} onChange={e => setNovoTermo(e.target.value)} placeholder="Adicionar nome"
                onKeyDown={e => { if (e.key === 'Enter') { e.preventDefault(); addTermo() } }} />
              <button type="button" className="btn" onClick={addTermo}>Incluir</button>
            </div>
          </Campo>
        )}

        <Campo rotulo="Observações">
          <textarea className="entrada" value={f.observacoes || ''} onChange={e => set('observacoes', e.target.value)} />
        </Campo>

        <div className="barra-salvar">
          <button type="button" className="btn" onClick={() => nav(-1)}>Cancelar</button>
          <button className="btn primario" disabled={salvando}>{salvando ? 'Salvando…' : editando ? 'Salvar' : 'Cadastrar'}</button>
        </div>
      </form>
    </>
  )
}
