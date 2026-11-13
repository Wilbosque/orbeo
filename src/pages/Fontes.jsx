import { useState } from 'react'
import * as api from '#backend'
import Icone from '../components/Icone.jsx'
import { Campo, Carregando, Erro, Folha, Topo, useCarregar, useToast } from '../components/ui.jsx'
import { TRIBUNAIS } from '../lib/suspensao.js'

function situacao(f) {
  if (!f.ativo) return ['selo', 'Pausada']
  if (!f.url) return ['selo alerta', 'Falta o endereço']
  if (f.ultimo_erro) return ['selo perigo', 'Erro na última leitura']
  if (f.ultimo_sucesso) return ['selo autor', `Lida em ${new Date(f.ultimo_sucesso).toLocaleDateString('pt-BR')}`]
  return ['selo', 'Aguardando 1ª leitura']
}

export default function Fontes() {
  const toast = useToast()
  const r = useCarregar(() => api.listarFontes(), [])
  const [editar, setEditar] = useState(null)

  async function salvar(e) {
    e.preventDefault()
    try { await api.salvarFonte(editar); toast('Fonte salva.'); setEditar(null); r.recarregar() }
    catch (err) { toast(err.message, 'erro') }
  }

  return (
    <>
      <Topo titulo="Fontes dos diários" sub="Onde a varredura procura suspensões" voltar="/ajustes"
        acoes={<button className="icone-btn" onClick={() => setEditar({ tribunal: '', url: '', ativo: true, nova: true })} aria-label="Incluir tribunal"><Icone nome="mais_add" /></button>} />
      <div className="aviso info" style={{ marginBottom: 12 }}>
        <Icone nome="info" />
        <div>Cada tribunal publica seus decretos e portarias num lugar diferente. Quando entra o primeiro processo de um tribunal, ele aparece aqui sozinho; basta informar o endereço da página de atos ou do diário administrativo. A varredura diária lê essas páginas e manda as suspensões encontradas para a sua confirmação.</div>
      </div>
      {r.erro && <Erro erro={r.erro} tentar={r.recarregar} />}
      {r.carregando && !r.dados ? <Carregando n={3} /> : (
        <div className="lista grade">
          {r.dados.map(f => {
            const [cls, txt] = situacao(f)
            return (
              <button key={f.tribunal} className="cartao" onClick={() => setEditar(f)}>
                <div className="cartao-topo"><h3 style={{ margin: 0 }}>{f.tribunal}</h3><span className={cls}>{txt}</span></div>
                <div className="linha">{f.url || 'Toque para informar o endereço'}</div>
                {f.ultimo_erro && <div className="linha" style={{ color: 'var(--danger)' }}>{f.ultimo_erro}</div>}
              </button>
            )
          })}
        </div>
      )}
      <Folha titulo={editar?.nova ? 'Incluir tribunal' : `Fonte · ${editar?.tribunal}`} aberta={Boolean(editar)} fechar={() => setEditar(null)}>
        {editar && (
          <form className="form" onSubmit={salvar}>
            {editar.nova && (
              <Campo rotulo="Tribunal" obrigatorio>
                <input className="entrada" list="trib-fontes" value={editar.tribunal} onChange={e => setEditar({ ...editar, tribunal: e.target.value.toUpperCase() })} required />
                <datalist id="trib-fontes">{TRIBUNAIS.map(t => <option key={t} value={t} />)}</datalist>
              </Campo>
            )}
            <Campo rotulo="Endereço da página de atos / diário administrativo" ajuda="Ex.: a página onde o tribunal lista decretos, portarias e atos normativos.">
              <input className="entrada" type="url" inputMode="url" value={editar.url || ''} onChange={e => setEditar({ ...editar, url: e.target.value })} placeholder="https://" />
            </Campo>
            <label className="caixa-check">
              <input type="checkbox" checked={editar.ativo} onChange={e => setEditar({ ...editar, ativo: e.target.checked })} />
              <div><b>Varredura ativa</b><span>Desmarque para pausar a leitura deste tribunal.</span></div>
            </label>
            <button className="btn primario bloco">Salvar</button>
          </form>
        )}
      </Folha>
    </>
  )
}
