#!/usr/bin/env bash
#
# Script de automação e configuração do ambiente e Data Lake (AWS S3) - MonTech
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
echo -e "${VERDE}INSTALAÇÃO DO AMBIENTE CONCLUÍDA${RESET}\n"

echo "================================================="
echo "      CONFIGURAÇÃO BUCKETS AWS - MONTECH         "
echo "================================================="
echo ""

# 1. Coleta de credenciais de forma interativa
read -p "AWS Access Key ID: " AWS_ACCESS_KEY
read -p "AWS Secret Access Key: " AWS_SECRET_KEY
read -p "AWS Session Token: " AWS_SESSION_TOKEN
read -p "Default region name [us-east-1]: " AWS_REGION
AWS_REGION=${AWS_REGION:-us-east-1}
read -p "Default output format [json]: " AWS_OUTPUT
AWS_OUTPUT=${AWS_OUTPUT:-json}

echo ""
echo "--- Configuração da Estrutura do Data Lake ---"

# 2. Configuração do AWS CLI
executar_com_spinner "Configurando o AWS CLI..." \
    "aws configure set aws_access_key_id '$AWS_ACCESS_KEY' && aws configure set aws_secret_access_key '$AWS_SECRET_KEY' && aws configure set aws_session_token '$AWS_SESSION_TOKEN' && aws configure set region '$AWS_REGION' && aws configure set output '$AWS_OUTPUT'"

# 3. Teste de conexão
executar_com_spinner "Validando credenciais na AWS..." "aws sts get-caller-identity"
if [ $? -ne 0 ]; then
    echo -e "${VERMELHO}ERRO: Credenciais inválidas ou token expirado. Rode o script novamente com as credenciais corretas.${RESET}"
    exit 1
fi
echo -e "${VERDE}Conexão com a AWS estabelecida com sucesso!${RESET}"

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