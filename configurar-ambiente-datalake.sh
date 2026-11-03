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
echo "========================================================"
echo "Para verificar tudo na AWS, rode: aws s3 ls s3://${BUCKET_NAME} --recursive"