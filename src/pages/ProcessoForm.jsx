import { useEffect, useState } from 'react'
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom'
import * as api from '#backend'
import { usePerfil } from '../App.jsx'
import Icone from '../components/Icone.jsx'
import { Campo, Carregando, Erro, Folha, Segmentado, Topo, useCarregar, useToast } from '../components/ui.jsx'
import { formatarCNJ, soDigitos, tipoAcaoSugerido, tribunalDoCNJ, validarCNJ } from '../lib/cnj.js'
import { SITUACOES, TIPOS_ACAO, lerMoeda, mascararMoeda } from '../lib/formato.js'
import { ClienteRapido } from './ClienteForm.jsx'
import { AUD_VAZIA, CamposAudiencia, validarAudiencia } from '../components/Audiencias.jsx'
import { montarISO } from '../lib/audiencia.js'

const VAZIO = {
  numero_cnj: '', cliente_id: '', polo: 'reu', parte_contraria: '', tribunal: '', orgao_julgador: '', comarca: '',
  classe: '', tipo_acao: '', valor_causa: '', situacao: 'ativo', data_distribuicao: '', observacoes: '',
}

export default function ProcessoForm() {
  const { id } = useParams()
  const [sp] = useSearchParams()
  const nav = useNavigate()
  const toast = useToast()
  const { perfil } = usePerfil()
  const editando = Boolean(id)

  const base = useCarregar(() => Promise.all([
    api.listarClientes(), api.listarAdvogados(), editando ? api.obterProcesso(id) : Promise.resolve(null),
  ]), [id])
  const [clientes, advogados, existente] = base.dados || []

  const [f, setF] = useState(VAZIO)
  const [colegas, setColegas] = useState([])
  const [tocado, setTocado] = useState({})
  const [duplicado, setDuplicado] = useState(null)
  const [salvando, setSalvando] = useState(false)
  const [erro, setErro] = useState('')
  const [folhaCliente, setFolhaCliente] = useState(false)
  const [listaClientes, setListaClientes] = useState([])
  const [comAud, setComAud] = useState(false)
  const [aud, setAud] = useState(AUD_VAZIA)
  const setA = (k, v) => setAud(x => ({ ...x, [k]: v }))

  useEffect(() => { if (clientes) setListaClientes(clientes) }, [clientes])
  useEffect(() => {
    if (existente) setF({ ...VAZIO, ...existente, valor_causa: existente.valor_causa ? mascararMoeda(Math.round(existente.valor_causa * 100)) : '' })
    else if (!editando && sp.get('cliente')) setF(v => ({ ...v, cliente_id: sp.get('cliente') }))
  }, [existente, editando, sp])

  const set = (k, v) => setF(x => ({ ...x, [k]: v }))
  const cnjOk = validarCNJ(f.numero_cnj)
  const trib = tribunalDoCNJ(f.numero_cnj)

  // Ao completar o número: preenche tribunal, sugere tipo e verifica duplicidade
  useEffect(() => {
    if (!cnjOk.ok) { setDuplicado(null); return }
    if (trib && (!f.tribunal || !editando)) set('tribunal', trib.sigla)
    if (!f.tipo_acao) { const t = tipoAcaoSugerido(f.numero_cnj); if (t) set('tipo_acao', t) }
    if (!editando) api.processoPorNumero(f.numero_cnj).then(setDuplicado).catch(() => {})
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [f.numero_cnj, cnjOk.ok])

  const outros = (advogados || []).filter(a => a.id !== perfil.id)
  const erros = {
    numero_cnj: !f.numero_cnj ? 'Informe o número do processo.' : !cnjOk.ok ? cnjOk.motivo : duplicado ? 'Você já tem este processo cadastrado.' : '',
    cliente_id: !f.cliente_id ? 'Escolha o cliente.' : '',
    tribunal: !f.tribunal ? 'Informe o tribunal.' : '',
  }
  const errosAud = comAud ? validarAudiencia(aud) : {}
  const temErro = Object.values(erros).some(Boolean) || Object.values(errosAud).some(Boolean)

  async function salvar(e) {
    e.preventDefault()
    setTocado({ numero_cnj: true, cliente_id: true, tribunal: true, aud: true })
    if (temErro) return
    setSalvando(true); setErro('')
    try {
      const salvo = await api.salvarProcesso({ ...f, id: editando ? id : undefined, valor_causa: lerMoeda(f.valor_causa) }, editando ? [] : colegas)
      if (!editando && comAud) await api.salvarAudiencia({ ...aud, processo_id: salvo.id, data_hora: montarISO(aud.dia, aud.hora) })
      toast(editando ? 'Processo atualizado.' : comAud ? 'Processo e audiência cadastrados.' : 'Processo cadastrado.')
      nav(`/processos/${salvo.id}`, { replace: true })
    } catch (err) { setErro(err.message) }
    finally { setSalvando(false) }
  }

  if (base.erro) return <><Topo titulo="Processo" voltar="/processos" /><Erro erro={base.erro} tentar={base.recarregar} /></>
  if (base.carregando || !base.dados) return <><Topo titulo={editando ? 'Editar processo' : 'Novo processo'} voltar="/processos" /><Carregando n={3} /></>
  if (editando && !existente) return <><Topo titulo="Processo" voltar="/processos" /><Erro erro={{ message: 'Processo não encontrado ou sem acesso.' }} /></>

  return (
    <>
      <Topo titulo={editando ? 'Editar processo' : 'Novo processo'} voltar="/processos" />
      <form className="form" onSubmit={salvar} noValidate>
        {erro && <div className="aviso erro" role="alert"><Icone nome="alerta" />{erro}</div>}

        <Campo rotulo="Número do processo (CNJ)" obrigatorio
          erro={tocado.numero_cnj || soDigitos(f.numero_cnj).length === 20 ? erros.numero_cnj : ''}
          certo={cnjOk.ok && trib && !duplicado ? `${trib.sigla} · ${trib.ramo}` : ''}
          ajuda="Digite só os números; a formatação é automática.">
          <input className={`entrada mono ${(tocado.numero_cnj || soDigitos(f.numero_cnj).length === 20) && erros.numero_cnj ? 'invalida' : ''}`}
            inputMode="numeric" autoComplete="off" placeholder="0000000-00.0000.0.00.0000"
            value={f.numero_cnj} disabled={editando}
            onChange={e => set('numero_cnj', formatarCNJ(e.target.value))}
            onBlur={() => setTocado(t => ({ ...t, numero_cnj: true }))} />
        </Campo>
        {duplicado && <div className="aviso alerta"><Icone nome="info" /><div>Este processo já está na sua lista. <Link to={`/processos/${duplicado.id}`}>Abrir processo</Link></div></div>}

        <Campo rotulo="Cliente" obrigatorio erro={tocado.cliente_id ? erros.cliente_id : ''}>
          <select className={`entrada ${tocado.cliente_id && erros.cliente_id ? 'invalida' : ''}`} value={f.cliente_id} onChange={e => set('cliente_id', e.target.value)}>
            <option value="">Selecione…</option>
            {listaClientes.map(c => <option key={c.id} value={c.id}>{c.nome_fantasia || c.nome}{c.tipo === 'PF' ? ' (PF)' : ''}</option>)}
          </select>
        </Campo>
        <button type="button" className="link-btn" style={{ justifySelf: 'start', marginTop: -10 }} onClick={() => setFolhaCliente(true)}>+ Cadastrar novo cliente</button>

        <Campo rotulo="O cliente é">
          <Segmentado rotulo="Polo do cliente" valor={f.polo} onChange={v => set('polo', v)} opcoes={[['reu', 'Réu'], ['autor', 'Autor']]} />
        </Campo>

        <Campo rotulo="Parte contrária">
          <input className="entrada" value={f.parte_contraria || ''} onChange={e => set('parte_contraria', e.target.value)} autoComplete="off" />
        </Campo>

        <div className="duas">
          <Campo rotulo="Tribunal" obrigatorio erro={tocado.tribunal ? erros.tribunal : ''}>
            <input className="entrada" value={f.tribunal} onChange={e => set('tribunal', e.target.value.toUpperCase())} placeholder="TJBA" />
          </Campo>
          <Campo rotulo="Tipo de ação">
            <select className="entrada" value={f.tipo_acao || ''} onChange={e => set('tipo_acao', e.target.value)}>
              <option value="">—</option>{TIPOS_ACAO.map(t => <option key={t}>{t}</option>)}
            </select>
          </Campo>
        </div>

        <Campo rotulo="Órgão julgador (vara)">
          <input className="entrada" value={f.orgao_julgador || ''} onChange={e => set('orgao_julgador', e.target.value)} placeholder="Ex.: 5ª Vara do Sistema dos Juizados Especiais do Consumidor" />
        </Campo>

        <Campo rotulo="Comarca / subseção" ajuda="Usada para aplicar suspensões de uma comarca específica. O DataJud preencherá sozinho quando a consulta estiver ligada.">
          <input className="entrada" value={f.comarca || ''} onChange={e => set('comarca', e.target.value)} placeholder="Ex.: Salvador" />
        </Campo>

        <Campo rotulo="Classe">
          <input className="entrada" value={f.classe || ''} onChange={e => set('classe', e.target.value)} placeholder="Ex.: Procedimento do Juizado Especial Cível" />
        </Campo>

        <div className="duas">
          <Campo rotulo="Valor da causa">
            <input className="entrada" inputMode="numeric" value={f.valor_causa} onChange={e => set('valor_causa', mascararMoeda(e.target.value))} placeholder="0,00" />
          </Campo>
          <Campo rotulo="Distribuição">
            <input className="entrada" type="date" value={f.data_distribuicao || ''} onChange={e => set('data_distribuicao', e.target.value)} />
          </Campo>
        </div>

        <Campo rotulo="Situação">
          <select className="entrada" value={f.situacao} onChange={e => set('situacao', e.target.value)}>
            {Object.entries(SITUACOES).map(([v, r]) => <option key={v} value={v}>{r}</option>)}
          </select>
        </Campo>

        {!editando && outros.length > 0 && (
          <Campo rotulo="Advogados do processo" ajuda="Por sigilo, só quem estiver marcado aqui enxerga o processo. Você já está incluído.">
            <div className="lista">
              {outros.map(a => (
                <label key={a.id} className="caixa-check">
                  <input type="checkbox" checked={colegas.includes(a.id)}
                    onChange={e => setColegas(c => e.target.checked ? [...c, a.id] : c.filter(x => x !== a.id))} />
                  <div><b>Incluir {a.nome}</b><span>OAB {a.oab_numero}/{a.oab_uf} passa a ver este processo e o cliente</span></div>
                </label>
              ))}
            </div>
          </Campo>
        )}

        <Campo rotulo="Observações">
          <textarea className="entrada" value={f.observacoes || ''} onChange={e => set('observacoes', e.target.value)} />
        </Campo>

        {!editando && (
          <>
            <label className="caixa-check">
              <input type="checkbox" checked={comAud} onChange={e => setComAud(e.target.checked)} />
              <div><b>Já tem audiência marcada</b><span>Cadastre agora para aparecer nos avisos e no calendário de audiências.</span></div>
            </label>
            {comAud && (
              <div className="cartao form" style={{ boxShadow: 'none' }}>
                <CamposAudiencia a={aud} set={setA} erros={tocado.aud ? errosAud : {}} />
              </div>
            )}
          </>
        )}

        <div className="barra-salvar">
          <button type="button" className="btn" onClick={() => nav(-1)}>Cancelar</button>
          <button className="btn primario" disabled={salvando}>{salvando ? 'Salvando…' : editando ? 'Salvar' : 'Cadastrar'}</button>
        </div>
      </form>

      <Folha titulo="Novo cliente" aberta={folhaCliente} fechar={() => setFolhaCliente(false)}>
        <ClienteRapido aoSalvar={c => { setListaClientes(l => [...l, c].sort((a, b) => a.nome.localeCompare(b.nome))); set('cliente_id', c.id); setFolhaCliente(false); toast('Cliente cadastrado.') }} />
      </Folha>
    </>
  )
}
