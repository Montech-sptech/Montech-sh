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
#  MONTECH_DB_USER, MONTECH_DB_PASSWORD, MONTECH_DB_NAME, MONTECH_BUCKET,
#  MONTECH_REGIAO, MONTECH_AWS_KEY, MONTECH_AWS_SECRET, MONTECH_AWS_TOKEN
#  e, se quiser outra pasta, MONTECH_DIR.
# ============================================================
# Se foi chamado com "sh instalar-coletor.sh", reexecuta com bash.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -uo pipefail
 
# ---------- CONFIGURAÇÃO DA EQUIPE (edite antes de enviar ao cliente) ----------
DEFAULT_DB_HOST=""            # IP/DNS do MySQL. Vazio = o cliente digita.
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
 
# ---------- Barra girando (spinner) ----------
SPIN_FRAMES='|/-\'
SPIN_PID=""
SPIN_SEG=0
 
cursor_on() { [[ -t 1 ]] && printf '\e[?25h'; return 0; }
 
interrompido() {
  [[ -n "$SPIN_PID" ]] && kill "$SPIN_PID" 2>/dev/null
  [[ -t 1 ]] && printf '\r\e[K\e[?25h'
  printf '\n'; erro "Instalação interrompida."; exit 130
}
 
# spin_run ARQUIVO_SAIDA "mensagem" comando...
# Roda o comando mostrando uma barra girando (só em terminal). A saída vai para o arquivo.
# Deixa o tempo gasto em SPIN_SEG e devolve o status do comando.
spin_run() {
  local out=$1 msg=$2 inicio=$SECONDS rc i=0
  shift 2
  if [[ ! -t 1 ]]; then
    info "$msg..."
    "$@" >"$out" 2>&1 </dev/null; rc=$?
    SPIN_SEG=$((SECONDS - inicio)); return $rc
  fi
  "$@" >"$out" 2>&1 </dev/null &
  SPIN_PID=$!
  printf '\e[?25l'
  while kill -0 "$SPIN_PID" 2>/dev/null; do
    printf '\r   %s%s%s %s (%ds)\e[K' "$C_B" "${SPIN_FRAMES:$((i % 4)):1}" "$C_OFF" "$msg" $((SECONDS - inicio))
    i=$((i + 1)); sleep 0.12
  done
  wait "$SPIN_PID"; rc=$?
  SPIN_PID=""
  printf '\r\e[K\e[?25h'
  SPIN_SEG=$((SECONDS - inicio))
  return $rc
}
 
# passo "mensagem" comando...  -> spinner + saída anexada ao log de instalação
passo() {
  local msg=$1 tmp rc; shift
  tmp=$(mktemp)
  spin_run "$tmp" "$msg" "$@"; rc=$?
  { printf '\n### %s (status %s)\n' "$msg" "$rc"; cat "$tmp"; } >>"$LOG"
  rm -f "$tmp"
  return $rc
}
 
# O sudo pode pedir senha: precisa ser antes do spinner, em primeiro plano.
preparar_sudo() {
  (( EUID == 0 )) && return 0
  command -v sudo >/dev/null 2>&1 || return 1
  info "É preciso permissão de administrador (sudo) para instalar pacotes."
  sudo -v
}
 
uso() {
  cat <<'USO'
Uso: bash instalar-coletor.sh [opção]
  (sem opção)      instalação completa
  --credenciais    renova somente as credenciais AWS
  -h, --ajuda      mostra esta ajuda
USO
}
 
# ---------- Perguntas ----------
# Lê as respostas do terminal. Se o stdin já é um terminal, lê direto dele (reabrir
# /dev/stdin falha com "Permission denied" quando o terminal é de outro usuário, ex.: após su).
# Se o script vier por pipe, usa /dev/tty.
if [[ -t 0 ]]; then
  TTY_IN=stdin
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
  local _rd=(read -r)
  [[ -n "$_secret" ]] && _rd+=(-s)
  _rd+=(-p "$_prompt: ")
  while :; do
    if [[ "$TTY_IN" == /dev/tty ]]; then
      "${_rd[@]}" _val </dev/tty || die "Não consegui ler a resposta do terminal."
    else
      "${_rd[@]}" _val || die "Entrada encerrada antes de terminar as perguntas."
    fi
    [[ -n "$_secret" ]] && echo >&2
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
    como_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    # shellcheck disable=SC2086
    como_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $apt_pk
  elif command -v dnf >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    como_root dnf install -y -q $dnf_pk
  elif command -v yum >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    como_root yum install -y -q $dnf_pk
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
  python_ok || return 1
  passo "Criando o ambiente virtual Python" python3 -m venv "$INSTALL_DIR/.venv" && return 0
  rm -rf "$INSTALL_DIR/.venv"
  return 1
}
 
garantir_venv() {
  criar_venv && { ok "Ambiente virtual pronto."; return 0; }
  info "Faltam componentes do Python neste servidor."
  if preparar_sudo; then
    passo "Instalando Python, venv e pip" pkg_instalar py || true
  fi
  criar_venv || die "Não foi possível criar o ambiente Python. É preciso Python 3.9+ com venv e pip (ex.: sudo apt install python3 python3-venv python3-pip) e internet. Veja $LOG"
  ok "Ambiente virtual pronto."
}
 
instalar_dependencias() {
  if ! passo "Instalando dependências (pandas, boto3, mysql-connector...)" \
      "$PY" -m pip install --quiet --disable-pip-version-check \
      pandas psutil boto3 mysql-connector-python python-dotenv; then
    tail -n 12 "$LOG" >&2
    die "Falha ao instalar as dependências. Verifique a internet do servidor. Log: $LOG"
  fi
  "$PY" -c 'import pandas, psutil, boto3, mysql.connector, dotenv' >>"$LOG" 2>&1 ||
    die "As dependências foram instaladas, mas não importam. Veja $LOG"
  ok "Dependências instaladas (${SPIN_SEG}s)."
}
 
garantir_tmux() {
  command -v tmux >/dev/null 2>&1 && return 0
  if preparar_sudo && passo "Instalando o tmux" pkg_instalar tmux && command -v tmux >/dev/null 2>&1; then
    ok "tmux instalado (mantém a coleta rodando se o SSH cair)."
  else
    aviso "Não consegui instalar o tmux. Instale tmux ou screen para manter a coleta ativa após fechar o SSH."
  fi
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
  local saida id_linha b_linha tmp script
  tmp=$(mktemp); script=$(mktemp)
  cat >"$script" <<'PY'
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
  MONTECH_REGIAO="$REGIAO" MONTECH_BUCKET="$BUCKET" \
    spin_run "$tmp" "Testando credenciais AWS e acesso ao bucket" env_aws "$PY" "$script" || true
  saida=$(cat "$tmp"); rm -f "$tmp" "$script"
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
  local saida linha tmp script
  tmp=$(mktemp); script=$(mktemp)
  cat >"$script" <<'PY'
import os
from dotenv import load_dotenv
load_dotenv(os.path.join(os.getcwd(), ".env"))
import mysql.connector
try:
    c = mysql.connector.connect(
        host=os.getenv("DB_HOST"), user=os.getenv("DB_USER"),
        password=os.getenv("DB_PASSWORD"), database=os.getenv("DB_NAME"),
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
  spin_run "$tmp" "Testando a conexão com o MySQL" \
    bash -c 'cd "$1" && exec "$2" "$3"' _ "$INSTALL_DIR" "$PY" "$script" || true
  saida=$(cat "$tmp"); rm -f "$tmp" "$script"
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
        *)    info "Dica: confira o endereço, o firewall/Security Group e se o MySQL está acessível a partir deste servidor."
              info "O coletor usa sempre a porta 3306. Se o MySQL só aceita conexões locais, é preciso túnel SSH ou liberar o acesso." ;;
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
  ask AWS_SECRET "AWS Secret Access Key" "" ""
  AWS_SECRET=$(sem_espacos "$AWS_SECRET")
  v_secret "$AWS_SECRET" || aviso "A Secret Access Key tem um formato estranho (esperado: 30+ caracteres base64)."
  ask AWS_TOKEN "AWS Session Token (Enter se não usar)" "" "" optional
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
 
  local prev_host="" prev_user="" prev_name=""
  if [[ -f "$INSTALL_DIR/.env" ]]; then
    prev_host=$(sed -n -E 's/^DB_HOST=(.*)$/\1/p' "$INSTALL_DIR/.env" | head -n1)
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
 
trap interrompido INT TERM
trap cursor_on EXIT
 
main "$@"
exit $?

# Tudo abaixo desta linha é o código do coletor (tar.gz em base64). Não edite.
__MONTECH_PAYLOAD__
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
X47+C8LhBfwAoAAA
