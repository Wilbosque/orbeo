import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import * as api from '#backend'
import Icone from '../components/Icone.jsx'
import { Carregando, Erro, Fab, Topo, Vazio, useCarregar } from '../components/ui.jsx'
import { iniciais, normalizar } from '../lib/formato.js'

export default function Clientes() {
  const r = useCarregar(() => api.listarClientes(), [])
  const [q, setQ] = useState('')
  const [tipo, setTipo] = useState('')
  const lista = r.dados || []
  const filtrados = useMemo(() => lista.filter(c =>
    (!tipo || c.tipo === tipo) &&
    (!q || normalizar(`${c.nome} ${c.nome_fantasia || ''} ${c.cpf_cnpj || ''}`).includes(normalizar(q)))), [lista, q, tipo])

  return (
    <>
      <Topo titulo="Clientes" sub={r.dados ? `${lista.length} cadastrado${lista.length === 1 ? '' : 's'}` : ' '} />
      <div className="busca">
        <Icone nome="busca" />
        <input type="search" placeholder="Nome, nome fantasia, CPF ou CNPJ" value={q} onChange={e => setQ(e.target.value)} aria-label="Buscar clientes" />
      </div>
      <div className="chips">
        <button className={`chip ${!tipo ? 'ativo' : ''}`} onClick={() => setTipo('')}>Todos</button>
        <button className={`chip ${tipo === 'PJ' ? 'ativo' : ''}`} onClick={() => setTipo(tipo === 'PJ' ? '' : 'PJ')}>Empresas</button>
        <button className={`chip ${tipo === 'PF' ? 'ativo' : ''}`} onClick={() => setTipo(tipo === 'PF' ? '' : 'PF')}>Pessoas físicas</button>
      </div>
      {r.erro && <Erro erro={r.erro} tentar={r.recarregar} />}
      {r.carregando && !r.dados ? <Carregando /> :
        lista.length === 0 ? (
          <Vazio icone="clientes" titulo="Nenhum cliente ainda" texto="Cadastre seus clientes para vincular os processos a eles.">
            <Link to="/clientes/novo" className="btn primario">Cadastrar cliente</Link>
          </Vazio>
        ) : filtrados.length === 0 ? <Vazio icone="busca" titulo="Nada encontrado" /> : (
          <div className="lista grade">
            {filtrados.map(c => (
              <Link key={c.id} to={`/clientes/${c.id}`} className="cartao" style={{ display: 'flex', gap: 12, alignItems: 'center' }}>
                <span className="avatar" style={{ width: 44, height: 44, fontSize: '.9rem', borderRadius: 12 }}>{iniciais(c.nome_fantasia || c.nome)}</span>
                <div style={{ minWidth: 0, flex: 1 }}>
                  <h3 style={{ margin: 0 }}>{c.nome_fantasia || c.nome}</h3>
                  <div className="linha">{c.tipo === 'PJ' ? 'Empresa' : 'Pessoa física'}{c.cpf_cnpj ? ` · ${c.cpf_cnpj}` : ''}</div>
                  <div className="cartao-rodape" style={{ marginTop: 6 }}>
                    <span className="selo">{c.qtd_ativos} ativo{c.qtd_ativos === 1 ? '' : 's'} · {c.qtd_processos} no total</span>
                    {c.monitorado && <span className="selo autor"><Icone nome="radar" />DJEN</span>}
                  </div>
                </div>
                <Icone nome="seta" width="20" height="20" className="faint" />
              </Link>
            ))}
          </div>
        )}
      <Fab to="/clientes/novo" rotulo="Cliente" />
    </>
  )
}
