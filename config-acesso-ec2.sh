#!/usr/bin/env bash
#
# Script de provisionamento e auditoria de usuários para instâncias EC2
# Cria usuários individuais com chave SSH e configura o usuário de serviço MonTech.

set -euo pipefail

# 1. Validação de privilégios
if [[ "$EUID" -ne 0 ]]; then
   echo "[ERRO] Este script precisa ser executado como root ou com sudo."
   exit 1
fi

# 2. Definição de Usuários
COMPANY_USER="montech"
USERS=("guilherme" "thiago" "lucas" "vinicius" "nicole")

# 3. Localização da chave pública base da AWS
SOURCE_AUTH_KEYS=""
if [[ -f "/home/ubuntu/.ssh/authorized_keys" ]]; then
    SOURCE_AUTH_KEYS="/home/ubuntu/.ssh/authorized_keys"
elif [[ -f "/home/ec2-user/.ssh/authorized_keys" ]]; then
    SOURCE_AUTH_KEYS="/home/ec2-user/.ssh/authorized_keys"
elif [[ -f "/root/.ssh/authorized_keys" ]]; then
    SOURCE_AUTH_KEYS="/root/.ssh/authorized_keys"
else
    echo "[AVISO] Nenhuma chave pública padrão encontrada em /home/ubuntu, /home/ec2-user ou /root."
fi

echo "=== Iniciando Configuração de Usuários ==="

# 4. Criação do usuário corporativo da empresa (MonTech)
if id "$COMPANY_USER" &>/dev/null; then
    echo "[INFO] Usuário de serviço '${COMPANY_USER}' já existe."
else
    echo "[INFO] Criando usuário de serviço '${COMPANY_USER}'..."
    useradd -m -s /bin/bash "$COMPANY_USER"
    # Bloqueia senha (login interativo direto desativado)
    passwd -l "$COMPANY_USER" &>/dev/null
fi

# 5. Criação e provisionamento dos operadores individuais
for USER in "${USERS[@]}"; do
    if id "$USER" &>/dev/null; then
        echo "[INFO] Usuário '${USER}' já existe. Atualizando permissões..."
    else
        echo "[INFO] Criando usuário '${USER}'..."
        useradd -m -s /bin/bash "$USER"
    fi

    # Define senha aleatória descartável de 32 caracteres e bloqueia autenticação por senha
    RANDOM_PASS=$(openssl rand -base64 24)
    echo "${USER}:${RANDOM_PASS}" | chpasswd
    passwd -l "$USER" &>/dev/null

    # Garante privilégios de superusuário (sudo)
    usermod -aG sudo "$USER" 2>/dev/null || usermod -aG wheel "$USER" 2>/dev/null

    # Configuração de SSH e importação da chave PEM
    USER_HOME="/home/${USER}"
    SSH_DIR="${USER_HOME}/.ssh"
    AUTH_KEYS="${SSH_DIR}/authorized_keys"

    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"

    if [[ -n "$SOURCE_AUTH_KEYS" && -f "$SOURCE_AUTH_KEYS" ]]; then
        cp "$SOURCE_AUTH_KEYS" "$AUTH_KEYS"
        chmod 600 "$AUTH_KEYS"
    else
        touch "$AUTH_KEYS"
        chmod 600 "$AUTH_KEYS"
    fi

    chown -R "${USER}:${USER}" "$SSH_DIR"
    echo "[OK] Usuário '${USER}' configurado com sucesso."
done

# 6. Permissão de sudo sem senha para troca de contexto ou comandos (Opcional, mas padrão na AWS)
SUDOERS_FILE="/etc/sudoers.d/90-montech-team"
echo "# Regras de sudo para equipe MonTech" > "$SUDOERS_FILE"
for USER in "${USERS[@]}"; do
    echo "${USER} ALL=(ALL) NOPASSWD:ALL" >> "$SUDOERS_FILE"
done
chmod 440 "$SUDOERS_FILE"

echo "=== Processo Concluído com Sucesso ==="