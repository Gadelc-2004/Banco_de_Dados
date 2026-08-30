# Análise de Acidentes PRF — ETL e Modelagem em PostgreSQL

Trabalho final de Banco de Dados 2. Um pipeline completo em PL/pgSQL que importa o dataset público de acidentes rodoviários da **Polícia Rodoviária Federal (PRF)**, normaliza os dados brutos em um modelo relacional tipo estrela, protege campos sensíveis com criptografia simétrica e inclui uma suíte de testes de performance de índices sobre uma base de 5 milhões de registros.

Fonte dos dados: [Dados Abertos da PRF](https://www.gov.br/prf/pt-br/acesso-a-informacao/dados-abertos/dados-abertos-da-prf) — acidentes de 2025 agrupados por pessoa envolvida.

## O que este projeto demonstra

- **ETL dentro do banco**: uma função PL/pgSQL (`fn_importar_normalizar`) faz `COPY` do CSV para uma staging table `UNLOGGED`, limpa/padroniza os dados e os distribui entre as tabelas normalizadas — sem depender de nenhuma ferramenta externa de ETL.
- **Modelagem em estrela simplificada**: tabelas de domínio (`tb_localidade`, `tb_causa_acidente`, `tb_tipo_acidente`, `tb_condicao_via`) referenciadas pela tabela fato `tb_ocorrencia`, com `tb_veiculo_ocorrencia` e `tb_envolvimento` para a granularidade de veículo/pessoa.
- **Conversões seguras**: funções auxiliares `to_date_safe` / `to_time_safe` capturam exceções de conversão (`CSV` com "NA", campos vazios etc.) e retornam `NULL` em vez de derrubar a importação inteira.
- **Proteção de dados sensíveis**: latitude/longitude e dados pessoais dos envolvidos (idade, sexo, estado físico) são armazenados como `BYTEA` cifrado via `pgcrypto` (`pgp_sym_encrypt`), e só voltam a texto legível através da `vw_acidentes` (que faz a descriptografia sob demanda).
- **Benchmark de índices**: `fn_performance` replica os dados normalizados até 5 milhões de linhas em `tb_analise` e mede tempo de consulta antes/depois de criar índices, capturando o plano de execução (`EXPLAIN`) de cada cenário via a função auxiliar `fn_explain`.

## Modelo entidade-relacionamento

![Modelo Físico do Banco](/modelo_er.png)

## Estrutura

```
├── sql/
│   └── acidentes_prf.sql   # Script completo: funções, tabelas, views, benchmark
└── docs/
    └── modelo_er.png       # Diagrama do modelo físico (gerado no pgModeler/DBeaver)
```

## Como executar

Pré-requisitos: PostgreSQL com a extensão `pgcrypto` disponível, e o CSV de acidentes da PRF baixado localmente.

```bash
psql -U seu_usuario -d seu_banco -f sql/acidentes_prf.sql
```

O script já vem configurado para rodar em modo de teste rápido (10.000 registros). Para importar a base completa, edite a chamada no final do arquivo:

```sql
-- Troque:
SELECT * FROM fn_importar_normalizar('/tmp/acidentes2025_todas_causas_tipos.csv', 10000);
-- Por:
SELECT * FROM fn_importar_normalizar('/tmp/acidentes2025_todas_causas_tipos.csv', NULL);
```

## Nota sobre a chave de criptografia

A chave simétrica usada nas chamadas `pgp_sym_encrypt`/`pgp_sym_decrypt` está fixa no script (`'chave_bd_2025'`) para fins didáticos. Em um cenário de produção, ela deveria vir de uma variável de ambiente ou de um cofre de segredos (ex: `pgsodium`, HashiCorp Vault), nunca hardcoded no SQL versionado.

## Autor

Gabriel Almeida Della Croce — [github.com/Gadelc-2004](https://github.com/Gadelc-2004)
