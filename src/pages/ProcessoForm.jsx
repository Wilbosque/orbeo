import { useEffect, useState } from 'react'
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom'
import * as api from '#backend'
import { usePerfil } from '../App.jsx'
import Icone from '../components/Icone.jsx'
import { Campo, Carregando, Erro, Folha, Segmentado, Topo, useCarregar, useToast } from '../components/ui.jsx'
import { formatarCNJ, soDigitos, tipoAcaoSugerido, tribunalDoCNJ, validarCNJ } from '../lib/cnj.js'
import { SITUACOES, TIPOS_ACAO, lerMoeda, mascararMoeda, oabsTexto } from '../lib/formato.js'
import { ClienteRapido } from './ClienteForm.jsx'
import { AUD_VAZIA, CamposAudiencia, validarAudiencia } from '../components/Audiencias.jsx'
import { montarISO } from '../lib/audiencia.js'
import { RITOS, inferirRito } from '../lib/prazo.js'
import { CampoComarca, CamposPartes } from '../components/CamposProcesso.jsx'

const VAZIO = {
  numero_cnj: '', cliente_id: '', polo: 'reu', parte_contraria: '', tribunal: '', orgao_julgador: '', comarca: '', rito: '', instancia: '1g',
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
  const [partes, setPartes] = useState([]) // todas menos o cliente principal
  const setA = (k, v) => setAud(x => ({ ...x, [k]: v }))

  useEffect(() => { if (clientes) setListaClientes(clientes) }, [clientes])
  useEffect(() => {
    if (existente) {
      setF({ ...VAZIO, ...existente, valor_causa: existente.valor_causa ? mascararMoeda(Math.round(existente.valor_causa * 100)) : '' })
      setPartes((existente.partes || []).filter(x => x.cliente_id !== existente.cliente_id))
    }
    else if (!editando && (sp.get('cliente') || sp.get('numero'))) {
      // Vindo da busca no DJEN: número, polo, parte contrária, vara e classe já preenchidos (confira antes de salvar)
      setF(v => ({ ...v,
        cliente_id: sp.get('cliente') || v.cliente_id, numero_cnj: sp.get('numero') || v.numero_cnj,
        polo: sp.get('polo') || v.polo, parte_contraria: sp.get('parte') || v.parte_contraria,
        orgao_julgador: sp.get('orgao') || v.orgao_julgador, classe: sp.get('classe') || v.classe }))
      if (sp.get('parte')) {
        const contra = (sp.get('polo') || 'reu') === 'autor' ? 'passivo' : 'ativo'
        setPartes(sp.get('parte').split(/\s*[,;]\s*|\s+e\s+/).filter(Boolean).map(nome => ({ polo: contra, nome })))
      }
    }
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
      const salvo = await api.salvarProcesso({ ...f, id: editando ? id : undefined, valor_causa: lerMoeda(f.valor_causa), partes }, editando ? [] : colegas)
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

        <Campo rotulo="O cliente está no">
          <Segmentado rotulo="Polo do cliente" valor={f.polo} onChange={v => {
            set('polo', v)
            // Ao trocar o polo do cliente, as demais partes trocam de lado junto
            setPartes(ps => ps.map(x => ({ ...x, polo: x.polo === 'ativo' ? 'passivo' : 'ativo' })))
          }} opcoes={[['reu', 'Polo passivo (réu)'], ['autor', 'Polo ativo (autor)']]} />
        </Campo>

        <Campo rotulo="Partes" ajuda="Inclua todos os autores e réus (litisconsórcio). Se outra parte também for cliente do escritório, escolha o nome na lista.">
          <CamposPartes partes={partes} setPartes={setPartes} polo={f.polo} clientes={listaClientes}
            cliente={listaClientes.find(c => c.id === f.cliente_id)} />
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

        <Campo rotulo={(f.tribunal || '').toUpperCase() === 'TJSP' ? 'Foro / comarca' : (f.tribunal || '').toUpperCase().startsWith('TRF') ? 'Subseção judiciária' : 'Comarca'}
          ajuda="Escolha na lista do tribunal. Define as suspensões e os feriados locais. Se ficar em branco, o DataJud preenche quando trouxer o processo.">
          <CampoComarca tribunal={f.tribunal} valor={f.comarca} onChange={v => set('comarca', v)} />
        </Campo>

        <Campo rotulo="Instância" ajuda="Define quais suspensões valem para o processo (ex.: TJBA 1º grau/Juizados x 2º grau/Turmas Recursais). Quando o processo subir em recurso, troque aqui: os prazos abertos são recalculados.">
          <Segmentado rotulo="Instância" valor={f.instancia || '1g'} onChange={v => set('instancia', v)} opcoes={[['1g', '1º grau / Juizados'], ['2g', '2º grau / Turmas Recursais']]} />
        </Campo>

        <Campo rotulo="Rito / competência" ajuda={`Define os tipos de prazo e as regras de contagem. Automático: ${RITOS[inferirRito(f.tribunal, f.classe, f.orgao_julgador)]}.`}>
          <select className="entrada" value={f.rito || ''} onChange={e => set('rito', e.target.value)}>
            <option value="">Automático ({RITOS[inferirRito(f.tribunal, f.classe, f.orgao_julgador)]})</option>
            {Object.entries(RITOS).map(([v, r]) => <option key={v} value={v}>{r}</option>)}
          </select>
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

        {f.situacao === 'baixado' ? (
          <div className="aviso info"><Icone nome="info" /><div>Processo baixado. Para reativar, use o botão na página do processo.</div></div>
        ) : (
          <Campo rotulo="Situação" ajuda="Para encerrar o acompanhamento, use “Dar baixa” na página do processo.">
            <select className="entrada" value={f.situacao} onChange={e => set('situacao', e.target.value)}>
              {Object.entries(SITUACOES).filter(([v]) => v !== 'baixado').map(([v, r]) => <option key={v} value={v}>{r}</option>)}
            </select>
          </Campo>
        )}

        {!editando && outros.length > 0 && (
          <Campo rotulo="Advogados do processo" ajuda="Por sigilo, só quem estiver marcado aqui enxerga o processo. Você já está incluído.">
            <div className="lista">
              {outros.map(a => (
                <label key={a.id} className="caixa-check">
                  <input type="checkbox" checked={colegas.includes(a.id)}
                    onChange={e => setColegas(c => e.target.checked ? [...c, a.id] : c.filter(x => x !== a.id))} />
                  <div><b>Incluir {a.nome}</b><span>{oabsTexto(a)} · passa a ver este processo e o cliente</span></div>
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
