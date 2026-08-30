-- Trabalho final Banco de Dados 2
-- DATA: Acidentes PRF 2025 (todas causas e tipos)
-- Documento CSV de Acidentes 2025 (Agrupados por pessoa - Todas as causas e tipos de acidentes) | https://www.gov.br/prf/pt-br/acesso-a-informacao/dados-abertos/dados-abertos-da-prf
-- Link alternativo: https://drive.google.com/file/d/1-PJGRbfSe7PVjU37A3wTCls_NRXyVGRD/view
-- Aluno: Gabriel Almeida Della Croce

-- \timing on instrui o cliente psql a medir e exibir o tempo de execução de cada comando SQL individualmente.
\timing on

-- Habilita funções de criptografia simétrica
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- algumas células podem conter valores inválidos (ex: "NA", "") | essas funções capturam a exceção e retornam NULL.
-- Converte texto para DATE sem lançar exceção em caso de falha.
-- IMMUTABLE = o PostgreSQL pode otimizar chamadas repetidas com o mesmo argumento (o resultado nunca muda para o mesmo texto).
CREATE OR REPLACE FUNCTION to_date_safe(p_text TEXT)
RETURNS DATE AS $$
BEGIN
  RETURN p_text::DATE;
EXCEPTION
  -- WHEN OTHERS captura qualquer erro de conversão
  WHEN OTHERS THEN
    RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;
-- IMMUTABLE sempre o mesmo resultado para o mesmo input

-- Mesmo princípio aplicado à conversão para TIME.
CREATE OR REPLACE FUNCTION to_time_safe(p_text TEXT)
RETURNS TIME AS $$
BEGIN
  RETURN p_text::TIME;
EXCEPTION
  WHEN OTHERS THEN
    RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;
-- IMMUTABLE sempre o mesmo resultado para o mesmo input

-- FUNÇÃO PRINCIPAL: fn_importar_normalizar
--
-- Responsabilidades (executadas em sequência):
--   1. Remover objetos de execuções anteriores (idempotência)
--   2. Importar o CSV para uma staging table (UNLOGGED)
--   3. Criar tabela temporária com limite opcional de registros
--   4. Limpar e padronizar os dados brutos
--   5. Criar as tabelas normalizadas (modelo estrela simplificado)
--   6. Popular tabelas de domínio com valores únicos
--   7. Adicionar PKs, FKs e índices de apoio
--   8. Construir tabela auxiliar de acidentes únicos (com criptografia)
--   9. Popular tb_ocorrencia, tb_veiculo_ocorrencia, tb_envolvimento
--  10. Remover índices temporários e staging
--  11. Criar a VIEW desnormalizada (com descriptografia)
--  12. Retornar os dados da VIEW ao chamador
--
-- Parâmetros:
--   p_caminho : caminho absoluto do arquivo CSV no servidor
--   p_limite  : número máximo de linhas a processar (NULL = todos)
--
-- Retorno: RETURNS TABLE com todos os campos da vw_acidentes
--   (dados já descriptografados, prontos para leitura)
-- ============================================================
DROP FUNCTION IF EXISTS fn_importar_normalizar(TEXT, INTEGER);
CREATE OR REPLACE FUNCTION fn_importar_normalizar(
  p_caminho TEXT    DEFAULT '/tmp/acidentes2025_todas_causas_tipos.csv',
  p_limite  INTEGER DEFAULT NULL
)
RETURNS TABLE (
  id_ocorrencia   INTEGER,
  data_acidente   DATE,
  dia_semana      TEXT,
  horario         TIME,
  km              NUMERIC,
  sentido_via     TEXT,
  uf              TEXT,
  municipio       TEXT,
  br              INTEGER,
  regional        TEXT,
  delegacia       TEXT,
  uop             TEXT,
  causa_acidente  TEXT,
  tipo_acidente   TEXT,
  classificacao   TEXT,
  fase_dia        TEXT,
  condicao_meteo  TEXT,
  tipo_pista      TEXT,
  tracado_via     TEXT,
  uso_solo        TEXT,
  latitude        TEXT,
  longitude       TEXT,
  id_veiculo      INTEGER,
  tipo_veiculo    TEXT,
  marca           TEXT,
  ano_fabricacao  INTEGER,
  pesid           INTEGER,
  tipo_envolvido  TEXT,
  estado_fisico   TEXT,
  idade           TEXT,
  sexo            TEXT,
  ilesos          INTEGER,
  feridos_leves   INTEGER,
  feridos_graves  INTEGER,
  mortos          INTEGER
) AS $$
BEGIN


  -- LIMPEZA DE OBJETOS ANTERIORES
  -- Garante idempotência: a função pode ser chamada múltiplas vezes sem erro de "objeto já existe".
  -- CASCADE remove automaticamente dependências

  DROP VIEW  IF EXISTS vw_acidentes            CASCADE;
  DROP TABLE IF EXISTS tb_envolvimento         CASCADE;
  DROP TABLE IF EXISTS tb_veiculo_ocorrencia   CASCADE;
  DROP TABLE IF EXISTS tb_ocorrencia           CASCADE;
  DROP TABLE IF EXISTS tb_localidade           CASCADE;
  DROP TABLE IF EXISTS tb_causa_acidente       CASCADE;
  DROP TABLE IF EXISTS tb_tipo_acidente        CASCADE;
  DROP TABLE IF EXISTS tb_condicao_via         CASCADE;
  DROP TABLE IF EXISTS tb_staging              CASCADE;

  -- TABELA STAGING (UNLOGGED) é uma área temporária de carga.
  -- UNLOGGED = não grava no WAL (Write-Ahead Log) mais rápida.
  -- Todos os campos são TEXT pois o CSV não tem tipos definidos.
  CREATE UNLOGGED TABLE tb_staging (
    id                      TEXT,  -- ID único do acidente
    pesid                   TEXT,  -- ID único da pessoa envolvida
    data_inversa            TEXT,  -- data no formato do CSV (texto)
    dia_semana              TEXT,
    horario                 TEXT,
    uf                      TEXT,  -- Unidade Federativa | Estado
    br                      TEXT,  -- número da rodovia federal
    km                      TEXT,  -- quilômetro do acidente
    municipio               TEXT,
    causa_principal         TEXT,  -- "Sim" ou "Não"
    causa_acidente          TEXT,
    ordem_tipo_acidente     TEXT,
    tipo_acidente           TEXT,
    classificacao_acidente  TEXT,  -- ex: "Com Vítimas Fatais"
    fase_dia                TEXT,  -- ex: "Pleno dia", "Anoitecer"
    sentido_via             TEXT,  -- ex: "Crescente", "Decrescente"
    condicao_metereologica  TEXT,
    tipo_pista              TEXT,  -- ex: "Simples", "Dupla"
    tracado_via             TEXT,  -- ex: "Reta", "Curva"
    uso_solo                TEXT,  -- ex: "Rural", "Urbano"
    id_veiculo              TEXT,  -- ID do veículo no CSV
    tipo_veiculo            TEXT,
    marca                   TEXT,
    ano_fabricacao_veiculo  TEXT,
    tipo_envolvido          TEXT,  -- ex: "Condutor", "Passageiro"
    estado_fisico           TEXT,  -- ex: "Ileso", "Ferido Grave" → CRIPTOGRAFADO
    idade                   TEXT,  -- dado pessoal → CRIPTOGRAFADO
    sexo                    TEXT,  -- dado pessoal → CRIPTOGRAFADO
    ilesos                  TEXT,
    feridos_leves           TEXT,
    feridos_graves          TEXT,
    mortos                  TEXT,
    latitude                TEXT,  -- coordenada geográfica → CRIPTOGRAFADA
    longitude               TEXT,  -- coordenada geográfica → CRIPTOGRAFADA
    regional                TEXT,  -- superintendência regional PRF
    delegacia               TEXT,
    uop                     TEXT   -- unidade operacional PRF
  );

  -- COPY é o comando mais eficiente do PostgreSQL para carga em massa.
  -- FORMAT CSV: interpreta o arquivo como CSV.
  -- HEADER TRUE: ignora a primeira linha (cabeçalho).
  -- DELIMITER ';': separador do CSV da PRF.
  -- ENCODING 'LATIN1': arquivo do governo brasileiro usa ISO-8859-1.
  -- EXECUTE + format() pq o copy n aceita o parametro 
  EXECUTE format(
    'COPY tb_staging FROM %L WITH (FORMAT CSV, HEADER TRUE, DELIMITER '';'', ENCODING ''LATIN1'')',
    p_caminho
  );

  -- Verificação de segurança: se a staging ficou vazia, algo deu errado
  -- (caminho incorreto, arquivo vazio, problema de permissão).
  IF NOT EXISTS (SELECT 1 FROM tb_staging LIMIT 1) THEN
    RAISE EXCEPTION 'tb_staging esta vazia. Verifique o caminho do CSV: %', p_caminho;
  END IF;

  -- TABELA TEMPORÁRIA COM LIMITE CONDICIONAL
  -- Permite processar apenas um subconjunto dos dados para testes rápidos. LIMIT NULL é equivalente a sem limite no PostgreSQL.
  CREATE TEMP TABLE tb_staging_limitada AS
  SELECT *
  FROM tb_staging
  ORDER BY id::INTEGER NULLS LAST  -- ordena para pegar os primeiros IDs
  LIMIT CASE WHEN p_limite IS NOT NULL THEN p_limite ELSE NULL END;

  -- LIMPEZA E PADRONIZAÇÃO DOS DADOS
  -- Problemas:
  --   - Campos numéricos com valor textual "NA"
  --   - Campos em branco onde deveria ser NULL
  --   - Inconsistências como "Nao Informado"
  --
  -- Estratégia:
  --   - IDs e números: valida com regex '^[0-9]+$'; se inválido → NULL
  --   - Categorias opcionais (tipo_veiculo, marca, etc.): 'NA' → NULL
  --   - Categorias obrigatórias (causa, tipo, fase, etc.): valor vazio → '(nao informado)' (nunca NULL, pois são usados como chave nas tabelas de domínio)
  -- COALESCE(NULLIF(TRIM(x), ''), 'fallback'):
  --   TRIM remove espaços, NULLIF transforma string vazia em NULL,
  --   COALESCE substitui NULL pelo valor padrão.
  -- ----------------------------------------------------------
  UPDATE tb_staging_limitada s SET
    -- IDs: aceita somente sequências puramente numéricas
    id                     = CASE WHEN s.id ~ '^[0-9]+$' THEN s.id ELSE NULL END, 
    pesid                  = CASE WHEN s.pesid ~ '^[0-9]+$' THEN s.pesid ELSE NULL END,
    id_veiculo             = CASE WHEN s.id_veiculo ~ '^[0-9]+$' THEN s.id_veiculo ELSE NULL END,
    -- Campos opcionais: 'NA' ou vazio viram NULL
    tipo_veiculo           = CASE WHEN TRIM(COALESCE(s.tipo_veiculo,'')) IN ('NA','') THEN NULL ELSE s.tipo_veiculo END,
    marca                  = CASE WHEN TRIM(COALESCE(s.marca,'')) IN ('NA','NA/NA','') THEN NULL ELSE s.marca END,
    ano_fabricacao_veiculo = CASE WHEN s.ano_fabricacao_veiculo ~ '^[0-9]+$' THEN s.ano_fabricacao_veiculo ELSE NULL END,
    -- Dados sensíveis pessoais: limpeza antes de criptografar
    idade                  = CASE WHEN TRIM(COALESCE(s.idade,'')) IN ('NA','') THEN NULL ELSE s.idade END,
    sexo                   = CASE WHEN TRIM(COALESCE(s.sexo,'')) IN ('NA','Nao Informado','') THEN NULL ELSE s.sexo END,
    estado_fisico          = CASE WHEN TRIM(COALESCE(s.estado_fisico,'')) IN ('NA','Nao Informado','') THEN NULL ELSE s.estado_fisico END,
    -- Campos de domínio: nunca NULL, usa placeholder quando vazio
    causa_acidente         = COALESCE(NULLIF(TRIM(s.causa_acidente), ''), '(nao informado)'),
    tipo_acidente          = COALESCE(NULLIF(TRIM(s.tipo_acidente), ''), '(nao informado)'),
    classificacao_acidente = COALESCE(NULLIF(TRIM(s.classificacao_acidente), ''), '(nao informado)'),
    fase_dia               = COALESCE(NULLIF(TRIM(s.fase_dia), ''), '(nao informado)'),
    condicao_metereologica = COALESCE(NULLIF(TRIM(s.condicao_metereologica), ''), '(nao informado)'),
    tipo_pista             = COALESCE(NULLIF(TRIM(s.tipo_pista), ''), '(nao informado)'),
    tracado_via            = COALESCE(NULLIF(TRIM(s.tracado_via), ''), '(nao informado)'),
    uso_solo               = COALESCE(NULLIF(TRIM(s.uso_solo), ''), '(nao informado)');

  -- CRIAÇÃO DAS TABELAS NORMALIZADAS
  --
  -- Modelo adotado: normalização até 3FN (Terceira Forma Normal).
  -- Cada entidade independente vira sua própria tabela.
  -- Chaves artificiais (SERIAL) são usadas como PKs para desacoplar a identidade interna do banco dos IDs originais do CSV.
  --
  --   tb_localidade      ← onde o acidente ocorreu (UF, município, BR)
  --   tb_causa_acidente  ← catálogo de causas
  --   tb_tipo_acidente   ← catálogo de tipos + classificação de gravidade
  --   tb_condicao_via    ← condições no momento do acidente
  --   tb_ocorrencia      ← fato central (1 linha por acidente único)
  --   tb_veiculo_ocorrencia ← veículos envolvidos (N por acidente)
  --   tb_envolvimento    ← pessoas envolvidas (N por acidente)
  -- Localidade: combinação única de UF + município + rodovia + unidades PRF
  CREATE TABLE tb_localidade (
    id         SERIAL,               -- PK artificial gerada automaticamente
    uf         TEXT    NOT NULL,
    municipio  TEXT    NOT NULL,
    br         INTEGER NOT NULL,
    regional   TEXT    NOT NULL DEFAULT '(nao informado)',
    delegacia  TEXT    NOT NULL DEFAULT '(nao informado)',
    uop        TEXT    NOT NULL DEFAULT '(nao informado)'
  );

  -- Catálogo de causas de acidente (ex: "Falta de atenção", "Velocidade")
  CREATE TABLE tb_causa_acidente (
    id        SERIAL,
    descricao TEXT NOT NULL
  );

  -- Catálogo de tipos de acidente com sua classificação de gravidade
  -- (tipo + classificação formam a chave natural — são inseparáveis)
  CREATE TABLE tb_tipo_acidente (
    id             SERIAL,
    descricao      TEXT NOT NULL,   -- ex: "Colisão traseira"
    classificacao  TEXT NOT NULL    -- ex: "Com Vítimas Fatais"
  );

  -- Condições da via no momento do acidente
  -- (agrupadas numa tabela pois sempre aparecem juntas no CSV)
  CREATE TABLE tb_condicao_via (
    id                     SERIAL,
    fase_dia               TEXT NOT NULL DEFAULT '(nao informado)',
    condicao_metereologica TEXT NOT NULL DEFAULT '(nao informado)',
    tipo_pista             TEXT NOT NULL DEFAULT '(nao informado)',
    tracado_via            TEXT NOT NULL DEFAULT '(nao informado)',
    uso_solo               TEXT NOT NULL DEFAULT '(nao informado)'
  );

  -- Tabela central de ocorrências (fato do acidente).
  -- latitude e longitude são BYTEA pois armazenam dados criptografados
  CREATE TABLE tb_ocorrencia (
    id                INTEGER,       -- ID original do CSV (não é SERIAL)
    data_acidente     DATE,
    dia_semana        TEXT,
    horario           TIME,
    km                NUMERIC,
    sentido_via       TEXT,
    causa_principal   BOOLEAN,       -- convertido de "Sim"/"Não" para booleano
    id_localidade     INTEGER NOT NULL,
    id_causa_acidente INTEGER NOT NULL,
    id_tipo_acidente  INTEGER NOT NULL,
    id_condicao_via   INTEGER NOT NULL,
    latitude          BYTEA,         -- armazenada CRIPTOGRAFADA (pgcrypto)
    longitude         BYTEA          -- armazenada CRIPTOGRAFADA (pgcrypto)
  );

  -- Veículos: um acidente pode ter N veículos envolvidos.
  -- id_veiculo_original preserva o ID do CSV para referência cruzada.
  -- A PK artificial (SERIAL) evita conflitos de IDs repetidos entre acidentes.
  CREATE TABLE tb_veiculo_ocorrencia (
    id_veiculo_ocorrencia SERIAL,
    id_ocorrencia         INTEGER NOT NULL,  -- FK para tb_ocorrencia
    id_veiculo_original   INTEGER NOT NULL,  -- ID do veículo no CSV original
    tipo_veiculo          TEXT,
    marca                 TEXT,
    ano_fabricacao        INTEGER,
    PRIMARY KEY (id_veiculo_ocorrencia),
    UNIQUE (id_ocorrencia, id_veiculo_original)  -- evita duplicação do mesmo veículo no mesmo acidente
  );

  -- Envolvidos: pessoas físicas por acidente (N por ocorrência).
  -- Dados pessoais (estado_fisico, idade, sexo) são BYTEA pois ficam criptografados
  CREATE TABLE tb_envolvimento (
    id_envolvimento       SERIAL,
    id_ocorrencia         INTEGER NOT NULL,
    pesid_original        INTEGER NOT NULL,   -- ID da pessoa no CSV
    id_veiculo_ocorrencia INTEGER,            -- FK nullable (pedestre não tem veículo)
    tipo_envolvido        TEXT,               -- ex: "Condutor", "Pedestre"
    estado_fisico         BYTEA,             -- CRIPTOGRAFADO: "Ileso", "Ferido Grave", etc.
    idade                 BYTEA,             -- CRIPTOGRAFADO: dado pessoal sensível
    sexo                  BYTEA,             -- CRIPTOGRAFADO: dado pessoal sensível
    ilesos                INTEGER DEFAULT 0,
    feridos_leves         INTEGER DEFAULT 0,
    feridos_graves        INTEGER DEFAULT 0,
    qtd_mortos            INTEGER DEFAULT 0,
    PRIMARY KEY (id_envolvimento),
    UNIQUE (id_ocorrencia, pesid_original)   -- evita duplicação da mesma pessoa no mesmo acidente
  );

  --POPULAR TABELAS DE DOMÍNIO
  -- SELECT DISTINCT garante que apenas combinações únicas sejam
  -- inseridas — equivalente a um dicionário de valores.
  -- As tabelas de domínio são populadas ANTES de tb_ocorrencia pois precisa das FKs das primeiras.

  -- Localidades únicas: combinação de UF+município+BR+unidades PRF
  INSERT INTO tb_localidade (uf, municipio, br, regional, delegacia, uop)
  SELECT DISTINCT
    s.uf,
    s.municipio,
    s.br::INTEGER,
    COALESCE(NULLIF(TRIM(s.regional),  ''), '(nao informado)'),
    COALESCE(NULLIF(TRIM(s.delegacia), ''), '(nao informado)'),
    COALESCE(NULLIF(TRIM(s.uop),       ''), '(nao informado)')
  FROM tb_staging_limitada s
  WHERE s.uf        IS NOT NULL
    AND s.municipio IS NOT NULL
    AND s.br        IS NOT NULL
    AND s.br ~ '^\d+$';  -- garante que br é numérico antes do cast

  -- Catálogo de causas únicas
  INSERT INTO tb_causa_acidente (descricao)
  SELECT DISTINCT s.causa_acidente
  FROM tb_staging_limitada s
  WHERE s.causa_acidente IS NOT NULL;

  -- Catálogo de tipos únicos (tipo + classificação são inseparáveis)
  INSERT INTO tb_tipo_acidente (descricao, classificacao)
  SELECT DISTINCT s.tipo_acidente, s.classificacao_acidente
  FROM tb_staging_limitada s
  WHERE s.tipo_acidente IS NOT NULL AND s.classificacao_acidente IS NOT NULL;

  -- Condições de via únicas (5 campos combinados formam 1 registro)
  INSERT INTO tb_condicao_via (fase_dia, condicao_metereologica, tipo_pista, tracado_via, uso_solo)
  SELECT DISTINCT s.fase_dia, s.condicao_metereologica, s.tipo_pista, s.tracado_via, s.uso_solo
  FROM tb_staging_limitada s;

  --  RESTRIÇÕES E ÍNDICES TEMPORÁRIOS
  -- PKs e FKs são adicionadas APÓS a carga para evitar overhead de validação durante o INSERT em massa (padrão ETL).
  -- Índices temporários são criados para acelerar os JOINs da etapa seguinte (popular tb_ocorrencia) e serão removidos depois.
  -- PKs e constraints UNIQUE nas tabelas de domínio
  ALTER TABLE tb_localidade     ADD PRIMARY KEY (id);
  ALTER TABLE tb_localidade     ADD UNIQUE (uf, municipio, br, regional, delegacia, uop);
  ALTER TABLE tb_causa_acidente ADD PRIMARY KEY (id);
  ALTER TABLE tb_causa_acidente ADD UNIQUE (descricao);
  ALTER TABLE tb_tipo_acidente  ADD PRIMARY KEY (id);
  ALTER TABLE tb_tipo_acidente  ADD UNIQUE (descricao, classificacao);
  ALTER TABLE tb_condicao_via   ADD PRIMARY KEY (id);
  ALTER TABLE tb_condicao_via   ADD UNIQUE (fase_dia, condicao_metereologica, tipo_pista, tracado_via, uso_solo);

  -- PKs e FKs na tabela de fatos e nas tabelas de relacionamento
  ALTER TABLE tb_ocorrencia ADD PRIMARY KEY (id);
  ALTER TABLE tb_ocorrencia ADD FOREIGN KEY (id_localidade)     REFERENCES tb_localidade(id);
  ALTER TABLE tb_ocorrencia ADD FOREIGN KEY (id_causa_acidente) REFERENCES tb_causa_acidente(id);
  ALTER TABLE tb_ocorrencia ADD FOREIGN KEY (id_tipo_acidente)  REFERENCES tb_tipo_acidente(id);
  ALTER TABLE tb_ocorrencia ADD FOREIGN KEY (id_condicao_via)   REFERENCES tb_condicao_via(id);
  ALTER TABLE tb_veiculo_ocorrencia ADD FOREIGN KEY (id_ocorrencia) REFERENCES tb_ocorrencia(id);
  ALTER TABLE tb_envolvimento ADD FOREIGN KEY (id_ocorrencia)         REFERENCES tb_ocorrencia(id);
  ALTER TABLE tb_envolvimento ADD FOREIGN KEY (id_veiculo_ocorrencia) REFERENCES tb_veiculo_ocorrencia(id_veiculo_ocorrencia);

  -- Índices temporários para acelerar os JOINs de inserção
  -- Serão removidos pois são úteis apenas durante a carga.
  CREATE INDEX idx_localidade_completa   ON tb_localidade    (uf, municipio, br, regional, delegacia, uop);
  CREATE INDEX idx_causa_descricao       ON tb_causa_acidente (descricao);
  CREATE INDEX idx_tipo_desc_class       ON tb_tipo_acidente  (descricao, classificacao);
  CREATE INDEX idx_condicao_fase_meteo   ON tb_condicao_via   (fase_dia, condicao_metereologica, tipo_pista, tracado_via, uso_solo);

  -- TABELA TEMPORÁRIA DE ACIDENTES ÚNICOS
  -- O CSV pode ter o mesmo acidente (mesmo id) repetido em múltiplas linhas — uma por pessoa/veículo envolvido.
  -- DISTINCT ON (id::INTEGER) garante uma linha por acidente.
  -- ORDER BY id::INTEGER determina qual linha é mantida em caso de duplicata (a primeira na ordem numérica do ID).
  --
  -- Aqui também ocorre a CRIPTOGRAFIA das coordenadas geográficas:
  --   pgp_sym_encrypt(valor, chave) retorna BYTEA cifrado com OpenPGP.
  --   A chave 'chave_bd_2025' é simétrica (via pgp_sym_decrypt).

  CREATE TEMP TABLE tmp_acidentes_unico AS
  SELECT DISTINCT ON (s.id::INTEGER)
    s.id::INTEGER AS sid,
    to_date_safe(s.data_inversa) AS data_inversa,  -- conversão segura
    s.dia_semana,
    to_time_safe(s.horario) AS horario,       -- conversão segura
    -- km pode ter vírgula como separador decimal (padrão BR)
    CASE WHEN s.km ~ '^[0-9]+([,.][0-9]+)?$'
         THEN REPLACE(s.km, ',', '.')::NUMERIC
         ELSE NULL END AS km,
    s.sentido_via,
    (s.causa_principal = 'Sim') AS causa_principal, -- texto → booleano
    s.uf,
    s.municipio,
    s.br::INTEGER AS br,
    COALESCE(NULLIF(TRIM(s.regional),  ''), '(nao informado)') AS regional,
    COALESCE(NULLIF(TRIM(s.delegacia), ''), '(nao informado)') AS delegacia,
    COALESCE(NULLIF(TRIM(s.uop),       ''), '(nao informado)') AS uop,
    s.causa_acidente,
    s.tipo_acidente,
    s.classificacao_acidente,
    s.fase_dia,
    s.condicao_metereologica,
    s.tipo_pista,
    s.tracado_via,
    s.uso_solo,
    -- CRIPTOGRAFIA das coordenadas geográficas (dado sensível de localização)
    CASE WHEN s.latitude IS NOT NULL AND s.latitude ~ '^-?[0-9]+([,.][0-9]+)?$'
         THEN pgp_sym_encrypt(REPLACE(s.latitude,  ',', '.'), 'chave_bd_2025')
         ELSE NULL END AS latitude_enc,
    CASE WHEN s.longitude IS NOT NULL AND s.longitude ~ '^-?[0-9]+([,.][0-9]+)?$'
         THEN pgp_sym_encrypt(REPLACE(s.longitude, ',', '.'), 'chave_bd_2025')
         ELSE NULL END AS longitude_enc
  FROM tb_staging_limitada s
  WHERE s.id IS NOT NULL AND s.id ~ '^\d+$'  -- filtra linhas sem ID válido
    AND s.br IS NOT NULL AND s.br ~ '^\d+$'  -- filtra linhas sem BR válido
  ORDER BY s.id::INTEGER;

  -- Índices na temp table para acelerar os JOINs na etapa seguinte
  CREATE INDEX ON tmp_acidentes_unico (uf, municipio, br);
  CREATE INDEX ON tmp_acidentes_unico (causa_acidente);
  CREATE INDEX ON tmp_acidentes_unico (tipo_acidente, classificacao_acidente);
  CREATE INDEX ON tmp_acidentes_unico (fase_dia, condicao_metereologica, tipo_pista, tracado_via, uso_solo);

  -- ETAPA 9: POPULAR TB_OCORRENCIA
  --
  -- Para cada acidente único, busca os IDs das tabelas de domínio via JOIN (usando os índices temporários).
  -- Insere latitude e longitude já criptografadas (BYTEA).
  INSERT INTO tb_ocorrencia (
    id, data_acidente, dia_semana, horario, km, sentido_via, causa_principal,
    id_localidade, id_causa_acidente, id_tipo_acidente, id_condicao_via,
    latitude, longitude
  )
  SELECT
    su.sid,
    su.data_inversa,
    su.dia_semana,
    su.horario,
    su.km,
    su.sentido_via,
    su.causa_principal,
    l.id,   -- FK para tb_localidade
    ca.id,  -- FK para tb_causa_acidente
    ta.id,  -- FK para tb_tipo_acidente
    cv.id,  -- FK para tb_condicao_via
    su.latitude_enc,
    su.longitude_enc
  FROM tmp_acidentes_unico su
  -- JOINs resolvem os IDs das chaves estrangeiras
  JOIN tb_localidade     l  ON l.uf        = su.uf
                            AND l.municipio = su.municipio
                            AND l.br        = su.br
                            AND l.regional  = su.regional
                            AND l.delegacia = su.delegacia
                            AND l.uop       = su.uop
  JOIN tb_causa_acidente ca ON ca.descricao    = su.causa_acidente
  JOIN tb_tipo_acidente  ta ON ta.descricao    = su.tipo_acidente
                            AND ta.classificacao = su.classificacao_acidente
  JOIN tb_condicao_via   cv ON cv.fase_dia               = su.fase_dia
                            AND cv.condicao_metereologica = su.condicao_metereologica
                            AND cv.tipo_pista             = su.tipo_pista
                            AND cv.tracado_via            = su.tracado_via
                            AND cv.uso_solo               = su.uso_solo;

  -- Descarta a temp table de acidentes únicos — não é mais necessária
  DROP TABLE tmp_acidentes_unico;

  -- POPULAR TB_VEICULO_OCORRENCIA
  --
  -- DISTINCT ON (id_ocorrencia, id_veiculo) garante unicidade:
  -- o mesmo veículo não aparece duas vezes no mesmo acidente
  -- EXISTS verifica que a ocorrência já foi inserida
  -- ----------------------------------------------------------
  INSERT INTO tb_veiculo_ocorrencia (id_ocorrencia, id_veiculo_original, tipo_veiculo, marca, ano_fabricacao)
  SELECT DISTINCT ON (s.id::INTEGER, s.id_veiculo::INTEGER)
    s.id::INTEGER,
    s.id_veiculo::INTEGER,
    s.tipo_veiculo,
    s.marca,
    -- Ano de fabricação: aceita apenas valores numéricos
    CASE WHEN s.ano_fabricacao_veiculo ~ '^\d+$'
         THEN s.ano_fabricacao_veiculo::INTEGER
         ELSE NULL END
  FROM tb_staging_limitada s
  WHERE s.id_veiculo IS NOT NULL
    AND s.id_veiculo ~ '^\d+$'
    AND s.id IS NOT NULL AND s.id ~ '^\d+$'
    AND EXISTS (SELECT 1 FROM tb_ocorrencia o WHERE o.id = s.id::INTEGER)
  ORDER BY s.id::INTEGER, s.id_veiculo::INTEGER;

  -- POPULAR TB_ENVOLVIMENTO
  --
  -- Aqui ocorre a CRIPTOGRAFIA dos dados pessoais sensíveis:
  --    estado_fisico: situação da vítima (ex: "Ferido Grave")
  --    idade: dado pessoal direto
  --    sexo: dado pessoal direto
  --
  -- pgp_sym_encrypt(texto, chave) → BYTEA cifrado com OpenPGP/AES
  -- O tipo BYTEA na tabela garante que o dado bruto não seja
  -- legível por consultas SELECT convencionais — somente quem
  -- conhece a chave e usa pgp_sym_decrypt() pode ler.
  --
  -- LEFT JOIN com tb_veiculo_ocorrencia: pedestres e outros envolvidos sem veículo ficam com id_veiculo_ocorrencia = NULL.
  INSERT INTO tb_envolvimento (
    id_ocorrencia, pesid_original, id_veiculo_ocorrencia,
    tipo_envolvido, estado_fisico, idade, sexo,
    ilesos, feridos_leves, feridos_graves, qtd_mortos
  )
  SELECT DISTINCT ON (s.id::INTEGER, s.pesid::INTEGER)
    s.id::INTEGER,
    s.pesid::INTEGER,
    v.id_veiculo_ocorrencia,  -- NULL se a pessoa não estava em veículo
    s.tipo_envolvido,
    -- Criptografia dos dados pessoais sensíveis
    CASE WHEN s.estado_fisico IS NOT NULL THEN pgp_sym_encrypt(s.estado_fisico, 'chave_bd_2025') ELSE NULL END,
    CASE WHEN s.idade         IS NOT NULL THEN pgp_sym_encrypt(s.idade,         'chave_bd_2025') ELSE NULL END,
    CASE WHEN s.sexo          IS NOT NULL THEN pgp_sym_encrypt(s.sexo,          'chave_bd_2025') ELSE NULL END,
    -- Contagens: regex garante que só converte valores numéricos válidos
    CASE WHEN TRIM(COALESCE(s.ilesos,''))        ~ '^[0-9]+$' THEN TRIM(s.ilesos)::INTEGER        ELSE 0 END,
    CASE WHEN TRIM(COALESCE(s.feridos_leves,'')) ~ '^[0-9]+$' THEN TRIM(s.feridos_leves)::INTEGER ELSE 0 END,
    CASE WHEN TRIM(COALESCE(s.feridos_graves,''))~ '^[0-9]+$' THEN TRIM(s.feridos_graves)::INTEGER ELSE 0 END,
    CASE WHEN TRIM(COALESCE(s.mortos,''))        ~ '^[0-9]+$' THEN TRIM(s.mortos)::INTEGER        ELSE 0 END
  FROM tb_staging_limitada s
  LEFT JOIN tb_veiculo_ocorrencia v
    ON  v.id_ocorrencia       = s.id::INTEGER
    AND v.id_veiculo_original = s.id_veiculo::INTEGER
  WHERE s.pesid IS NOT NULL
    AND s.pesid ~ '^\d+$'
    AND s.id IS NOT NULL AND s.id ~ '^\d+$'
    AND EXISTS (SELECT 1 FROM tb_ocorrencia o WHERE o.id = s.id::INTEGER)
  ORDER BY s.id::INTEGER, s.pesid::INTEGER;

  -- LIMPEZA FINAL
  --
  -- Remove índices temporários criados para acelerar a carga —
  -- Remove também a staging table limitada (temporária de sessão).
  DROP INDEX IF EXISTS idx_localidade_completa;
  DROP INDEX IF EXISTS idx_causa_descricao;
  DROP INDEX IF EXISTS idx_tipo_desc_class;
  DROP INDEX IF EXISTS idx_condicao_fase_meteo;
  DROP TABLE IF EXISTS tb_staging_limitada;

  -- VIEW DESNORMALIZADA vw_acidentes
  --
  -- A VIEW reconstrói a visão "plana" dos dados (como era o CSV
  -- original) fazendo JOINs entre todas as tabelas normalizadas.
  --
  -- Funcionalidades da VIEW:
  --   1. DESCRIPTOGRAFIA automática dos campos sensíveis:
  --      pgp_sym_decrypt(bytea, chave) → TEXT legível
  --      O CASE WHEN evita erro ao tentar descriptografar NULL.
  --   2. JOINs transparentes: o usuário consulta a VIEW como se
  --      fosse uma tabela única — sem precisar conhecer o modelo.
  --   3. LEFT JOIN com tb_veiculo_ocorrencia: pedestre (sem veículo)
  --      aparece na VIEW com campos de veículo como NULL.
  -- ----------------------------------------------------------
  CREATE VIEW vw_acidentes AS
  SELECT
    o.id                AS id_ocorrencia,
    o.data_acidente,
    o.dia_semana,
    o.horario,
    o.km,
    o.sentido_via,
    -- Dados de localidade (desnormalizados da tb_localidade)
    l.uf,
    l.municipio,
    l.br,
    l.regional,
    l.delegacia,
    l.uop,
    -- Dados de causa (desnormalizados da tb_causa_acidente)
    ca.descricao        AS causa_acidente,
    -- Dados de tipo (desnormalizados da tb_tipo_acidente)
    ta.descricao        AS tipo_acidente,
    ta.classificacao,
    -- Dados de condição da via (desnormalizados da tb_condicao_via)
    cv.fase_dia,
    cv.condicao_metereologica AS condicao_meteo,
    cv.tipo_pista,
    cv.tracado_via,
    cv.uso_solo,
    -- DESCRIPTOGRAFIA das coordenadas (armazenadas como BYTEA cifrado)
    CASE WHEN o.latitude  IS NOT NULL THEN pgp_sym_decrypt(o.latitude,  'chave_bd_2025') ELSE NULL END AS latitude,
    CASE WHEN o.longitude IS NOT NULL THEN pgp_sym_decrypt(o.longitude, 'chave_bd_2025') ELSE NULL END AS longitude,
    -- Dados do veículo (LEFT JOIN: NULL se pedestre)
    v.id_veiculo_original AS id_veiculo,
    v.tipo_veiculo,
    v.marca,
    v.ano_fabricacao,
    -- Dados pessoais do envolvido (com DESCRIPTOGRAFIA)
    e.pesid_original    AS pesid,
    e.tipo_envolvido,
    CASE WHEN e.estado_fisico IS NOT NULL THEN pgp_sym_decrypt(e.estado_fisico, 'chave_bd_2025') ELSE NULL END AS estado_fisico,
    CASE WHEN e.idade         IS NOT NULL THEN pgp_sym_decrypt(e.idade,         'chave_bd_2025') ELSE NULL END AS idade,
    CASE WHEN e.sexo          IS NOT NULL THEN pgp_sym_decrypt(e.sexo,          'chave_bd_2025') ELSE NULL END AS sexo,
    e.ilesos,
    e.feridos_leves,
    e.feridos_graves,
    e.qtd_mortos        AS mortos
  FROM tb_ocorrencia              o
  JOIN tb_localidade              l  ON l.id  = o.id_localidade
  JOIN tb_causa_acidente          ca ON ca.id = o.id_causa_acidente
  JOIN tb_tipo_acidente           ta ON ta.id = o.id_tipo_acidente
  JOIN tb_condicao_via            cv ON cv.id = o.id_condicao_via
  JOIN tb_envolvimento            e  ON e.id_ocorrencia = o.id
  LEFT JOIN tb_veiculo_ocorrencia v  ON v.id_veiculo_ocorrencia = e.id_veiculo_ocorrencia;

  -- RETORNO DA FUNÇÃO
  --
  -- RETURN QUERY executa a query e envia as linhas como resultado
  -- da função (equivalente a um SELECT na assinatura RETURNS TABLE).
  -- O SELECT sobre a VIEW garante que os dados retornados passam
  -- pela descriptografia definida na VIEW.
  RETURN QUERY
  SELECT
    vw.id_ocorrencia,  vw.data_acidente,  vw.dia_semana,   vw.horario,
    vw.km,             vw.sentido_via,    vw.uf,           vw.municipio,
    vw.br,             vw.regional,       vw.delegacia,    vw.uop,
    vw.causa_acidente, vw.tipo_acidente,  vw.classificacao,vw.fase_dia,
    vw.condicao_meteo, vw.tipo_pista,     vw.tracado_via,  vw.uso_solo,
    vw.latitude,       vw.longitude,      vw.id_veiculo,   vw.tipo_veiculo,
    vw.marca,          vw.ano_fabricacao, vw.pesid,        vw.tipo_envolvido,
    vw.estado_fisico,  vw.idade,          vw.sexo,
    vw.ilesos,         vw.feridos_leves,  vw.feridos_graves, vw.mortos
  FROM vw_acidentes vw;

END;
$$ LANGUAGE plpgsql;


-- FUNÇÃO AUXILIAR: fn_explain
--
-- Problema: EXPLAIN ANALYZE não é permitido dentro de funções
-- PL/pgSQL (o PostgreSQL proíbe por conflito de transação interna).
--
-- Solução: usar um loop FOR ... IN EXECUTE 'EXPLAIN ...' que
-- itera sobre as linhas do plano e as concatena em uma string.
-- Isso captura o plano COMPLETO (todas as linhas), diferente de
-- EXECUTE ... INTO que retornava apenas a primeira linha.
--
-- Uso dentro da fn_performance:
--   v_plano := fn_explain($q$SELECT ... FROM tb_analise$q$);
-- O $q$...$q$ é um dollar-quoting para evitar problemas com
-- aspas simples dentro da string SQL.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_explain(p_sql TEXT)
RETURNS TEXT AS $$
DECLARE
  v_linha TEXT;
  v_plano TEXT := '';
BEGIN
  -- FOR ... IN EXECUTE itera sobre as linhas retornadas pelo EXPLAIN
  FOR v_linha IN EXECUTE 'EXPLAIN ' || p_sql LOOP
    v_plano := v_plano || v_linha || E'\n';  -- E'\n' = newline escapado
  END LOOP;
  RETURN v_plano;
END;
$$ LANGUAGE plpgsql;


-- FUNÇÃO DE ANÁLISE DE PERFORMANCE: fn_performance
--
-- Metodologia:
--   1. Carrega dados reais das tabelas normalizadas em tb_analise
--   2. Replica os dados até atingir 5.000.000 de registros
--   3. Mede tempo de SELECT SEM índice
--   4. Cria índice e mede tempo de SELECT COM índice
--   5. Repete para outro tipo de filtro (por data)
--   6. Captura o plano de execução (EXPLAIN) para cada cenário
--
-- Retorno: RETURNS TABLE (teste TEXT, tempo TEXT)
--   Cada linha representa um teste ou o plano de execução.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_performance()
RETURNS TABLE (
  teste  TEXT,
  tempo  TEXT
) AS $$
DECLARE
  v_inicio       TIMESTAMP;  -- marcador de início para clock_timestamp()
  v_fim          TIMESTAMP;  -- marcador de fim para clock_timestamp()
  v_total        BIGINT;     -- resultado do COUNT (nº de linhas encontradas)
  v_linhas_base  BIGINT;     -- qtd de registros reais carregados
  v_linhas_atual BIGINT;     -- contador do loop de replicação
  v_plano        TEXT;       -- texto completo do plano EXPLAIN
BEGIN

  -- Remove a tabela de análise de execuções anteriores
  DROP TABLE IF EXISTS tb_analise CASCADE;

  -- tb_analise: tabela UNLOGGED para máxima velocidade de INSERT.
  -- Reúne campos de múltiplas tabelas normalizadas para simular uma tabela desnormalizada de análise.
  -- Sem PK e sem índices inicialmente → pior cenário de busca.
  CREATE UNLOGGED TABLE tb_analise (
    uf             TEXT,
    municipio      TEXT,
    causa          TEXT,
    tipo           TEXT,
    classificacao  TEXT,
    mortos         INTEGER,
    feridos        INTEGER,    -- feridos_leves + feridos_graves
    data_acidente  DATE,
    ano_fabricacao INTEGER
  );

  -- Tabela temporária para guardar os dados reais (base de replicação).
  -- ON COMMIT PRESERVE ROWS: sobrevive ao fim da transação implícita.
  CREATE TEMPORARY TABLE temp_base (
    uf             TEXT,
    municipio      TEXT,
    causa          TEXT,
    tipo           TEXT,
    classificacao  TEXT,
    mortos         INTEGER,
    feridos        INTEGER,
    data_acidente  DATE,
    ano_fabricacao INTEGER
  ) ON COMMIT PRESERVE ROWS;

  -- Carrega dados reais cruzando 5 tabelas normalizadas:
  -- tb_ocorrencia (fato central) + tb_localidade + tb_causa_acidente + tb_tipo_acidente + tb_envolvimento + tb_veiculo_ocorrencia
  INSERT INTO temp_base (uf, municipio, causa, tipo, classificacao,
                         mortos, feridos, data_acidente, ano_fabricacao)
  SELECT
    l.uf,
    l.municipio,
    ca.descricao                       AS causa,
    ta.descricao                       AS tipo,
    ta.classificacao,
    e.qtd_mortos                       AS mortos,
    e.feridos_leves + e.feridos_graves AS feridos,  -- soma os dois tipos de ferido
    o.data_acidente,
    v.ano_fabricacao
  FROM tb_ocorrencia              o
  JOIN tb_localidade              l  ON l.id  = o.id_localidade
  JOIN tb_causa_acidente          ca ON ca.id = o.id_causa_acidente
  JOIN tb_tipo_acidente           ta ON ta.id = o.id_tipo_acidente
  JOIN tb_envolvimento            e  ON e.id_ocorrencia = o.id
  LEFT JOIN tb_veiculo_ocorrencia v  ON v.id_veiculo_ocorrencia = e.id_veiculo_ocorrencia;

  SELECT COUNT(*) INTO v_linhas_base FROM temp_base;

  -- Guarda de segurança: se não há dados, a função retorna erro amigável
  IF v_linhas_base = 0 THEN
    teste := 'ERRO: sem dados — execute fn_importar_normalizar() primeiro';
    tempo := '0 ms';
    DROP TABLE IF EXISTS temp_base;
    RETURN NEXT;
    RETURN;
  END IF;

  -- SIMULAÇÃO 1: INSERT de 5.000.000 registros SEM índice
  --
  -- Técnica de replicação exponencial:
  --   - Insere a base real uma vez
  --   - A cada iteração dobra (aproximadamente) o volume
  --   - Para exatamente em 5M usando LIMIT para ajuste fino
  -- UNLOGGED + sem PK = cenário mais rápido para INSERT puro.
  -- clock_timestamp() mede o tempo de relógio real (wall-clock),
  -- diferente de now() que retorna o início da transação.
  v_inicio := clock_timestamp();

  -- Primeira carga: dados reais
  INSERT INTO tb_analise (uf, municipio, causa, tipo, classificacao,
                          mortos, feridos, data_acidente, ano_fabricacao)
  SELECT uf, municipio, causa, tipo, classificacao,
         mortos, feridos, data_acidente, ano_fabricacao
  FROM temp_base;

  SELECT COUNT(*) INTO v_linhas_atual FROM tb_analise;

  -- Loop de replicação: insere de si mesma até atingir 5M
  WHILE v_linhas_atual < 5000000 LOOP
    INSERT INTO tb_analise (uf, municipio, causa, tipo, classificacao,
                            mortos, feridos, data_acidente, ano_fabricacao)
    SELECT uf, municipio, causa, tipo, classificacao,
           mortos, feridos, data_acidente, ano_fabricacao
    FROM tb_analise
    LIMIT GREATEST(1, 5000000 - v_linhas_atual);  -- não ultrapassa 5M

    SELECT COUNT(*) INTO v_linhas_atual FROM tb_analise;
  END LOOP;

  v_fim := clock_timestamp();
  teste := 'INSERT 5.000.000 registros SEM indice (UNLOGGED, sem PK)';
  tempo := (v_fim - v_inicio)::TEXT;
  RETURN NEXT;  -- envia esta linha como resultado da função

  DROP TABLE IF EXISTS temp_base;  -- libera memória

  -- SIMULAÇÃO 2: SELECT SEM índice
  --
  -- Filtro composto: uf = 'SP' AND mortos > 0
  -- Sem índice, o PostgreSQL faz um Seq Scan (varredura totalde todas as 5M linhas).
  v_inicio := clock_timestamp();
  SELECT COUNT(*) INTO v_total FROM tb_analise WHERE uf = 'SP' AND mortos > 0;
  v_fim := clock_timestamp();
  teste := 'SELECT SEM indice (uf=SP e mortos>0) -> ' || v_total || ' linhas';
  tempo := (v_fim - v_inicio)::TEXT;
  RETURN NEXT;

  -- Captura o plano de execução SEM índice via fn_explain.
  -- Esperado: "Seq Scan on tb_analise" — varredura completa.
  v_plano := fn_explain($q$SELECT COUNT(*) FROM tb_analise WHERE uf = 'SP' AND mortos > 0$q$);
  teste := '[EXPLAIN] SELECT SEM indice (uf=SP e mortos>0)';
  tempo := v_plano;
  RETURN NEXT;

  -- CRIAÇÃO DO ÍNDICE COMPOSTO
  -- Índice em (uf, mortos): otimiza filtros que usam ambas as colunas.
  -- ANALYZE atualiza as estatísticas do planner para que ele saiba que o índice existe e possa decidir usá-lo.
  CREATE INDEX idx_analise_uf_mortos ON tb_analise (uf, mortos);
  ANALYZE tb_analise;

  -- SIMULAÇÃO 3: SELECT COM índice (mesmo filtro)
  v_inicio := clock_timestamp();
  SELECT COUNT(*) INTO v_total FROM tb_analise WHERE uf = 'SP' AND mortos > 0;
  v_fim := clock_timestamp();
  teste := 'SELECT COM indice  (uf=SP e mortos>0) -> ' || v_total || ' linhas';
  tempo := (v_fim - v_inicio)::TEXT;
  RETURN NEXT;

  v_plano := fn_explain($q$SELECT COUNT(*) FROM tb_analise WHERE uf = 'SP' AND mortos > 0$q$);
  teste := '[EXPLAIN] SELECT COM indice (uf=SP e mortos>0)';
  tempo := v_plano;
  RETURN NEXT;

  -- SIMULAÇÃO 4: SELECT por data SEM índice
  -- Filtro de range em coluna DATE sem índice.
  v_inicio := clock_timestamp();
  SELECT COUNT(*) INTO v_total FROM tb_analise WHERE data_acidente >= '2025-01-01';
  v_fim := clock_timestamp();
  teste := 'SELECT por data SEM indice (>= 2025-01-01) -> ' || v_total || ' linhas';
  tempo := (v_fim - v_inicio)::TEXT;
  RETURN NEXT;

  v_plano := fn_explain($q$SELECT COUNT(*) FROM tb_analise WHERE data_acidente >= '2025-01-01'$q$);
  teste := '[EXPLAIN] SELECT por data SEM indice (>= 2025-01-01)';
  tempo := v_plano;
  RETURN NEXT;

  -- Índice em data_acidente para range queries
  CREATE INDEX idx_analise_data ON tb_analise (data_acidente);
  ANALYZE tb_analise;

  -- SIMULAÇÃO 5: SELECT por data COM índice
  --
  -- Se o resultado é grande (próximo de 100% da tabela), o planner pode IGNORAR o índice e usar Seq Scan mesmo assim.
  SELECT COUNT(*) INTO v_total FROM tb_analise WHERE data_acidente >= '2025-01-01';
  v_fim := clock_timestamp();
  teste := 'SELECT por data COM indice  (>= 2025-01-01) -> ' || v_total || ' linhas';
  tempo := (v_fim - v_inicio)::TEXT;
  RETURN NEXT;

  v_plano := fn_explain($q$SELECT COUNT(*) FROM tb_analise WHERE data_acidente >= '2025-01-01'$q$);
  teste := '[EXPLAIN] SELECT por data COM indice (>= 2025-01-01)';
  tempo := v_plano;
  RETURN NEXT;

END;
$$ LANGUAGE plpgsql;


-- EXECUÇÃO DAS FUNÇÕES

-- PASSO 1: Importa e normaliza 10.000 registros (modo teste rápido) Para processar todos os dados, substitua 10000 por NULL.
\echo '>>> Iniciando fn_importar_normalizar com 10.000 registros...'
SELECT * FROM fn_importar_normalizar('/tmp/acidentes2025_todas_causas_tipos.csv', 10000);
\echo '>>> fn_importar_normalizar CONCLUIDA.'

-- Para importar todos os registros, comente o SELECT acima e descomente:
-- \echo '>>> Iniciando fn_importar_normalizar com TODOS os registros...'
-- SELECT * FROM fn_importar_normalizar('/tmp/acidentes2025_todas_causas_tipos.csv', NULL);
-- \echo '>>> fn_importar_normalizar CONCLUIDA (todos os registros).'

-- PASSO 2: Executa os testes de performance
-- Requer que fn_importar_normalizar tenha sido executada antes.
\echo '>>> Iniciando fn_performance (INSERT 5M + buscas com/sem indice)...'
SELECT * FROM fn_performance();
\echo '>>> fn_performance CONCLUIDA.'