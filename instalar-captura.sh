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

# Tabelas que o coletor consulta (no Linux o MySQL diferencia maiúsculas de minúsculas).
TABELAS = ["usuario", "servidor", "componente", "servidorcomponente", "aeroporto", "empresa"]

def texto(x):
    return x.decode() if isinstance(x, (bytes, bytearray)) else x

try:
    c = mysql.connector.connect(
        host=os.getenv("DB_HOST"), user=os.getenv("DB_USER"),
        password=os.getenv("DB_PASSWORD"), database=os.getenv("DB_NAME"),
        connection_timeout=8,
    )
    cur = c.cursor()
    cur.execute("SHOW TABLES")
    existentes = {texto(linha[0]) for linha in cur.fetchall()}
    faltam = [t for t in TABELAS if t not in existentes]
    if faltam:
        print("FALTA|" + ",".join(faltam))
    else:
        try:
            # Não altera nada (WHERE 1 = 0): só confirma que a coluna statusAtividade existe
            # e que o usuário tem permissão de UPDATE, como o coletor vai precisar.
            cur.execute("UPDATE servidor SET statusAtividade = statusAtividade WHERE 1 = 0")
            c.rollback()
            print("OK|completo")
        except mysql.connector.Error as e:
            print("STATUS|%s|%s" % (e.errno, str(e).replace("\n", " ")))
    c.close()
except mysql.connector.Error as e:
    print("ERRO|%s|%s" % (e.errno, str(e).replace("\n", " ")))
PY
  spin_run "$tmp" "Testando a conexão com o MySQL" \
    bash -c 'cd "$1" && exec "$2" "$3"' _ "$INSTALL_DIR" "$PY" "$script" || true
  saida=$(cat "$tmp"); rm -f "$tmp" "$script"

  linha=$(grep -m1 -E '^(OK|ERRO|FALTA|STATUS)\|' <<<"$saida" || true)

  case "$linha" in
    OK\|completo)
      ok "Banco acessível e com as tabelas esperadas ($DB_USER@$DB_HOST/$DB_NAME)."; return 0 ;;
    FALTA\|*)
      aviso "O banco '$DB_NAME' não tem as tabelas: ${linha#FALTA|}"
      info "Confira se o script SQL foi importado. Os nomes precisam estar em minúsculas (ex.: servidorcomponente), pois no Linux o MySQL diferencia maiúsculas."
      return 1 ;;
    STATUS\|*)
      local est=${linha#STATUS|}; est=${est%%|*}
      case "$est" in
        1054) aviso "A tabela 'servidor' não tem a coluna 'statusAtividade', que o coletor atualiza."
              info "Atualize o script SQL do banco (acrescente essa coluna na tabela servidor)." ;;
        1142|1143) aviso "O usuário '$DB_USER' não tem permissão de UPDATE na tabela 'servidor' (o coletor marca o servidor como ativo)."
              info "No MySQL, conceda: GRANT UPDATE ON $DB_NAME.servidor TO '$DB_USER'@'%';" ;;
        *)    aviso "Não consegui testar a atualização do status: ${linha#STATUS|*|}" ;;
      esac
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

