#!/usr/bin/env bash
#
# Script de automação e configuração do ambiente e Data Lake (AWS S3) - MonTech
# Usa o IAM Instance Profile da EC2 (LabInstanceProfile): não pede credenciais.
#

# Garante que o cursor volte a ficar visível caso o script seja interrompido
trap 'tput cnorm 2>/dev/null || true' EXIT INT TERM

# Cores para feedback visual
VERDE="\033[1;32m"
VERMELHO="\033[1;31m"
AMARELO="\033[1;33m"
CIANO="\033[1;36m"
AZUL="\033[1;34m"
RESET="\033[0m"

# Função para executar comandos com barra giratória (spinner)
executar_com_spinner() {
    local mensagem="$1"
    shift
    local comando="$*"
    local log_temp
    log_temp=$(mktemp)

    # Executa em subshell em background redirecionando as saídas
    ( eval "$comando" ) > "$log_temp" 2>&1 &
    local pid=$!

    # Caracteres da animação (barra invertida, barra reta, traço, barra comum)
    local spin_chars=('|' '/' '-' '\')
    local i=0
    local delay=0.1

    # Oculta o cursor durante a animação
    tput civis 2>/dev/null || true

    while kill -0 "$pid" 2>/dev/null; do
        printf "\r\033[K${CIANO}[%s]${RESET} %s" "${spin_chars[i]}" "$mensagem"
        i=$(( (i + 1) % 4 ))
        sleep "$delay"
    done

    wait "$pid"
    local exit_status=$?

    # Restaura o cursor
    tput cnorm 2>/dev/null || true

    if [ "$exit_status" -eq 0 ]; then
        printf "\r\033[K${VERDE}[OK]${RESET} %s\n" "$mensagem"
        rm -f "$log_temp"
        return 0
    else
        printf "\r\033[K${VERMELHO}[ERRO]${RESET} %s\n" "$mensagem"
        echo -e "${VERMELHO}--- Detalhes do erro: ---${RESET}"
        cat "$log_temp"
        echo -e "${VERMELHO}-------------------------${RESET}"
        rm -f "$log_temp"
        return "$exit_status"
    fi
}

echo "================================================="
echo "      CONFIGURANDO AMBIENTE - MONTECH         "
echo "================================================="
echo ""

executar_com_spinner "Configurando fuso horário de São Paulo..." "sudo timedatectl set-timezone America/Sao_Paulo"
echo "Horário atual: $(date)"
echo ""

executar_com_spinner "Instalando dependências do sistema (Python, Pip, Venv, Unzip e Curl)..." \
    "sudo DEBIAN_FRONTEND=noninteractive apt-get update -y && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-pip python3-venv unzip curl"

executar_com_spinner "Criando o ambiente virtual Python (venv)..." "python3 -m venv venv"

executar_com_spinner "Instalando OpenJDK 21..." \
    "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y openjdk-21-jdk"

if command -v java &>/dev/null; then
    echo -e "${AZUL}Versão Java instalada:${RESET} $(java -version 2>&1 | head -n 1)"
fi

executar_com_spinner "Instalando AWS CLI v2..." \
    "curl -fsSL 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o 'awscliv2.zip' && unzip -qo awscliv2.zip && sudo ./aws/install --update && rm -rf aws awscliv2.zip"

if command -v aws &>/dev/null; then
    echo -e "${AZUL}Versão instalada:${RESET} $(aws --version)"
fi
# Instalação do Docker Engine (repositório oficial para Ubuntu)
instalar_docker() {
    set -e
    export DEBIAN_FRONTEND=noninteractive

    sudo apt-get update -y
    sudo apt-get install -y ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    # Adiciona o repositório às fontes do Apt
    sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    sudo systemctl start docker.service
    sudo systemctl enable docker.service

    # Permite usar o docker sem sudo (vale a partir de um novo login)
    sudo usermod -aG docker "$(whoami)"
}

executar_com_spinner "Instalando Docker Engine e Docker Compose..." "instalar_docker"

if command -v docker &>/dev/null; then
    echo -e "${AZUL}Versão Docker instalada:${RESET} $(docker --version)"
    echo -e "${AMARELO}Obs:${RESET} para usar o docker sem sudo, faça logout/login ou rode: newgrp docker"
fi
# Banco de dados MySQL em container Docker (MonTech)
DB_DIR="$HOME/montech-db"
DB_IMAGE="montech-mysql"
DB_CONTAINER="montech-db"

echo ""
read -r -s -p "Senha root do MySQL [suaSenhaForte]: " MYSQL_ROOT_PASSWORD
echo ""
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-suaSenhaForte}

# Usuário adicional (sem privilégios de root) com acesso ao banco montech
read -r -p "Nome do usuário adicional do MySQL [montech]: " MYSQL_USER
MYSQL_USER=${MYSQL_USER:-montech}
while [ "$MYSQL_USER" = "root" ]; do
    read -r -p "O nome 'root' já existe. Escolha outro nome de usuário: " MYSQL_USER
done

MYSQL_PASSWORD=""
while [ -z "$MYSQL_PASSWORD" ]; do
    read -r -s -p "Senha do usuário '$MYSQL_USER': " MYSQL_PASSWORD
    echo ""
    [ -z "$MYSQL_PASSWORD" ] && echo -e "${AMARELO}A senha não pode ser vazia.${RESET}"
done

# Cria a pasta do banco com o montech.sql e o Dockerfile
preparar_arquivos_banco() {
    set -e
    mkdir -p "$DB_DIR"

    cat > "$DB_DIR/montech.sql" <<'SQL_EOF'
CREATE DATABASE IF NOT EXISTS montech;

USE montech;

CREATE TABLE empresa (
  idEmpresa INT NOT NULL AUTO_INCREMENT,
  razaoSocial VARCHAR(200) NOT NULL,
  cnpj CHAR(14) NOT NULL,
  email VARCHAR(200),
  cep CHAR(8),
  numero VARCHAR(10),
  statusAtividade TINYINT NOT NULL DEFAULT 1,
  PRIMARY KEY (idEmpresa),
  UNIQUE KEY uq_empresa_cnpj (cnpj)
);

CREATE TABLE aeroporto (
  idAeroporto INT NOT NULL AUTO_INCREMENT,
  nome VARCHAR(100) NOT NULL,
  codigoAeroporto VARCHAR(10) NOT NULL,
  statusAtividade TINYINT NOT NULL DEFAULT 1,
  urlJira VARCHAR(255) NOT NULL,
  emailJira VARCHAR(255) NOT NULL,
  tokenJira VARCHAR(255) NOT NULL,
  fkEmpresa INT NOT NULL,
  PRIMARY KEY (idAeroporto),
  UNIQUE KEY uq_aeroporto_empresa_codigo (fkEmpresa, codigoAeroporto),
  CONSTRAINT fk_aeroporto_empresa FOREIGN KEY (fkEmpresa)
    REFERENCES empresa (idEmpresa)
);

CREATE TABLE cargo (
  idCargo INT NOT NULL AUTO_INCREMENT,
  nome VARCHAR(100) NOT NULL,
  descricao VARCHAR(250),
  statusAtividade TINYINT NOT NULL DEFAULT 1,
  empresa_idEmpresa INT NOT NULL,
  PRIMARY KEY (idCargo),
  UNIQUE KEY uq_cargo_nome (nome),
  CONSTRAINT fk_cargo_empresa FOREIGN KEY (empresa_idEmpresa)
    REFERENCES empresa (idEmpresa)
);

CREATE TABLE permissao (
  idPermissao INT NOT NULL AUTO_INCREMENT,
  nome VARCHAR(100) NOT NULL,
  descricao VARCHAR(250),
  PRIMARY KEY (idPermissao),
  UNIQUE KEY uq_permissao_nome (nome)
);

CREATE TABLE componente (
  idComponente INT NOT NULL AUTO_INCREMENT,
  nomeComponente VARCHAR(100) NOT NULL,
  unidadeMedida VARCHAR(30) NOT NULL,
  codigo VARCHAR(100) NOT NULL,
  nomeCodigo VARCHAR(50) NOT NULL,
  PRIMARY KEY (idComponente),
  UNIQUE KEY uq_componente_nome (nomeComponente)
);

CREATE TABLE servidor (
  idServidor INT NOT NULL AUTO_INCREMENT,
  token VARCHAR(32) UNIQUE NOT NULL,
  nomeServidor VARCHAR(100) NOT NULL,
  sistemaOperacional VARCHAR(100) NOT NULL,
  intervaloColeta INT DEFAULT NULL,
  statusAtividade TINYINT NOT NULL DEFAULT 0,
  fkAeroporto INT NOT NULL,
  PRIMARY KEY (idServidor),
  CONSTRAINT fk_servidor_aeroporto FOREIGN KEY (fkAeroporto)
    REFERENCES aeroporto (idAeroporto),
  CONSTRAINT ck_servidor_intervalo
    CHECK (intervaloColeta IS NULL OR intervaloColeta > 0)
);


CREATE TABLE usuario (
  idUsuario INT NOT NULL AUTO_INCREMENT,
  nome VARCHAR(100) NOT NULL,
  email VARCHAR(200) NOT NULL,
  senha VARCHAR(50) NOT NULL,
  cpf CHAR(11) NOT NULL,
  telefone VARCHAR(20),
  statusAtividade TINYINT NOT NULL DEFAULT 1,
  fkCargo INT NOT NULL,
  fkAeroporto INT NOT NULL,
  PRIMARY KEY (idUsuario),
  UNIQUE KEY uq_usuario_email (email),
  UNIQUE KEY uq_usuario_cpf (cpf),
  CONSTRAINT fk_usuario_cargo FOREIGN KEY (fkCargo)
    REFERENCES cargo (idCargo),
  CONSTRAINT fk_usuario_aeroporto FOREIGN KEY (fkAeroporto)
    REFERENCES aeroporto (idAeroporto)
);

CREATE TABLE servidorcomponente (
  idServidorComponente INT NOT NULL AUTO_INCREMENT,
  fkServidor INT NOT NULL,
  fkComponente INT NOT NULL,
  limiteAtencao DECIMAL(10,2),
  limiteCritico DECIMAL(10,2),
  PRIMARY KEY (idServidorComponente),
  UNIQUE KEY uq_servidor_componente_instancia
    (fkServidor, fkComponente),
  CONSTRAINT fk_servidorcomponente_servidor FOREIGN KEY (fkServidor)
    REFERENCES servidor (idServidor),
  CONSTRAINT fk_servidorcomponente_componente FOREIGN KEY (fkComponente)
    REFERENCES componente (idComponente),
  CONSTRAINT ck_servidorcomponente_limites CHECK (
    limiteAtencao IS NOT NULL OR limiteCritico IS NOT NULL
    OR limiteAtencao <= limiteCritico
  )
);

CREATE TABLE chamado (
  idChamado INT NOT NULL AUTO_INCREMENT,
  titulo VARCHAR(200) NOT NULL,
  descricao VARCHAR(255) NOT NULL,
  statusChamado ENUM('ABERTO', 'ATENCAO', 'CRITICO', 'FECHADO') NOT NULL DEFAULT 'ABERTO',
  linkJira VARCHAR(500) NOT NULL,
  dt_inicio DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  dt_fim DATETIME,
  fkServidorComponente INT NOT NULL,
  PRIMARY KEY (idChamado, fkServidorComponente),
  CONSTRAINT fk_chamado_servidorcomponente FOREIGN KEY (fkServidorComponente)
    REFERENCES servidorcomponente (idServidorComponente),
  CONSTRAINT ck_chamado_datas CHECK (
    dt_fim IS NULL OR dt_fim >= dt_inicio
  )
);


CREATE TABLE cargopermissao (
  idCargoPermissao INT NOT NULL AUTO_INCREMENT,
  fkCargo INT NOT NULL,
  fkPermissao INT NOT NULL,
  dataConcessao DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (idCargoPermissao),
  UNIQUE KEY uq_cargopermissao (fkCargo, fkPermissao),
  CONSTRAINT fk_cargopermissao_cargo FOREIGN KEY (fkCargo)
    REFERENCES cargo (idCargo),
  CONSTRAINT fk_cargopermissao_permissao FOREIGN KEY (fkPermissao)
    REFERENCES permissao (idPermissao)
);

CREATE TABLE visualizacao (
  idVisualizacao INT NOT NULL AUTO_INCREMENT,
  fkUsuario INT NOT NULL,
  fkServidor INT NOT NULL,
  dataInicioAcesso DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  dataFimAcesso DATETIME,
  PRIMARY KEY (idVisualizacao),
  UNIQUE KEY uq_visualizacao_usuario_servidor (fkUsuario, fkServidor),
  CONSTRAINT fk_visualizacao_usuario FOREIGN KEY (fkUsuario)
    REFERENCES usuario (idUsuario),
  CONSTRAINT fk_visualizacao_servidor FOREIGN KEY (fkServidor)
    REFERENCES servidor (idServidor),
  CONSTRAINT ck_visualizacao_periodo CHECK (
    dataFimAcesso IS NULL OR dataFimAcesso >= dataInicioAcesso
  )
);

-- ------------------------------------------------------------
-- EMPRESA (ids 1 e 2)
-- ------------------------------------------------------------
INSERT INTO empresa (razaoSocial, cnpj, email, cep, numero, statusAtividade) VALUES
('Aeroportos Paulistas S.A.',    '11222333000181', 'contato@aeroportospaulistas.com.br', '01310100', '1578', 1),  -- 1
('Campinas Aero Operações LTDA', '45723174000110', 'ti@campinasaero.com.br',             '13054750', '300',  1);  -- 2
 
-- ------------------------------------------------------------
-- AEROPORTO (ids 1 a 3) -> fkEmpresa
-- ------------------------------------------------------------
INSERT INTO aeroporto (nome, codigoAeroporto, statusAtividade, urlJira, emailJira, tokenJira, fkEmpresa) VALUES
('Aeroporto Internacional de Guarulhos', 'GRU', 1, "https://montechsd.atlassian.net", "botmontech@protonmail.com", "ATATT3xFfGF0MWo_zxNbNrvWLE8wpvRB55h4rCyyNi6sECykHLR_yjItk9siiVcZ8iKrBWsWx21-UlRgeKEDexxvERCGRC7nKLfky_i-rvl9kL0DBDS1EIQ5bBoVTHMvksNY_uoZ9_YRkBBe_y_cyPe_HRPlsGTpK8VmSBM49qJCK3zbi3zwxSY=0F6A4BB3" ,1),  -- 1 (Aeroportos Paulistas)
('Aeroporto de Congonhas',               'CGH', 1, "https://montechsd.atlassian.net", "botmontech@protonmail.com", "ATATT3xFfGF0MWo_zxNbNrvWLE8wpvRB55h4rCyyNi6sECykHLR_yjItk9siiVcZ8iKrBWsWx21-UlRgeKEDexxvERCGRC7nKLfky_i-rvl9kL0DBDS1EIQ5bBoVTHMvksNY_uoZ9_YRkBBe_y_cyPe_HRPlsGTpK8VmSBM49qJCK3zbi3zwxSY=0F6A4BB3" ,1),  -- 2 (Aeroportos Paulistas)
('Aeroporto Internacional de Viracopos', 'VCP', 1, "https://montechsd.atlassian.net", "botmontech@protonmail.com", "ATATT3xFfGF0MWo_zxNbNrvWLE8wpvRB55h4rCyyNi6sECykHLR_yjItk9siiVcZ8iKrBWsWx21-UlRgeKEDexxvERCGRC7nKLfky_i-rvl9kL0DBDS1EIQ5bBoVTHMvksNY_uoZ9_YRkBBe_y_cyPe_HRPlsGTpK8VmSBM49qJCK3zbi3zwxSY=0F6A4BB3" ,2);  -- 3 (Campinas Aero)

-- ------------------------------------------------------------
-- CARGO (ids 1 a 5) -> empresa_idEmpresa
-- ------------------------------------------------------------
INSERT INTO cargo (nome, descricao, statusAtividade, empresa_idEmpresa) VALUES
('Administrador',              'Acesso total: gerencia usuários, servidores, limites e relatórios',       1, 1),  -- 1
('Analista de Infraestrutura', 'Configura servidores e limites e acompanha a saúde da infraestrutura',    1, 1),  -- 2
('Operador de Monitoramento',  'Acompanha os painéis em tempo real e sinaliza incidentes',                1, 1),  -- 3
('Gerente de TI',              'Responsável pela área de TI do aeroporto, gestão de equipe e relatórios', 1, 2),  -- 4
('Técnico de Campo',           'Realiza manutenção e cadastro físico dos servidores',                     1, 2);  -- 5
 
-- ------------------------------------------------------------
-- PERMISSAO (ids 1 a 5)
-- ------------------------------------------------------------
INSERT INTO permissao (nome, descricao) VALUES
('VISUALIZAR_DASHBOARD', 'Permite visualizar os painéis de monitoramento'),             -- 1
('GERENCIAR_SERVIDORES', 'Permite cadastrar, editar e desativar servidores'),           -- 2
('GERENCIAR_USUARIOS',   'Permite cadastrar, editar e desativar usuários'),             -- 3
('CONFIGURAR_LIMITES',   'Permite definir os limites de atenção e crítico dos componentes'),  -- 4
('EXPORTAR_RELATORIOS',  'Permite gerar e exportar relatórios de desempenho'),          -- 5
('VISUALIZAR_DASHBOARD_GESTOR', 'Permite visualizar o painel gerencial');               -- 6 
-- ------------------------------------------------------------
-- CARGOPERMISSAO -> (fkCargo, fkPermissao)
-- ------------------------------------------------------------
INSERT INTO cargopermissao (fkCargo, fkPermissao) VALUES
-- Administrador: tudo
(1, 1), (1, 2), (1, 3), (1, 4), (1, 5), (1, 6),
-- Analista de Infraestrutura: dashboard, servidores, limites, relatórios
(2, 1), (2, 2), (2, 4), (2, 5),
-- Operador de Monitoramento: só dashboard
(3, 1),
-- Gerente de TI: dashboard, usuários, limites, relatórios
(4, 1), (4, 3), (4, 4), (4, 5), (4, 6),
-- Técnico de Campo: dashboard e servidores
(5, 1), (5, 2);
 
-- ------------------------------------------------------------
-- USUARIO (ids 1 a 5) -> fkCargo, fkAeroporto
-- Senha em texto puro porque o coletor compara senha = %s direto.
-- Cargo e aeroporto sempre da mesma empresa.
-- ------------------------------------------------------------
INSERT INTO usuario (nome, email, senha, cpf, telefone, statusAtividade, fkCargo, fkAeroporto) VALUES
('Carlos Silva',      'carlos.silva@aeroportospaulistas.com.br',  'Admin@123',    '11144477735', '11987654321', 1, 1, 1),  -- 1 Administrador / GRU
('Mariana Souza',     'mariana.souza@aeroportospaulistas.com.br', 'Analista@123', '52998224725', '11976543210', 1, 2, 1),  -- 2 Analista / GRU
('Rafael Lima',       'rafael.lima@aeroportospaulistas.com.br',   'Operador@123', '39053344705', '11965432109', 1, 3, 2),  -- 3 Operador / CGH
('Fernanda Oliveira', 'fernanda.oliveira@campinasaero.com.br',    'Gerente@123',  '16899535009', '19987654321', 1, 4, 3),  -- 4 Gerente de TI / VCP
('João Pereira',      'joao.pereira@campinasaero.com.br',         'Tecnico@123',  '71428793860', '19976543210', 1, 5, 3);  -- 5 Técnico de Campo / VCP
 
-- ------------------------------------------------------------
-- COMPONENTE (ids 1 a 11)
-- "codigo" = expressão Python executada pelo eval() do coletor
-- "nomeCodigo" = nome da coluna no CSV
-- ------------------------------------------------------------
INSERT INTO componente (nomeComponente, unidadeMedida, codigo, nomeCodigo) VALUES
('Uso de CPU (Geral)',     'porcentagem',         'psutil.cpu_percent(interval=1)',                                  'UsoCPU_Geral'),          -- 1
-- ('Uso de CPU (Por Core)',  'porcentagem',         'psutil.cpu_percent(percpu=True)',                                 'UsoCPU_Por_Core'),       -- 2
('Uso de RAM',             'porcentagem',         'psutil.virtual_memory().percent',                                 'UsoRAM'),                -- 3
('Swap In',                'bytes',     'psutil.swap_memory().sin',                                        'Swap_In'),               -- 4
('Swap Out',               'bytes',     'psutil.swap_memory().sout',                                       'Swap_Out'),              -- 5
('Uso de Disco',           'porcentagem',         'psutil.disk_usage("C:\\\\" if os.name == "nt" else "/").percent', 'UsoDisco'),              -- 6
('Leitura de Disco',       'bytes',     'psutil.disk_io_counters().read_bytes',                            'Disco_Read_Bytes'),      -- 7
('Escrita de Disco',       'bytes',     'psutil.disk_io_counters().write_bytes',                           'Disco_Write_Bytes'),     -- 8
('Rede - Bytes Enviados',  'bytes',     'psutil.net_io_counters().bytes_sent',                             'Rede_Bytes_Enviados'),   -- 9
('Rede - Bytes Recebidos', 'bytes',     'psutil.net_io_counters().bytes_recv',                             'Rede_Bytes_Recebidos'),  -- 10
('Processos Ativos',       'processos', 'len(psutil.pids())',                                              'Qtd_Processos');         -- 11
 
-- ------------------------------------------------------------
-- SERVIDOR (ids 1 a 4) -> fkAeroporto
-- token com exatamente 32 caracteres; intervaloColeta em segundos (NULL = padrão)
-- ------------------------------------------------------------
INSERT INTO servidor (token, nomeServidor, sistemaOperacional, intervaloColeta, statusAtividade, fkAeroporto) VALUES
('3b12f1df-5232-4df4-8d48-64a938c2', 'SDV-GRU-01', 'linux', 3, 1, 1),  -- 1 GRU (servidor de teste)
('5d2e8b7a1c4f4963b0a7e21f9c6d3a85', 'SPA-GRU-01', 'windows', 5, 1, 1),  -- 2 GRU
('9b7c3e5f2a1d48c6847f0e3b6a2d1c90', 'AIS-CGH-01', 'windows', 10, 1, 2),  -- 3 CGH
('c4e1a7b92d3f45068e9a1b7c5d3f2e64', 'SPA-VCP-01', 'linux', 5, 1, 3);  -- 4 VCP
 
-- ------------------------------------------------------------
-- SERVIDORCOMPONENTE -> (fkServidor, fkComponente, limiteAtencao, limiteCritico)
-- Limite NULL = métrica sem limite (lista por core, contadores acumulados...)
-- ------------------------------------------------------------
INSERT INTO servidorcomponente (fkServidor, fkComponente, limiteAtencao, limiteCritico) VALUES
-- Servidor 1 (SDV-GRU-01): todos os 11 componentes
(1, 1,  70.00,  90.00),   -- Uso de CPU (Geral)
(1, 2,  75.00,  90.00),   -- Uso de RAM
(1, 3,  80.00,   90.00),    -- Swap In
(1, 4,  80.00,   90.00),    -- Swap Out
(1, 5,  80.00,  95.00),   -- Uso de Disco
(1, 6,  80.00,   90.00),    -- Leitura de Disco
(1, 7,  80.00,   90.00),    -- Escrita de Disco
(1, 8,  80.00,   90.00),    -- Rede - Bytes Enviados
(1, 9, 80.00,   90.00),    -- Rede - Bytes Recebidos
(1, 10, 300.00, 500.00),  -- Processos Ativos
 
-- Servidor 2 (SPA-GRU-01): RAM, disco e rede recebida
(2, 2,  80.00,  90.00),   -- Uso de RAM
(2, 5,  80.00,  95.00),   -- Uso de Disco
(2, 6,  80.00,   90.00),    -- Leitura de Disco
(2, 7,  80.00,   90.00),    -- Escrita de Disco
(2, 9, 80.00,   90.00),    -- Rede - Bytes Recebidos
 
-- Servidor 3 (AIS-CGH-01): RAM, disco e rede
(3, 2,  80.00,  92.00),   -- Uso de RAM
(3, 5,  80.00,  95.00),   -- Uso de Disco
(3, 6,  80.00,   90.00),    -- Leitura de Disco
(3, 7,  80.00,   90.00),    -- Escrita de Disco
(3, 8,  80.00,   90.00),    -- Rede - Bytes Enviados
(3, 9, 80.00,   90.00),    -- Rede - Bytes Recebidos
 
-- Servidor 4 (SPA-VCP-01): RAM e disco
(4, 2,  80.00,  92.00),   -- Uso de RAM
(4, 5,  85.00,  95.00),   -- Uso de Disco
(4, 6,  80.00,   90.00),    -- Leitura de Disco
(4, 7,  80.00,   90.00);    -- Escrita de Disco
 
-- ------------------------------------------------------------
-- VISUALIZACAO -> (fkUsuario, fkServidor, dataInicioAcesso, dataFimAcesso)
-- dataFimAcesso NULL = acesso ainda ativo
-- Cada usuário só visualiza servidores da própria empresa.
-- ------------------------------------------------------------
INSERT INTO visualizacao (fkUsuario, fkServidor, dataInicioAcesso, dataFimAcesso) VALUES
(1, 1, '2026-09-01 08:00:00', NULL),                    -- Carlos  -> SDV-GRU-01
(1, 2, '2026-09-01 08:00:00', NULL),                    -- Carlos  -> SPA-GRU-01
(1, 3, '2026-09-01 08:00:00', NULL),                    -- Carlos  -> AIS-CGH-01
(2, 1, '2026-09-02 09:30:00', NULL),                    -- Mariana -> SDV-GRU-01
(2, 2, '2026-09-02 09:30:00', NULL),                    -- Mariana -> SPA-GRU-01
(3, 3, '2026-09-03 07:45:00', '2026-09-25 18:00:00'),   -- Rafael  -> AIS-CGH-01 (acesso encerrado)
(4, 4, '2026-09-05 10:15:00', NULL),                    -- Fernanda -> SPA-VCP-01
(5, 4, '2026-09-08 13:00:00', '2026-09-20 17:30:00');   -- João    -> SPA-VCP-01 (acesso encerrado)
SQL_EOF

    cat > "$DB_DIR/Dockerfile" <<'DOCKERFILE_EOF'
FROM mysql:8.0

# Banco criado automaticamente na primeira inicialização
ENV MYSQL_DATABASE=montech
ENV TZ=America/Sao_Paulo

# Scripts .sql nesta pasta rodam em ordem alfabética na primeira inicialização
COPY ./montech.sql /docker-entrypoint-initdb.d/01-montech.sql

EXPOSE 3306

CMD ["--character-set-server=utf8mb4", "--collation-server=utf8mb4_unicode_ci", "--default-time-zone=-03:00"]
DOCKERFILE_EOF
}

# Build da imagem e subida do container
# (usa sudo porque o grupo docker só vale a partir de um novo login)
subir_banco_docker() {
    set -e
    cd "$DB_DIR"
    sudo docker build -t "$DB_IMAGE" .
    sudo docker rm -f "$DB_CONTAINER" > /dev/null 2>&1 || true
    sudo docker run -d --name "$DB_CONTAINER" \
      -e MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD" \
      -e MYSQL_USER="$MYSQL_USER" \
      -e MYSQL_PASSWORD="$MYSQL_PASSWORD" \
      -p 3306:3306 \
      -v montech_data:/var/lib/mysql \
      "$DB_IMAGE"
}

# Aguarda o MySQL aceitar conexões (a 1ª inicialização executa o montech.sql)
aguardar_banco() {
    for _ in $(seq 1 90); do
        if sudo docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$DB_CONTAINER" \
            mysqladmin ping -h 127.0.0.1 -uroot --silent > /dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    echo "O MySQL não ficou pronto a tempo. Últimos logs do container:"
    sudo docker logs --tail 30 "$DB_CONTAINER"
    return 1
}

executar_com_spinner "Preparando montech.sql e Dockerfile em $DB_DIR..." "preparar_arquivos_banco"
executar_com_spinner "Construindo a imagem $DB_IMAGE e subindo o container $DB_CONTAINER..." "subir_banco_docker"
executar_com_spinner "Aguardando o MySQL inicializar (executando o montech.sql)..." "aguardar_banco"
echo -e "${VERDE}Banco MonTech no ar:${RESET} container $DB_CONTAINER na porta 3306"

echo -e "${VERDE}INSTALAÇÃO DO AMBIENTE CONCLUÍDA${RESET}\n"

echo "================================================="
echo "      CONFIGURAÇÃO BUCKETS AWS - MONTECH         "
echo "================================================="
echo ""

# 1. Autenticação via IAM Instance Profile (LabInstanceProfile)
#    Nenhuma credencial é digitada: o AWS CLI obtém chaves temporárias
#    automaticamente pelo serviço de metadados da instância (IMDS).
echo -e "${AZUL}Autenticação:${RESET} usando o IAM Instance Profile da EC2 (LabInstanceProfile)"

# Credenciais explícitas têm prioridade sobre o Instance Profile e, se estiverem
# velhas/expiradas, quebram tudo. Por isso garantimos que não há nenhuma em uso.
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE

if [ -f "$HOME/.aws/credentials" ]; then
    BACKUP_CRED="$HOME/.aws/credentials.bak.$(date +%Y%m%d%H%M%S)"
    mv "$HOME/.aws/credentials" "$BACKUP_CRED"
    echo -e "${AMARELO}Aviso:${RESET} arquivo ~/.aws/credentials antigo movido para $BACKUP_CRED"
fi

# 2. Região e formato de saída (não são segredos, então podem ser configurados)
read -p "Default region name [us-east-1]: " AWS_REGION
AWS_REGION=${AWS_REGION:-us-east-1}
export AWS_DEFAULT_REGION="$AWS_REGION"

executar_com_spinner "Configurando região e formato de saída do AWS CLI..." \
    "aws configure set region '$AWS_REGION' && aws configure set output json"

# 3. Teste de conexão (valida se o Instance Profile está anexado à EC2)
executar_com_spinner "Validando Instance Profile na AWS..." "aws sts get-caller-identity"
if [ $? -ne 0 ]; then
    echo -e "${VERMELHO}ERRO: não foi possível obter credenciais do Instance Profile.${RESET}"
    echo -e "${AMARELO}Verifique no console EC2: Actions > Security > Modify IAM role > LabInstanceProfile.${RESET}"
    exit 1
fi
echo -e "${VERDE}Conexão com a AWS estabelecida com sucesso!${RESET}"
echo -e "${AZUL}Identidade:${RESET} $(aws sts get-caller-identity --query Arn --output text)"

# 4. Variáveis de Ambiente e Particionamento
# Sufixo aleatório obrigatório porque nomes de buckets S3 devem ser globais e únicos
RANDOM_SUFFIX=$((RANDOM % 9999 + 1000))
BUCKET_NAME="montech-datalake-${RANDOM_SUFFIX}"

# Caminhos das camadas
BRONZE_PATH="s3://${BUCKET_NAME}/01-bronze/"
SILVER_PATH="s3://${BUCKET_NAME}/02-silver/"
GOLD_PATH="s3://${BUCKET_NAME}/03-gold/"

LOCAL_BASE_DIR="/home/ubuntu/datalake_data"
LOCAL_CSV_DIR="${LOCAL_BASE_DIR}"

# 5. Criando Bucket e Pastas (Prefixos) na AWS
executar_com_spinner "Criando o Bucket S3 ($BUCKET_NAME)..." "aws s3 mb 's3://${BUCKET_NAME}'"
if [ $? -ne 0 ]; then
    echo -e "${VERMELHO}ERRO: falha ao criar o bucket. Confira se o perfil da instância tem permissão de S3.${RESET}"
    exit 1
fi

executar_com_spinner "Criando as camadas Bronze, Silver e Gold no S3..." \
    "aws s3api put-object --bucket '$BUCKET_NAME' --key '01-bronze/' && aws s3api put-object --bucket '$BUCKET_NAME' --key '02-silver/' && aws s3api put-object --bucket '$BUCKET_NAME' --key '03-gold/'"

# 6. Criando diretórios locais e permissões na EC2
executar_com_spinner "Configurando diretórios locais na EC2..." \
    "sudo mkdir -p '$LOCAL_CSV_DIR' && (sudo chown -R ubuntu:ubuntu '$LOCAL_BASE_DIR' 2>/dev/null || sudo chown -R \$(whoami):\$(whoami) '$LOCAL_BASE_DIR') && sudo chmod -R 755 '$LOCAL_BASE_DIR'"

# 7. Resumo Final
echo ""
echo "================ CONFIGURAÇÃO CONCLUÍDA ================"
echo "Bucket criado    : $BUCKET_NAME"
echo "Camada Bronze S3 : $BRONZE_PATH (Espera CSV)"
echo "Camada Silver S3 : $SILVER_PATH (Espera CSV)"
echo "Camada Gold S3   : $GOLD_PATH (Espera JSON)"
echo "Pasta local EC2  : $LOCAL_CSV_DIR"
echo "Banco MySQL      : container $DB_CONTAINER (porta 3306, volume montech_data)"
echo "Usuário MySQL     : $MYSQL_USER (acesso ao banco montech) e root"
echo "========================================================"
echo "Para verificar tudo na AWS, rode: aws s3 ls s3://${BUCKET_NAME} --recursive"