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
H4sIAFbJ2moC/+0923IbR3Z+xlf0DkslYA0OSdFyJVjDKZiEbK1FUiEpu7KiCmkCDXKswQw8F5oS
xad9SOUzvPuw5a3yk5OXvOLHci7dPT0XkNTF2WyC2bUIzEx3nz597n364GicBPNsNLzMEjmWsT9/
9dEHvzbh+vSTT+gvXJW/Dx88/OShucf3t7Y+efDJR2Lzo/+BK08zmcDwH/3/vNZE/z2u1po4CtJM
zaSYKLEThyqjT3uLn7IkGMsUXngU5pexOFOJDHvwVYgtH96M1BhelbE4ldE4Fnuvjv75CT194ItH
8rUI47MgEpNY5Gm++DEJYtGGUYJQfCxSFZ3LDr287YunCsaLRRa/VPR+qpKLYBInQonTPB1LEadi
HM/mMGKUqRSgC5WI9LjUySe+OBAHyZmMgtcSW7bVpRrnGXwWz/YG4kK97kCzdByfJkqo2TxRqdyQ
KonncZLFOCiN3qXe4AKWkuI0iaPXauMz/f7nG5/ZFp9vAJQiWvw5FuoS0BcgsBN1EYcX0H8Kz8Zy
FkTnDN5DXwxngI943hUaMJivN44nwVnsIbbHciKdOUJnZ4m8kCKHZQmhH4nz3Tn6xgI4CRKFgMPb
CfyRYi5TWjgEIcDvKoxdlLTWoOnjvacHh8eD/eNhD6CEcWTyfR5cwCRE6WWQIQLmPA5SORNToIJE
RFLsDY8AlzSQ33pPqmsFM0Qk9BZNZCrg//NoIqrXmpjFESFrV2byUSJniBp1iU1xyolEpLSmSTwD
HGQqC+AF3bP9bvuCO3LjPIZGOOSYSD01gACN3XCtiQuZBIsfL1SA9Cfk7DTAheoyOtKuGIcKsISE
pBJYeRmajk/jLN6+oeM5vo8E9H2OJASsQVQEqwCkDiSbqAtYhJSEPNwQch7CgmSwavBtJp6+ys7j
iHERAESJPIO+iDwAW0hLQFY4O+KqxV/gE1DH4NsjuwJpngFTLoXvNDgNgzhTYxILMyMWRHvn6bOu
OBzsdWE04Czf9zu+eJZKQ3wAd9ju/MaMk8bjlyq7CQ9nuNDncZpFuM7QzWzxI5BnJH1xDAhf/DQD
UVLp3vTurnRT72mo1Bywl6hw8csZyCIgrDhb/EcUgAjRfcxepd+H/jiOULKBEKn2AU/UJbI8YVQL
PKY9wE90YSgvjOVkpG+ZtuHir9DEsJsPj7ilK7R083YLm8T6QdKlr08HR8eD0ReHB/t/GPIdIA+k
k2QENJMFUcx3iV+S0fhcXqhRut1tdQjy28VZIb5iK7uAyXdkkuDCEMNE0+AsT+TiL4v/RDFcnk8X
0RILoq9JTI9JQPstBx+wYNDpFzmRAkIFb9FqMn2TKHSG+TOJNgWDzJXf2j/YG46+eLbz9fBY9IWH
U1Xj83Vk61C+VOv/+PDBpx72f6jOAt0WCF3EEemXUx51Ggd6ZL91OPzy8eBghC9Bh3m6roCb17eo
kx3EGeAiJEYn7gQWWvxINBgzw8GMAuB6jYYUleHRNsrGAaArAbUWjQMJEiNFaEiXoeSJZG2SsZUo
fkuPCKsHQJH08PlW20u3vS4sPNBvNEIm6RcTIMQ+JSUQxmMZgjAIYPBQ4FqAkEwRrF01jwMQViVh
D0ifBhEIFpHmp1qNSKMkkS4AOEMofosJETpElLlUWYzP+OZReeqkzAAQNBtmavEXiThIZPBaeEyV
nmhPZRieyvHLDgy5+Ekg9gAsUGXQL7w9zORcim3Ne5pCb6Fpow3jmja8cR4tGFkv7WicXsBCtPV4
+LUrgslIj0ef7YhdNiI6vRbzPMhCIUnrIA6jeEa4hCGZeHh+QD1GpXKrQZoGsy5ofstdvJLQFAl+
hrQD/J4TDo3W50fcBQ40Mm37sBD+XGbn/qkE1QI0486lQw0QQqeB2/55qKI2zwrMtq3ei+e9rc0X
LQ3qnlbOWgJZa8TwGsNjZBF0XZFOLOnwMmTQtXccJLv3CmTbu9pyM1/d2RR33Unx3Q7PIkte9VqF
jB/isgteJeYjWquC4jRV4noSr5umBdf6+Zwk3jQIVZlwHAHWtWjhNVCXYwXyb0h/gL1R4KokiV3Y
9mSUoRIs5C5DmKJ0Q3qNBTDRuUwKqOYJ2ATtqXcSPcInKKC0zLpyMXLdE1c42rXXsU3BgMiTCCz5
MFWMqqIzxA71YwRhut3b2Lhy5ne9cWUmaDrVHR4nudI8NmYfIvkC9URb880P54A3equYe2mRCNuo
iiVSa0Vpm0/tVtUGQMOiD8xwpkgRebtfjL46ODr2Ot3aq0hgfZxr+XW0nUH+etvbm596nYZ2OSiI
yhDPjoaHjUPINP0hTiaV10EQHX17cLjb1AQJG5m40mR/sDesvt4pfeN183aM+XKqZutpPlYT9BOs
/zZRWnGTXfMbr9yHXjyNd/tIk211EYZAS0mdhF0iwldwcEMDdUAaaJKEQDTPYTZPQTSkwCgKWBas
XiZDQAp2ZfuM4gs2gsE4hW5IrRssICDjYC5D1KhoAqNmQL0HAgVlrTZJWgWpVcgVe3sCNhtKB2P0
i7Y3DlMPhcO3QTSJfwBl65FrQPeegNy+3NiTY1RyMyBIEi0w7UglLVjW9BV64rqPYIqym2zhPlgn
UeYJBbxo+uu0GJWJ53mt9btfwMujkdD/4T8C/xvh5fyrb7feCHGyIcSbDfhy8kaciDfiDT16Q69t
4L9vBP0P3n1zsqG/CGzofB69oT/UXL8r+Bk3PxH23TfUI/WLUMC7+An+OcEB8cvJSLcjePH2iL++
ab0VJgBzBoveF8AUF7hkZMTdGBEhkypVeYrWjIlK/OYkKjp7isQox0ChQIRASdxdFwULiOiLOOnC
HzSDOEaCNg30Jzg8ojg84lOHrfeO7gyPB08HoLrFk4MvH++TdTxX6PqDLhFOcAbATZBnykC87/hV
ab4mDlJm4ZQCCzNrNCg0eUDQa05OZEa428mS8OMdYxwdAXsGaQqmlpwzuPwcmYtxCaZInOvYCfYy
VmhUivbX6tVpLJPJY5QWST7POn5d//Pc+0bG7AZnQUbKFe/3hNfxgWWDebuQSISlWgvJ92sttLis
wVK2QGAhSC7MkxgMZybDaZxQKAjFzfe5jEhC2bUbg0RSIUWQNEIqFgDo7CdMavwmOD9mIO7KjOU7
0ramddfEI3C40KituMIsuKWOzolUBkDhIKokMJTEJQnAURXyFJesLMynRqX4QTrSCkRNjC3QoPLB
F4pT5azATSqoonpA5zqIPiJhO7wMsvZmB5YwlYufAVovQlSH4JGMF79ggE5sdnAyMwGaJJVnCkmW
FFthKoGPp8r9GRP58WyuKL4HgiIVF/J1AH/acQ5+0S+AmLnEiAxPBnARxZmmwTihL0xG1cUcuizK
Uch5PFEmVKdHgUHQVUDEz8HyT+1w7hprZ0JbeOM8SeNkkKMeha7GpPb2UclS+INdN3Lz6aY2jaeo
+cJXgEBYYFz2wsVutLGPVImCZJB3WXODIraqu73N94B0MLz2gAiLAlwXMoyLCWis3YWKzDs0ChmJ
MoMVm2dpf7uLUWX5qv9Ar5yOfeXTqQJPtI8CDKXJa5guGB55SKFlMhQICRKIY7b4BebcFeoiyIir
kEYQai+PEiUnuqFX4L4J25bM6WG7BEHHAQ3E6D3tXQMEiz/NFEhRsJlgxIS4TaVj9JiJ6kIOJjJo
Asw78Tj6DhAA9tMN0Pgcq1ZlW9o7Gj4Z7hyDM/YszSVIH9BlLwc2lP7o8GAPBRM+Ed9+NTwcWqkK
8A72d63IvJd6ZauVtwe6enegeOZO+1ABc0ccGM/A0ZKi3QxIB+mfqNQE6uX4HG5FQXSWgxfVKox2
hrXfhIGpyqBVpMry+47mLshyTQEkH3sFecNSXMQhhrCTWPMVuc24RdDgu1E3Uc1Qn4Cei0g/kepr
sJeX2641/scvmpHLvIpOuJiS3I81ioBZiMDRYogRz4hflyMbKDtIiU9xRcpcWdMyS4ixKvffTvZb
+W+iLEQMhQrtodIyS4AoJpQauWxopHESVsM+s6aUgXvCChKdLTBaXJ/qFCTCS9etti46ELdtT9FB
X3yjkmAaYAQytuaZNjGMLH9r5+FDGZYPeuL44Ovhvtg9EODrfvN49+BQfCx2DvaeHuwP94+HRxgX
dHb4usVGHCB0clRs9o1NrBnsHA5rtdZKG39tjFns0K4ZRpvxb8cGZv9MMf0A1p8ijR/ScDXhLpWC
5iPLFJ1K4kRtfqKVQwFKQzlgoJ7hTlMUs2lotxjrCpFuWzRYU/IksubncW1n1OwVfSftpJN3sjZ3
HMvR2jdkZnY10zuqmiy7Ot2DA56g62ymaI1M+S5G5t/OJFxqxmkbo7RQDfx/oBfKGmSuPXab0cVN
2driqKy6UIeFPdTnSByu2TSUZz0yIAuFMqHIPi6BFuJdNkwIlhmwE+iKRFvrtK6ago1IbzDUfkXL
qjzlu5o87dICdDs0nYvFz8lZHqJBwfYAoH0LZJ3iCbZB0ARn4Ov+goJZG6xsIXWawLnN5rF8SnaO
5Uc2dDI9obplU4G82bY5NvaMM0XHiDHc5WYdOH6olR/ubN7LfrmzAUIigoxiJCgaucEYqRE0RYIb
7Q5rQjCJvIvtwPP/sEaDhR7dcZZ3yasN4/4oYkf2kRxTDuZSnnnvXcwzDQHjQ0V4H/Vcb1mGDKag
GJowYFgaudmMsSQeYGgmmN5oxzCyiziYK8GWife7SpV3kSxLYLqbiGEc/z5HV9RJxln/3KJup/Eu
yxVMYEhILJdXo9L9RRCN85D4R4rSOvmVNwtrR+/KCUoSCvPIpAOJN9oMghfUJe6WkUOoc0LQSMCk
LaBGcgEr3Q+eHA8PB7sHPdE2EHTE/uKPBwLbWAerS1PKZ+Rm/hUnpHwxIOMmT2XR9vnmi25lG2KN
QFj8JKSOX43jBPNSumhJ+I4w5c10dE4T2gg/ywOQMIp3ynG+/o0L3Cy0XcE99kumo6+xRkLcWemx
+P3B4/2m1U7H4gAejP3pyzJhwTScG6XmIqU27kT73MVRWW9UXqmpD1IhN+C5SsFPtPnMC5j2xPMm
y7krmu/6vv+iot0LydKvI590DEjAOxpgN28LLdU1UidQJBXuWrJLdLtorXm/jZqopI2chV6qkpaq
pUbCbdJPb6+jGoKbxaLYvB52qtAYBa4lIwKh75hwMt05X/zI+YZp1+kMQCWbA4UVIAMakNSiyABw
N9hSyK1BUo4BOFSzFFtW6Tg7KaRGw/NgwgvdpHWsB02pXa7jbowkhO8sVyY6x8l+bmivjVJtfE7+
5vd5gAaWCzHIK0aPbfLWHnZljuzdX5ArP7Z5PyVa9nV4CxYjD63HgL26LlshtyngrrNOwG0km5Co
k4JLF7S5S2jB6DUMcY5C3Xh5dcXveC+FheFGH5Tg7ottVb2p+kEiCds9sXPwBD6L3aHYW/z78eHj
ncHR+/Z+izu5VkkcTmLQsZgyvPivCJYJM4d7d0mfa6MVjBlNuleb0FLNE+40Zdr5GBMv2fe0Y6L7
suNsmKSswobo6kRhnQ8M66zh9J20QZ3lZFMKK+6IQVAHdx1KqVDYhQZix1j4bmqYkxlWsmsakrl9
7dRSppCj7KppjMtgazk7gCSIwPHDAUFzRbwRFSHHBzP0S3RmVZGZxIZHKWmH7PIyNCCmGm1i+wLy
UUP2uE4J8s1mcRH/qMdiayK/FnXYsnMdFH5VouPeGdhgNqLvWxLOVDJGAQzv0eauuzAkAmeSd4JI
3MgsOA1CNrFklstQY2QyLNLaBkVW2wiWqYKqVuudRaLGqQcC565MfBLVVN5jyolDvTXEPI3KtiJe
b9M9JQK4ZsiXyFS0hzMDA6PgomvelGcVDTbnOCabaPOm1GOUpDrP0iSdg3oOMPec81n0nhb2DxQc
IQf1xdZD8Vvx6SazHjuVYIOD5GXDX/KRAXgLBEiexakmhS9zCcoY48QpbVE5Sbq00j2j7vWuQy7a
TSnRHeFKJyefcQJojyMOc7NuhcnkkU4JprlEnCtM3JgAw8gQs9KZefShAsKFdxbGpzL0uHuGF6fW
F1cepTzGXo/yun0CLIZb7Q6m0zBU8BCZ9boy8dRAndrMVzC7vjMJchoAFEvMK8i31IVJ4n2qoomx
dVOVaU5lgPZ0rJVjS/0adACHkx08liFKxITyg0DJg1DMZCgod7+lxeGUlwWl8lEGH9N2EAGO1SAK
Zrjt0XE1/zH1Qu1R0qeaWkhIggjNAjMyHnJIe5oyeuY9J1jENwZ8igBDzlm7Npf1pkkXcovGwNyp
lFAxCS5m8aRd7rortj/d3CzaaIi6FoKiIfXTBYp3I2J7nCJFPrVNoDX0jLTSRqLSabBAG0DO8iJI
4yL3oFC9hZGvCWSAiAcAyl5jLV3WEuZzS3kvOlX/oOkl1+otB6BIJsozoljkRZA6M5Dexkz1GqOD
R/MA08R6zE8RJp9nYH+/ERuwUieUUQ4+NrItKEYkocIYx6+S1a33ZmP95MR7XqYycU988sIZ6yTR
+5MmPIwqPYgWPwM5YBCCXISu9QtCiW5Ains6LIx5XeZE/PRu1Rou4QO8vuTKAnktylzG5P7GiE70
94zkvYbbXqUr4jR4iVlg88F178rwAX0xlIffoDksGbzsUsR1xfkGcdD3KvemYZ6eU/DIjeQWLM1L
mzxN4ktAMFsFbnRrGsyG6RzDLA0y5GOxXV66YplA09hHvEFVa/1Z0XnZ1bpFzlRyLEvDfgzqqBx3
xVHpSE17039g7ZVHpAiAItBZQLXyV3sKxNnUK0cqqxYiWnjJhXJDarMc2AQUoFGbRXSg7cRuJKsm
IKEN0DoxdrnBqmeiZ7dWVkGJ4sT6xN2ZapXTDAzUz5eHStwQ/QTzLjB+0ZaLn8nmwnxt0wl8Dc5k
x7d0wgENx/Ud6DUC+nTJRe+G64dFVs5NmVp3SrKxGVvGzkz+NrHa8tTuHqyttf6AkUCv3kUpujd+
6+DgbT3eIV7Y0MWvEUI02d419H6QWN+a2KfgB+5GnxbRmR7pbun4xzXNWUQJqQfMM5vHabr4+UKF
hYDDUe05xSXxQT3D0gg3B/9cGn2f6J+Lzg8c/rOChRGa7CnGQbtkRQ5RFk2NqM70ycpESXj5NA/E
vzry+V8bwoDGhJ6oMeh33lWOBRvzSGPsjicgWAPeRjBHZ0M+r1JMV7dx90qc4XZhGBBN2jgim+5C
BiYNMXFPSKFbpDe8LRU4PVV2x/D881HhjTn7LmvU08AehaK0PzxmVTbQxMEz40Yh3mHYmXhwjj4y
pblYQ0m7agiRHYLSQvaMwm5yIpwzSy4sZZG2zOCssQwyYWXIdbe19rReiM/7ja5ogy1KasGCVuVt
9wQVBR2CuKRoitXDTqp7Xvs1ZHfrlrxdd+cQZrUj6wjzWSXKQnGPbVZGvoMNX2e8msvoy8lkicNQ
Ae+YVLE+i4UhM3OEdG7dTzzqhz5+lsR89hq6rM4SXXJksfHil3lAO9IgLb7LIxP2wSwUtHTAHlI0
jj61lZY7wmi3htXMBYiBzJZ2bZINmt+cBetXjk02i8HyQN3Gl4pY1JLHg/pBwJIQLkURa69U1sMY
fYgm9G+mAbg0aczn553jdZmC53o/wq/1EEwNIppldJ1c8OA8kGm7gpLqft6ACSGJM71v0AbI4rRB
MnWNXLI251iegoE6UZUuMf6h8+0msjhf+6Cj7fZqQoE9zF2BDA+r8uFw3KZNyVVHe30mIodyzcFL
QYc8ZpRHh4UbKrUetL2sd5Zi/SLMAEVGeE4S1QhXiZlOsw/AxONG8xuPXt9onTfQzxHMnadssJ+W
c2NUzimzv2NfIde+Au0zdR13wYjNJgpbAu6NU2zYxG3spbVMxVgl0a8qk6r4Bp7pMfOtD+Ba39tb
390dffXVuQ8igcMCXs9j4QQ2CHlsiXNcroxXNNULDTj1rkpsfb1+ZYp8gFH/Q5uyH6f4tX3/3r+s
35ut35uM7n21fm9v/d7R/c41guBVAD4g/bD4yRQj0Pso9mj1jbs+t2vk4vj1d3EQtYtActedW+nM
wY7mpGlwiVU2NDOw4pt1fLGDDEsbAAg2F4jRjvWWCDJnY28Nz5tx1rBTPoXjDoZfcYOV2sNQRbGZ
vpNC554I1gcfkIKuyglyx4D1I7Al515PPF+2Kp5ZFXHvq969vd69I6/zoiycvceFZMeuHEH/omtV
XuO+E4oE60oVqcCFiLhuQvMEBMqfZuwpIAJ05LZcjocPBhoh2HLVZj0uIPhEn01QuD1jbY2KmdjS
QCA3wBSPzorgCVnY5jgSZ/c0dNJWlz3hcT0XfzzPR3PcFQKHydh1/a2OV95/tEta644prM9lVnTA
o2FMSjVJNzjRZGMSjLOU4dh5+oyOO47jRHUAgWgjZ+oys7FxPCsUse3yUwgL2CTsgjSIoH+w3toE
T1e0kVi7lNiisPDMOOt0mgWemQDgkhs3ZgHecOC+FEvJZy498DF7zoySwGGhzcua0qYx51iU8weW
HYDWq56I+1eM5uv7S3xWd1Y1O7+ULobothHzSs5YxQ02LP28aI5i6zkN9MLlmONERinnccWlfSCQ
6YCeQsSQJCJBUuR+Tkf7MQnxeTTx7avtYvySDERNyhVzTNmF7xY/lkovnIIrSdlBhVEkx8FMVoP8
vKHUJJtLwoBrvZDw50xhkAex43JINw1kJl8qeDVtG9kOX9zKGjBOp8vtRvHLWhozbfUbDwbnxbJd
72NzxSfefSvsHsq5KJhUtx6yN1QoGeopdeFwZznkulmErR5IyInq35f3beBUOKXGKBTibra05Rw9
k051Rf2MaluULf1i/LJwT9W8f/9398s3DRzdagRaXfYp5b384FxJcGn6aOyUsFAN2iMvRWf9+3k2
Xf+H+60Gw3/N7kAaPVls6WrNWkQuABUzkL85Fp7ihCG962HiJnh2tBrYsP05wTIzAsXU7fGCEZXz
GY1o33w0moHLOxp5vZsCvE8wsSeIkCWyuGf0+jaIXy4swEcuUgr2o9DXKVBuJ02lNoo4ReMeRoP5
XAk1VQODNxw/0Udko3EI+HSCJSLSLpgNG2gHvuLlazp7RMR6G5cb+9lt41jNMNbE8lGQusVb6N3O
Xd3/UqMb3X48Ppo2O/8r97zJPc8Cqt2naYMPNTsxDTdb8Ff1zqs+hLOCKEbYOnAqNQFUMsSnlIk0
m1NhyqTmu9Yg6C0xHhrhx6j4IFORFu9XWLmpThzXZpQ2CAWvsSNPZwASruA1HyfIeRTV+VA8V2cC
3raIdjff5EE46TAgRLn8SlouIuC37jB5nHh5y9iG+0xGVkoAVzaP/YYtkqaNXZrL/+L6r+W6nb/O
GDfX/936dPvhg0r9381PNx+u6v/+XdT/LdcC1BVNyXnTQl5siOKAv0B5SKzKsZEu8KWkI+1xnoCP
uGYLBteL8FKnpkheUUiYw2ORLqnZa6gEvP654/HDFx2OMeWGv5R8EO0zBu3zpVm6lMlLhQeVrXaY
VlN01cyWJt41njKKS60H8CP5sCDrZ1jGbYZZdCTKAFL4PDx+wmh4lurKg+Zh+6hWqxvzrPYHuwOK
mjJSlhUGtfm79BbHp2pZvU42b7WQ642hLAdeiTOA1cvC0RZCeEeoRpou6G2TeNuvP6/C6b7/3ORN
v+gWt4i+SneQ0ko3HIMDbD4zl5mMclOyes5noipFjtfXmdYGX+w0qUI6JMAQde7Yy/o6TxOtO8LF
BymTLJMzILlUFdWKzadEtZbUr72lNG2rXpf1EBmjrymLqnhSkWhdmxU+g7NKml9g9pAia5WLT+Kr
IR0GsTzf8akgKKbvBTPKBMtnui5kV5zSEHJO9SB1zvnu4HjwZPD1UJ/SzdFWYFBAkPg94XHjEXcH
3ON1TBnPw8HjPzhusPHHzXd5muLf9ohqMo5GnU6rMqQpAYodtVo7gz3gSEyZbxd5/JoM4QNRn+7i
aFS8fMUr32uK+ZqRuoJf6hijHkkFbHndyzUuA9Z5pFROE72tSw29npIXCEM3LTdx38zHQlfwFQ6w
/h4XFrc9Hu4v/m3xRzyB8l2OAJBpO2O7LZOnCmOBJsIsT2VwqYOzOdDSuZpRWbGjfB6ngbZWjaB3
Dz+bchFuURdT/lyb7OZ+u5SvjqBgM629Ko20+Gs72e6JfC3joxjL5XbeFz2gwEa7w6Pjx/sHmG7p
sV2sk4+U74wq/RLUpa/UqHzEnIMIlDBUqEKJGUOllhjx9B2UFa2KYxvQxoEEN3V8iy163+QUFQfa
sVZepWrn6NQt2wnPnZ8EIEWOudC0F1kuhjzhetG+TbIz2XO6eKnBWSnmofN17lTt846VPt+lyucd
K3y+ZXXPO1b2fJ8z/O9UbtNNkuK1p6KxmEKbxJQRWSy+3jwHh1mOM5XQYYCLxY8hHePjUhQxx4a1
TLf1N2f6TJndArQUgHVIYjoj5IOx1k7uP//s8563cXLy5p9+e3K5ubl+crk1fXEfFmuEB62yhGGy
VVD8hD94vijXoOWOMZ8uVbMRNjLEzZu+9jCStlHKlZ1ptky6bVsI2qkC7XBjp/hpiVo9Km1tbpik
UTttnXLtBPl/5boc5QS1O2dg8lObculIvq6ueNHtFG+bnUXd6oNUpnComtNX7SG6+7xV3LiXUs39
W15+4p0qT3zQohMa1jZhD/M2GY/Pt+ynBy86CDCj1w1o0jEDh3ebT9pZO7xP21WWwunvrqnUdHc6
1zW/uc9ekYHMGgG3O7gMJB15xCGhS/pRFl1uiPZgk8UvsMQ6G9uyBff5FIZEL85SaSntrTjuqd+7
qdqG0WCteu2h+lnAmkBcpqNuFiHLKW4J2MupbcmBwnclNyISXaGdZLR29LuivviO0se1aKdKp4UC
JdzmhDedfzVrnLAHUjFeucMXbi2mIlIPxn4bmzmiz92jo0c1wcE/VECjUeIHGO1X+O3anO6z3rVr
yuMb3ZIO1DPslO8WaLLF2Sw81HHj7qAmH3pBr8Yy377PjMN46RvbvsK8dw2K6KJI5tx8fXGot6qx
Vj+tfOM5ZdR+1IqNDjb1qOO28fJoNXC3mp0ik5NDmS3fgx8PvlDCdUTA76OmO+c6EsUnK7Cw6rJg
SMcJXpu8owjr5+jR5nJCJeT62t0vix7eN6JMOaA9cNfKBNqrHOb9Roa5Il4DUtsxPh5bQ0Bp97Wj
eH0ffy9HkciDOV4ZH9A3ROjSTTNL1AjJPWW99HS1E3spn4RedgJ66h2XtSqdpDGuycZNC+8vsycd
X6ykVZzTxi5b3FUwVTlnSdSpSdvhj5ZhoNIm7FkbWYkzzUwYGOWgIdLdtiaLtMwjV6V4VA+PCXVt
RQDzlcMJ5hvFFOgLH2hdVvfrdk4rU+7fNSmU3doyUZgavP0atp1vjMvGSEuvntZmmKr4oZLbqc2Z
S5FLVVKl9sdOTDe3/HxMl9zBbukXSwpCNT+5Yn+OhLfNtaeNrlaipsElboYmvClKAV39E0qGKsxL
/KssV7WfYekJb3NrvfabLJZmvc0H62mA1OQ+1TTsbW6vn8XhRD+6bjWLUAeGt5SfRnx69uCh/WUU
E4eiU9i036prYVH15kn+2hSEAVpKciyKiBg0JSE0SBgCLYCz1kfJHi9yAL0r/fL1xlWxtPzFru31
hue2YNbZwPRVfLP0Uyxeq/D1NSFJsD00CVAUGF00ExH2B8lZji70U3rSnigO14KC67Nxdif9j8Xy
yXw3hRCoN0xoAMB4gLan49z0G1Tf4+F+9gi74lyF875XK1N6U2cF2ZiIuUNKMGsJvNSv/ywQ+IzB
WKV9E3X9WLQ9irR77ok2hkdTjuTDSKKtdXzPRPTNBnBHn/8/Syn4TbDSH4QWM1padoP+LPU1FWOi
Dg/cc8BevulBbR0X4DZpu6w0SCUnZJlQKwS22SPRZNxUU6i+lVRAa61MZ/KlGXDjt4afgeOD+yAw
b8mBYhb4aHWtrtW1ulbX6lpdq2t1ra7VtbpW1+paXatrda2u1bW6VtfqWl2ra3WtrtW1ulbX6lpd
q2t1ra7VtbpW1+paXavr/8T13yjqadEAoAAA
