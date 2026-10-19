#!/bin/bash
echo "================================================="
echo "      CONFIGURANDO AMBIENTE - MONTECH         "
echo "================================================="
echo ""

echo "Configurando fuso horário de São Paulo..."
sudo timedatectl set-timezone America/Sao_Paulo
echo "Horário atual: $(date)"
echo ""

echo "Instalando dependências do sistema (Python, Pip, Venv, Unzip e Curl)..."
sudo apt update && sudo apt install -y python3 python3-pip python3-venv unzip curl
ls
echo "Criando o ambiente virtual Python (venv)..."
python3 -m venv venv

echo "Instalando AWS CLI v2..."
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -qo awscliv2.zip
sudo ./aws/install --update
rm -rf aws awscliv2.zip

aws --version
echo "INSTALAÇÃO DO AMBIENTE CONCLUÍDA"



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
echo -e "\nConfigurando o AWS CLI..."
aws configure set aws_access_key_id "$AWS_ACCESS_KEY"
aws configure set aws_secret_access_key "$AWS_SECRET_KEY"
aws configure set aws_session_token "$AWS_SESSION_TOKEN"
aws configure set region "$AWS_REGION"
aws configure set output "$AWS_OUTPUT"

# 3. Teste de conexão
echo "Validando credenciais na AWS..."
aws sts get-caller-identity > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "ERRO: Credenciais inválidas ou token expirado. Rode o script novamente com as credenciais corretas."
    exit 1
fi
echo "Conexão com a AWS estabelecida com sucesso!"

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
echo -e "\nCriando o Bucket S3: $BUCKET_NAME..."
aws s3 mb "s3://${BUCKET_NAME}"

echo "Criando as camadas Bronze, Silver e Gold no S3..."
aws s3api put-object --bucket "$BUCKET_NAME" --key "01-bronze/" > /dev/null
aws s3api put-object --bucket "$BUCKET_NAME" --key "02-silver/" > /dev/null
aws s3api put-object --bucket "$BUCKET_NAME" --key "03-gold/" > /dev/null

# 6. Criando diretórios locais e permissões na EC2
echo -e "\nConfigurando diretórios locais na EC2..."
sudo mkdir -p "$LOCAL_CSV_DIR"
sudo chown -R ubuntu:ubuntu "$LOCAL_BASE_DIR"
sudo chmod -R 755 "$LOCAL_BASE_DIR"

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