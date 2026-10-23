#!/usr/bin/env bash
# ============================================================
#  MonTech - Instalador do coletor de métricas
#  Rode no SERVIDOR do cliente (Linux) que vai executar a captura.
#
#  O que faz:
#    1. Instala o que faltar (Python 3.9+, venv, pip, tmux)
#    2. Cria a pasta do coletor com ambiente virtual e dependências
#    3. Coloca Script_Extracao.py e Organizador.py (embutidos neste arquivo)
#    4. Configura bucket/região, acesso ao MySQL (.env) e credenciais AWS
#    5. Valida banco e AWS e gera o iniciar_coleta.sh
#
#  Uso:
#    bash instalar-coletor.sh               instalação completa
#    bash instalar-coletor.sh --credenciais só renova as credenciais AWS
#
#  Para automatizar (sem perguntas), defina antes: MONTECH_DB_HOST,
#  MONTECH_DB_USER, MONTECH_DB_PASSWORD, MONTECH_DB_NAME, MONTECH_DB_PORT, MONTECH_BUCKET,
#  MONTECH_REGIAO, MONTECH_AWS_KEY, MONTECH_AWS_SECRET, MONTECH_AWS_TOKEN
#  e, se quiser outra pasta, MONTECH_DIR.
# ============================================================
# Se foi chamado com "sh instalar-coletor.sh", reexecuta com bash.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -uo pipefail

# ---------- CONFIGURAÇÃO DA EQUIPE (edite antes de enviar ao cliente) ----------
DEFAULT_DB_HOST=""            # IP/DNS do MySQL. Vazio = o cliente digita.
DEFAULT_DB_PORT="3306"        # Porta publicada na VM (ex.: 3307).
DEFAULT_DB_USER="montech"
DEFAULT_DB_NAME="montech"
# --------------------------------------------------------------------------------

SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
INSTALL_DIR="${MONTECH_DIR:-$HOME/montech-coletor}"
PY="$INSTALL_DIR/.venv/bin/python"
AWS_DIR="$INSTALL_DIR/.aws"
PYFILE="$INSTALL_DIR/Script_Extracao.py"
LOG="$INSTALL_DIR/instalacao.log"

# ---------- Mensagens ----------
if [[ -t 1 ]]; then
  C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'; C_B=$'\e[1m'; C_OFF=$'\e[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_B=""; C_OFF=""
fi
titulo() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_OFF"; }
info()   { printf '   %s\n' "$*"; }
ok()     { printf '%s[OK]%s %s\n' "$C_OK" "$C_OFF" "$*"; }
aviso()  { printf '%s[AVISO]%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
erro()   { printf '%s[ERRO]%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; }
die()    { erro "$*"; exit 1; }

uso() {
  cat <<'USO'
Uso: bash instalar-coletor.sh [opção]
  (sem opção)      instalação completa
  --credenciais    renova somente as credenciais AWS
  -h, --ajuda      mostra esta ajuda
USO
}

# ---------- Perguntas ----------
# Lê as respostas do terminal, mesmo se o script vier por pipe.
if [[ -t 0 ]]; then
  TTY_IN=/dev/stdin
elif [[ -r /dev/tty ]] && { : </dev/tty; } 2>/dev/null; then
  TTY_IN=/dev/tty
else
  TTY_IN=""
fi

# ask VAR "Pergunta" [padrão] [secreto] [opcional]
# Se MONTECH_<VAR> estiver definida, usa o valor sem perguntar.
ask() {
  local _var=$1 _label=$2 _def=${3:-} _secret=${4:-} _opt=${5:-}
  local _preset="MONTECH_$_var" _val="" _prompt="$_label"
  if [[ -n "${!_preset:-}" ]]; then
    printf -v "$_var" '%s' "${!_preset}"
    return 0
  fi
  if [[ -z "$TTY_IN" ]]; then
    if [[ -n "$_opt" ]]; then printf -v "$_var" '%s' ""; return 0; fi
    die "Sem terminal para perguntar \"$_label\". Defina a variável $_preset."
  fi
  [[ -n "$_def" && -z "$_secret" ]] && _prompt+=" [$_def]"
  while :; do
    if [[ -n "$_secret" ]]; then
      read -rsp "$_prompt: " _val <"$TTY_IN"; echo >&2
    else
      read -rp "$_prompt: " _val <"$TTY_IN"
    fi
    _val=${_val:-$_def}
    [[ -n "$_val" || -n "$_opt" ]] && break
    aviso "Valor obrigatório."
  done
  printf -v "$_var" '%s' "$_val"
}

# Remove qualquer espaço/quebra de linha (colagens costumam trazer lixo).
sem_espacos() { printf '%s' "$1" | tr -d '[:space:]'; }

# Validadores
v_regiao() { [[ $1 =~ ^[a-z]{2}(-[a-z]+)+-[0-9]+$ ]]; }
v_bucket() { [[ $1 =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; }
v_host()   { [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; }
v_port()   { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
v_ident()  { [[ $1 =~ ^[A-Za-z0-9_.-]+$ ]]; }
v_chave()  { [[ $1 =~ ^[A-Za-z0-9]{16,128}$ ]]; }
v_secret() { [[ $1 =~ ^[A-Za-z0-9/+=]{30,128}$ ]]; }

# perguntar_valido VAR "Pergunta" "padrão" validador "mensagem de erro" [secreto]
perguntar_valido() {
  local _var=$1 _label=$2 _def=$3 _fn=$4 _msg=$5 _secret=${6:-} _preset="MONTECH_$1"
  while :; do
    ask "$_var" "$_label" "$_def" "$_secret"
    printf -v "$_var" '%s' "$(sem_espacos "${!_var}")"
    "$_fn" "${!_var}" && return 0
    [[ -n "${!_preset:-}" ]] && die "$_msg (variável $_preset)"
    aviso "$_msg"
  done
}

# ---------- Sistema ----------
como_root() {
  if (( EUID == 0 )); then "$@"
  elif command -v sudo >/dev/null 2>&1; then sudo "$@"
  else return 1
  fi
}

# pkg_instalar py|tmux
pkg_instalar() {
  local apt_pk dnf_pk
  case $1 in
    py)   apt_pk="python3 python3-venv python3-pip"; dnf_pk="python3 python3-pip" ;;
    tmux) apt_pk="tmux"; dnf_pk="tmux" ;;
  esac
  if command -v apt-get >/dev/null 2>&1; then
    como_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq >>"$LOG" 2>&1
    # shellcheck disable=SC2086
    como_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $apt_pk >>"$LOG" 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    como_root dnf install -y -q $dnf_pk >>"$LOG" 2>&1
  elif command -v yum >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    como_root yum install -y -q $dnf_pk >>"$LOG" 2>&1
  else
    return 1
  fi
}

python_ok() {
  command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'
}

criar_venv() {
  [[ -x "$PY" ]] && return 0
  python_ok && python3 -m venv "$INSTALL_DIR/.venv" >>"$LOG" 2>&1 && return 0
  rm -rf "$INSTALL_DIR/.venv"
  return 1
}

garantir_venv() {
  criar_venv && return 0
  info "Instalando Python no sistema (pode pedir sua senha de sudo)..."
  pkg_instalar py || true
  criar_venv || die "Não foi possível criar o ambiente Python (é preciso Python 3.9+ com venv e acesso à internet). Veja $LOG"
}

instalar_dependencias() {
  info "Instalando dependências Python (pode levar alguns minutos)..."
  if ! "$PY" -m pip install --quiet --disable-pip-version-check \
      pandas psutil boto3 mysql-connector-python python-dotenv >>"$LOG" 2>&1; then
    tail -n 12 "$LOG" >&2
    die "Falha ao instalar as dependências. Verifique a internet do servidor. Log: $LOG"
  fi
  "$PY" -c 'import pandas, psutil, boto3, mysql.connector, dotenv' >>"$LOG" 2>&1 ||
    die "As dependências foram instaladas, mas não importam. Veja $LOG"
  ok "Dependências instaladas."
}

garantir_tmux() {
  command -v tmux >/dev/null 2>&1 && return 0
  info "Instalando o tmux (mantém a coleta rodando se o SSH cair)..."
  pkg_instalar tmux || true
  command -v tmux >/dev/null 2>&1 ||
    aviso "Não consegui instalar o tmux. Instale tmux ou screen para manter a coleta ativa após fechar o SSH."
  return 0
}

# ---------- Código do coletor ----------
valor_py() { sed -n -E "s/^$1 = \"([^\"]*)\".*/\1/p" "$PYFILE" 2>/dev/null | head -n 1; }

obter_codigo() {
  local origem; origem="$(cd "$(dirname "$SELF")" && pwd)"
  if [[ -f "$origem/Script_Extracao.py" && -f "$origem/Organizador.py" ]]; then
    if [[ "$origem" -ef "$INSTALL_DIR" ]]; then
      info "Mantendo os arquivos .py já presentes em $INSTALL_DIR."
    else
      cp "$origem/Script_Extracao.py" "$origem/Organizador.py" "$INSTALL_DIR/"
      ok "Usando Script_Extracao.py e Organizador.py que estão ao lado do instalador."
    fi
  elif grep -q '^__MONTECH_PAYLOAD__$' "$SELF" 2>/dev/null; then
    awk 'f{print} /^__MONTECH_PAYLOAD__$/{f=1}' "$SELF" | base64 -d | tar -xz -C "$INSTALL_DIR" ||
      die "Falha ao extrair o código embutido. O arquivo do instalador pode ter sido corrompido na cópia."
    ok "Código do coletor extraído."
  else
    die "Não encontrei Script_Extracao.py e Organizador.py (nem embutidos, nem ao lado do instalador)."
  fi
  sed -i 's/\r$//' "$INSTALL_DIR/Script_Extracao.py" "$INSTALL_DIR/Organizador.py"
}

aplicar_config_py() {
  sed -i -E "s|^NOME_BUCKET = \".*\"|NOME_BUCKET = \"$BUCKET\"|; s|^REGIAO_AWS = \".*\"|REGIAO_AWS = \"$REGIAO\"|" "$PYFILE"
  [[ "$(valor_py NOME_BUCKET)" == "$BUCKET" && "$(valor_py REGIAO_AWS)" == "$REGIAO" ]] ||
    die "Não consegui gravar bucket/região no Script_Extracao.py (as linhas NOME_BUCKET e REGIAO_AWS mudaram?)."
  ok "Bucket $BUCKET na região $REGIAO."
}

# ---------- Arquivos de configuração ----------
escapar_env() { local s=$1; s=${s//\\/\\\\}; s=${s//\'/\\\'}; printf '%s' "$s"; }

escrever_env() {
  (
    umask 077
    {
      printf 'DB_HOST=%s\n' "$DB_HOST"
      printf 'DB_PORT=%s\n' "$DB_PORT"
      printf 'DB_USER=%s\n' "$DB_USER"
      printf "DB_PASSWORD='%s'\n" "$(escapar_env "$DB_PASSWORD")"
      printf 'DB_NAME=%s\n' "$DB_NAME"
    } >"$INSTALL_DIR/.env"
  )
  chmod 600 "$INSTALL_DIR/.env"
  ok "Arquivo .env criado (permissão 600)."
}

escrever_aws() {
  mkdir -p "$AWS_DIR"; chmod 700 "$AWS_DIR"
  (
    umask 077
    {
      echo "[default]"
      printf 'aws_access_key_id = %s\n' "$AWS_KEY"
      printf 'aws_secret_access_key = %s\n' "$AWS_SECRET"
      if [[ -n "$AWS_TOKEN" ]]; then printf 'aws_session_token = %s\n' "$AWS_TOKEN"; fi
    } >"$AWS_DIR/credentials"
    printf '[default]\nregion = %s\noutput = json\n' "$REGIAO" >"$AWS_DIR/config"
  )
  chmod 600 "$AWS_DIR/credentials" "$AWS_DIR/config"
  ok "Credenciais AWS gravadas em $AWS_DIR (isoladas, não mexem no ~/.aws do servidor)."
}

# Executa um comando só com as credenciais deste coletor (ignora variáveis AWS_* do ambiente).
env_aws() {
  env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
      -u AWS_PROFILE -u AWS_DEFAULT_PROFILE -u AWS_DEFAULT_REGION \
      AWS_SHARED_CREDENTIALS_FILE="$AWS_DIR/credentials" AWS_CONFIG_FILE="$AWS_DIR/config" "$@"
}

escrever_launcher() {
  cat >"$INSTALL_DIR/iniciar_coleta.sh" <<'LAUNCHER'
#!/usr/bin/env bash
# Inicia o coletor MonTech (pede e-mail, senha e token do servidor monitorado).
# Ctrl+C encerra e envia os CSVs pendentes ao S3.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR" || exit 1
exec env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
  -u AWS_PROFILE -u AWS_DEFAULT_PROFILE -u AWS_DEFAULT_REGION \
  AWS_SHARED_CREDENTIALS_FILE="$DIR/.aws/credentials" AWS_CONFIG_FILE="$DIR/.aws/config" \
  "$DIR/.venv/bin/python" Script_Extracao.py "$@"
LAUNCHER
  chmod +x "$INSTALL_DIR/iniciar_coleta.sh"
  ok "Criado iniciar_coleta.sh."
}

copiar_instalador() {
  local destino="$INSTALL_DIR/instalar-coletor.sh"
  if [[ -f "$SELF" && ! "$SELF" -ef "$destino" ]]; then
    cp "$SELF" "$destino" && chmod +x "$destino"
  fi
}

# ---------- Validações ----------
dica_aws() {
  case "$1" in
    *ExpiredToken*|*expired*)
      info "Dica: as credenciais expiraram. Gere novas e rode: $INSTALL_DIR/instalar-coletor.sh --credenciais" ;;
    *InvalidToken*|*InvalidClientTokenId*|*malformed*)
      info "Dica: chave ou token inválido/incompleto. Os 3 valores (Access Key, Secret e Session Token) precisam ser da MESMA sessão e colados inteiros." ;;
    *SignatureDoesNotMatch*)
      info "Dica: a Secret Access Key não confere com a Access Key (colada incompleta ou de outra sessão)." ;;
    *"Could not connect"*|*EndpointConnectionError*|*"Connect timeout"*)
      info "Dica: sem acesso ao endpoint da AWS. Confira a região (use us-east-1, nunca us-east-1d) e a internet/firewall do servidor." ;;
    *"Unable to locate credentials"*)
      info "Dica: o arquivo de credenciais está vazio ou ilegível." ;;
  esac
}

validar_aws() {
  local saida id_linha b_linha
  saida=$(MONTECH_REGIAO="$REGIAO" MONTECH_BUCKET="$BUCKET" env_aws "$PY" - 2>&1 <<'PY'
import os
import boto3
reg, bucket = os.environ["MONTECH_REGIAO"], os.environ["MONTECH_BUCKET"]
try:
    ident = boto3.client("sts", region_name=reg).get_caller_identity()
    print("OK|" + ident["Arn"])
except Exception as e:
    print("ERRO|" + type(e).__name__ + ": " + str(e).replace("\n", " "))
    raise SystemExit(0)
try:
    boto3.client("s3", region_name=reg).head_bucket(Bucket=bucket)
    print("BUCKET_OK")
except Exception as e:
    print("BUCKET_ERRO|" + str(e).replace("\n", " "))
PY
)
  id_linha=$(grep -m1 -E '^(OK|ERRO)\|' <<<"$saida" || true)
  b_linha=$(grep -m1 -E '^BUCKET_(OK|ERRO)' <<<"$saida" || true)
  if [[ "$id_linha" == OK\|* ]]; then
    ok "Credenciais AWS válidas (${id_linha#OK|})."
    if [[ "$b_linha" == BUCKET_OK ]]; then
      ok "Acesso ao bucket $BUCKET confirmado."
    else
      aviso "Não consegui acessar o bucket $BUCKET: ${b_linha#BUCKET_ERRO|}"
      info "Confira o nome do bucket e a região. Sem isso o envio dos CSVs falha (eles ficam salvos localmente)."
      return 1
    fi
    return 0
  fi
  aviso "As credenciais AWS não passaram na validação: ${id_linha#ERRO|}"
  [[ -n "$id_linha" ]] || printf '%s\n' "$saida" | tail -n 5
  dica_aws "$id_linha"
  AWS_FALHOU=1
  return 1
}

validar_banco() {
  local saida linha
  saida=$(cd "$INSTALL_DIR" && "$PY" - 2>&1 <<'PY'
import os
from dotenv import load_dotenv
load_dotenv(os.path.join(os.getcwd(), ".env"))
import mysql.connector
try:
    c = mysql.connector.connect(
        host=os.getenv("DB_HOST"), port=int(os.getenv("DB_PORT", "3306")),
        user=os.getenv("DB_USER"), password=os.getenv("DB_PASSWORD"),
        database=os.getenv("DB_NAME"),
        connection_timeout=8,
    )
    cur = c.cursor()
    cur.execute("SHOW TABLES LIKE 'servidor'")
    tem = cur.fetchone() is not None
    c.close()
    print("OK|tabelas" if tem else "OK|sem_tabelas")
except mysql.connector.Error as e:
    print("ERRO|%s|%s" % (e.errno, str(e).replace("\n", " ")))
PY
)
  linha=$(grep -m1 -E '^(OK|ERRO)\|' <<<"$saida" || true)
  case "$linha" in
    OK\|tabelas)
      ok "Banco acessível ($DB_USER@$DB_HOST/$DB_NAME)."; return 0 ;;
    OK\|sem_tabelas)
      aviso "Conectei no banco, mas a tabela 'servidor' não existe. O nome do banco ($DB_NAME) está certo e o script SQL foi importado?"
      return 1 ;;
    ERRO\|*)
      local errno=${linha#ERRO|}; errno=${errno%%|*}
      aviso "Não consegui conectar no MySQL: ${linha#ERRO|*|}"
      case "$errno" in
        1045) info "Dica: usuário ou senha incorretos." ;;
        1049) info "Dica: o banco '$DB_NAME' não existe." ;;
        1044) info "Dica: o usuário não tem permissão no banco '$DB_NAME'." ;;
        *)    info "Dica: confira o endereço, a porta DB_PORT, o firewall/Security Group e se o MySQL está acessível a partir deste servidor."
              info "Se o MySQL só aceita conexões locais, é preciso túnel SSH ou liberar o acesso de forma restrita." ;;
      esac
      return 1 ;;
    *)
      aviso "Não consegui testar o banco:"; printf '%s\n' "$saida" | tail -n 5
      return 1 ;;
  esac
}

# ---------- Fluxos ----------
perguntar_aws() {
  ask AWS_KEY "AWS Access Key ID" "" ""
  AWS_KEY=$(sem_espacos "$AWS_KEY")
  v_chave "$AWS_KEY" || aviso "A Access Key tem um formato estranho (esperado: 16 a 128 letras/números)."
  ask AWS_SECRET "AWS Secret Access Key (não aparece na tela)" "" secret
  AWS_SECRET=$(sem_espacos "$AWS_SECRET")
  v_secret "$AWS_SECRET" || aviso "A Secret Access Key tem um formato estranho (esperado: 30+ caracteres base64)."
  ask AWS_TOKEN "AWS Session Token (Enter se não usar; não aparece na tela)" "" secret optional
  AWS_TOKEN=$(sem_espacos "$AWS_TOKEN")
  if [[ -n "$AWS_TOKEN" && ${#AWS_TOKEN} -lt 100 ]]; then
    aviso "O Session Token parece curto (${#AWS_TOKEN} caracteres). Tokens costumam ter centenas; confira se foi colado inteiro."
  fi
}

modo_credenciais() {
  [[ -x "$PY" && -f "$PYFILE" ]] || die "Instalação não encontrada em $INSTALL_DIR. Rode a instalação completa primeiro."
  titulo "Renovar credenciais AWS"
  BUCKET=$(valor_py NOME_BUCKET); REGIAO=$(valor_py REGIAO_AWS)
  AWS_FALHOU=0
  perguntar_aws
  escrever_aws
  validar_aws || true
  if (( AWS_FALHOU )); then
    aviso "Credenciais gravadas, mas inválidas. Rode --credenciais de novo com valores corretos."
    exit 1
  fi
}

modo_instalar() {
  [[ "$(uname -s)" == Linux ]] || die "Este instalador é para servidores Linux."
  mkdir -p "$INSTALL_DIR" || die "Não consegui criar $INSTALL_DIR."
  : >>"$LOG" || die "Sem permissão de escrita em $INSTALL_DIR."

  printf '%s\n' "$C_B=========================================================$C_OFF"
  printf '%s\n' "$C_B  MonTech - Instalação do coletor de métricas$C_OFF"
  printf '%s\n' "$C_B=========================================================$C_OFF"
  info "Pasta de instalação: $INSTALL_DIR"

  titulo "1/5 Código do coletor"
  local prev_bucket="" prev_regiao="" def_bucket def_regiao
  if [[ -f "$PYFILE" ]]; then prev_bucket=$(valor_py NOME_BUCKET); prev_regiao=$(valor_py REGIAO_AWS); fi
  obter_codigo
  def_bucket=${prev_bucket:-$(valor_py NOME_BUCKET)}
  def_regiao=${prev_regiao:-$(valor_py REGIAO_AWS)}
  def_regiao=${def_regiao:-us-east-1}

  local prev_host="" prev_port="" prev_user="" prev_name=""
  if [[ -f "$INSTALL_DIR/.env" ]]; then
    prev_host=$(sed -n -E 's/^DB_HOST=(.*)$/\1/p' "$INSTALL_DIR/.env" | head -n1)
    prev_port=$(sed -n -E 's/^DB_PORT=(.*)$/\1/p' "$INSTALL_DIR/.env" | head -n1)
    prev_user=$(sed -n -E 's/^DB_USER=(.*)$/\1/p' "$INSTALL_DIR/.env" | head -n1)
    prev_name=$(sed -n -E 's/^DB_NAME=(.*)$/\1/p' "$INSTALL_DIR/.env" | head -n1)
  fi

  titulo "2/5 Configuração"
  info "Bucket S3 e região onde os CSVs serão enviados:"
  perguntar_valido BUCKET "Nome do bucket" "$def_bucket" v_bucket "Nome de bucket inválido (minúsculas, números, ponto e hífen)."
  perguntar_valido REGIAO "Região AWS" "$def_regiao" v_regiao "Região inválida. Exemplo: us-east-1 (não use zona como us-east-1d)."
  echo
  info "Banco MySQL da MonTech (usado para login, token e lista de componentes):"
  perguntar_valido DB_HOST "Endereço do MySQL (IP ou DNS)" "${prev_host:-$DEFAULT_DB_HOST}" v_host "Endereço inválido."
   perguntar_valido DB_PORT "Porta do MySQL" "${prev_port:-$DEFAULT_DB_PORT}" v_port "Porta inválida (use um número entre 1 e 65535)."
  perguntar_valido DB_USER "Usuário do MySQL" "${prev_user:-$DEFAULT_DB_USER}" v_ident "Usuário inválido (use letras, números, _ . -)."
  while :; do
    ask DB_PASSWORD "Senha do MySQL (não aparece na tela)" "" secret
    DB_PASSWORD=${DB_PASSWORD//$'\r'/}
    [[ "$DB_PASSWORD" != *'${'* ]] && break
    [[ -n "${MONTECH_DB_PASSWORD:-}" ]] && die "A senha não pode conter a sequência \${ (variável MONTECH_DB_PASSWORD)."
    aviso "A senha não pode conter a sequência \${ : o arquivo .env a trataria como variável. Troque a senha do usuário no MySQL ou digite outra."
  done
  perguntar_valido DB_NAME "Nome do banco" "${prev_name:-$DEFAULT_DB_NAME}" v_ident "Nome de banco inválido (use letras, números, _ . -)."
  echo
  info "Credenciais AWS para enviar os CSVs ao S3:"
  perguntar_aws

  titulo "3/5 Ambiente Python"
  garantir_venv
  instalar_dependencias
  garantir_tmux

  titulo "4/5 Gravando configuração"
  aplicar_config_py
  escrever_env
  escrever_aws
  escrever_launcher
  copiar_instalador
  "$PY" -m py_compile "$INSTALL_DIR/Script_Extracao.py" "$INSTALL_DIR/Organizador.py" ||
    die "O código do coletor tem erro de sintaxe."

  titulo "5/5 Validando conexões"
  local pendencias=0
  AWS_FALHOU=0
  validar_banco || pendencias=$((pendencias + 1))
  validar_aws   || pendencias=$((pendencias + 1))

  titulo "Instalação concluída"
  info "Pasta: $INSTALL_DIR"
  echo
  info "Para iniciar a coleta (mantém rodando mesmo se o SSH cair):"
  info "  tmux new -s montech"
  info "  $INSTALL_DIR/iniciar_coleta.sh"
  info "Sair sem parar: Ctrl+B e depois D  |  Voltar: tmux attach -t montech  |  Parar: Ctrl+C"
  echo
  info "Renovar as credenciais AWS quando expirarem:"
  info "  $INSTALL_DIR/instalar-coletor.sh --credenciais"
  if (( pendencias > 0 )); then
    printf '\n'
    aviso "$pendencias validação(ões) falharam (veja acima). A instalação está pronta, mas corrija isso antes de coletar."
  fi
}

main() {
  case "${1:-}" in
    ""|--instalar)  modo_instalar ;;
    --credenciais)  modo_credenciais ;;
    -h|--ajuda|--help) uso ;;
    *) uso; exit 1 ;;
  esac
}

main "$@"
exit $?

# Tudo abaixo desta linha é o código do coletor (tar.gz em base64). Não edite.
__MONTECH_PAYLOAD__
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
ulbX6lpdq2t1ra7V9X/i+m+BXHUrAKAAAA==
