import { Link, useNavigate, useParams } from 'react-router-dom'
import * as api from '#backend'
import Icone from '../components/Icone.jsx'
import { Carregando, Erro, Fab, Topo, Vazio, useCarregar, useToast } from '../components/ui.jsx'
import { CartaoProcesso } from './Processos.jsx'

export default function ClienteDetalhe() {
  const { id } = useParams()
  const nav = useNavigate()
  const toast = useToast()
  const r = useCarregar(() => Promise.all([api.obterCliente(id), api.listarProcessos({ cliente_id: id }), api.termosDoCliente(id)]), [id])
  const [c, processos, termos] = r.dados || []

  async function excluir() {
    if (!window.confirm(`Excluir o cliente "${c.nome}"? Essa ação não pode ser desfeita.`)) return
    try { await api.excluirCliente(id); toast('Cliente excluído.'); nav('/clientes', { replace: true }) }
    catch (e) { toast(e.message, 'erro') }
  }

  if (r.erro) return <><Topo titulo="Cliente" voltar="/clientes" /><Erro erro={r.erro} tentar={r.recarregar} /></>
  if (r.carregando && !r.dados) return <><Topo titulo="Cliente" voltar="/clientes" /><Carregando n={3} /></>
  if (!c) return <><Topo titulo="Cliente" voltar="/clientes" /><Erro erro={{ message: 'Cliente não encontrado ou sem acesso.' }} /></>

  const ativos = processos.filter(p => p.situacao === 'ativo')
  const reu = processos.filter(p => p.polo === 'reu').length
  return (
    <>
      <Topo titulo={c.nome_fantasia || c.nome} sub={c.tipo === 'PJ' ? 'Empresa' : 'Pessoa física'} voltar="/clientes"
        acoes={<Link to={`/clientes/${id}/editar`} className="icone-btn so-editor" aria-label="Editar cliente"><Icone nome="editar" /></Link>} />

      <div className="kpis">
        <div className="kpi destaque"><span className="rotulo">Processos ativos</span><span className="valor">{ativos.length}</span></div>
        <div className="kpi"><span className="rotulo">Como réu / autor</span><span className="valor">{reu} / {processos.length - reu}</span></div>
      </div>

      <div className="secao"><h2>Dados</h2></div>
      <div className="cartao">
        <dl className="dados" style={{ margin: 0 }}>
          <div><dt>{c.tipo === 'PJ' ? 'Razão social' : 'Nome'}</dt><dd>{c.nome}</dd></div>
          {c.tipo === 'PJ' && <div><dt>Nome fantasia</dt><dd>{c.nome_fantasia || '—'}</dd></div>}
          <div><dt>{c.tipo === 'PJ' ? 'CNPJ' : 'CPF'}</dt><dd className="mono">{c.cpf_cnpj || '—'}</dd></div>
          <div><dt>E-mail</dt><dd>{c.email ? <a href={`mailto:${c.email}`}>{c.email}</a> : '—'}</dd></div>
          <div><dt>Telefone</dt><dd>{c.telefone ? <><a href={`tel:${c.telefone.replace(/\D/g, '')}`}>{c.telefone}</a> · <a href={`https://wa.me/55${c.telefone.replace(/\D/g, '')}`} target="_blank" rel="noreferrer">WhatsApp</a></> : '—'}</dd></div>
          {c.contato_nome && <div><dt>Pessoa de contato</dt><dd>{c.contato_nome}</dd></div>}
          {c.observacoes && <div><dt>Observações</dt><dd style={{ whiteSpace: 'pre-wrap' }}>{c.observacoes}</dd></div>}
        </dl>
      </div>

      <div className="secao"><h2>Processos novos no DJEN</h2><Link className="btn pequeno primario" to={`/pesquisa?cliente=${id}`}><Icone nome="radar" />Buscar</Link></div>
      <div className="cartao">
        {termos.length ? <div className="termos">{termos.map(t => <span key={t.id} className="termo" style={{ paddingRight: 12 }}>{t.valor}</span>)}</div>
          : <span className="muted">Nenhum nome de busca cadastrado: a busca usa a razão social.</span>}
        <small className="muted" style={{ display: 'block', marginTop: 8 }}>Todo dia o Orbeo procura no DJEN publicações com esses nomes. Processo que ainda não está no sistema gera um aviso para os advogados deste cliente (em Processos novos). <Link className="link-btn" style={{ padding: 0 }} to={`/clientes/${id}/editar`}>Editar nomes de busca</Link></small>
      </div>

      <div className="secao"><h2>Processos ({processos.length})</h2></div>
      {processos.length === 0 ? <Vazio titulo="Sem processos" texto="Nenhum processo deste cliente está na sua lista." /> :
        <div className="lista grade">{processos.map(p => <CartaoProcesso key={p.id} p={p} />)}</div>}

      <div style={{ marginTop: 28 }} className="so-editor">
        <button className="btn perigo bloco" onClick={excluir}><Icone nome="lixo" />Excluir cliente</button>
      </div>
      <Fab to={`/processos/novo?cliente=${id}`} rotulo="Processo" />
    </>
  )
}
