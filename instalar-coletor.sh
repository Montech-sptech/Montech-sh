#!/usr/bin/env bash
# ============================================================
#  MonTech - Instalador do coletor de métricas
#  Rode no SERVIDOR do cliente (Linux) que vai executar a captura.
#
#  O envio dos CSVs ao S3 é feito por uma Lambda (Function URL): o servidor
#  NÃO precisa de credenciais AWS, bucket nem região.
#
#  O que faz:
#    1. Instala o que faltar (Python 3.9+, venv, pip, tmux)
#    2. Cria a pasta do coletor com ambiente virtual e dependências
#    3. Coloca Script_Extracao.py e Organizador.py (embutidos neste arquivo
#       ou ao lado do instalador)
#    4. Configura a URL da Lambda e o acesso ao MySQL (.env)
#    5. Valida banco e Lambda e gera o iniciar_coleta.sh
#
#  Uso:
#    bash instalar-coletor.sh            instalação completa
#    bash instalar-coletor.sh --lambda   só troca a URL da Lambda
#
#  Para automatizar (sem perguntas), defina antes: MONTECH_DB_HOST,
#  MONTECH_DB_USER, MONTECH_DB_PASSWORD, MONTECH_DB_NAME, MONTECH_URL_LAMBDA
#  e, se quiser outra pasta, MONTECH_DIR.
# ============================================================
# Se foi chamado com "sh instalar-coletor.sh", reexecuta com bash.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -uo pipefail

# ---------- CONFIGURAÇÃO DA EQUIPE (edite antes de enviar ao cliente) ----------
DEFAULT_DB_HOST=""            # IP/DNS do MySQL. Vazio = o cliente digita.
DEFAULT_DB_USER="montech"
DEFAULT_DB_NAME="montech"
DEFAULT_URL_LAMBDA=""         # Vazio = usa a URL que já está no Script_Extracao.py.
# --------------------------------------------------------------------------------

SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
INSTALL_DIR="${MONTECH_DIR:-$HOME/montech-coletor}"
PY="$INSTALL_DIR/.venv/bin/python"
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
  --lambda         troca somente a URL da Lambda de envio
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
v_host()   { [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; }
v_ident()  { [[ $1 =~ ^[A-Za-z0-9_.-]+$ ]]; }
v_url()    { [[ $1 =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~%/-]*)?$ ]]; }

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

# O envio usa só a biblioteca padrão (urllib), então não há boto3.
instalar_dependencias() {
  if ! passo "Instalando dependências (pandas, psutil, mysql-connector...)" \
      "$PY" -m pip install --quiet --disable-pip-version-check \
      pandas psutil mysql-connector-python python-dotenv; then
    tail -n 12 "$LOG" >&2
    die "Falha ao instalar as dependências. Verifique a internet do servidor. Log: $LOG"
  fi
  "$PY" -c 'import pandas, psutil, mysql.connector, dotenv' >>"$LOG" 2>&1 ||
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

# Grava a URL da Lambda na linha URL_LAMBDA = "..." do Script_Extracao.py.
aplicar_config_py() {
  grep -q -E '^URL_LAMBDA = "' "$PYFILE" ||
    die "Não encontrei a linha URL_LAMBDA no Script_Extracao.py. Este instalador é para a versão do coletor que envia via Lambda."
  sed -i -E "s|^URL_LAMBDA = \".*\"|URL_LAMBDA = \"$URL_LAMBDA\"|" "$PYFILE"
  [[ "$(valor_py URL_LAMBDA)" == "$URL_LAMBDA" ]] ||
    die "Não consegui gravar a URL da Lambda no Script_Extracao.py."
  ok "URL da Lambda configurada no coletor."
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

escrever_launcher() {
  cat >"$INSTALL_DIR/iniciar_coleta.sh" <<'LAUNCHER'
#!/usr/bin/env bash
# Inicia o coletor MonTech (pede e-mail, senha e token do servidor monitorado).
# Ctrl+C encerra e reenvia os CSVs pendentes pela Lambda.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR" || exit 1
exec "$DIR/.venv/bin/python" Script_Extracao.py "$@"
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
# Testa se a Lambda responde, SEM enviar arquivo (não grava nada no S3).
# Qualquer resposta HTTP prova que a URL existe e está acessível; só 403 é suspeito
# (Function URL com autenticação IAM recusa chamadas sem assinatura).
validar_lambda() {
  local saida linha tmp script codigo
  tmp=$(mktemp); script=$(mktemp)
  cat >"$script" <<'PY'
import os
import urllib.request
import urllib.error

url = os.environ["MONTECH_URL"]
try:
    with urllib.request.urlopen(urllib.request.Request(url, method="GET"), timeout=15) as r:
        print("HTTP|%s" % r.status)
except urllib.error.HTTPError as e:
    print("HTTP|%s" % e.code)
except Exception as e:
    print("ERRO|" + type(e).__name__ + ": " + str(e).replace("\n", " "))
PY
  MONTECH_URL="$URL_LAMBDA" \
    spin_run "$tmp" "Testando a conexão com a Lambda" "$PY" "$script" || true
  saida=$(cat "$tmp"); rm -f "$tmp" "$script"
  linha=$(grep -m1 -E '^(HTTP|ERRO)\|' <<<"$saida" || true)

  case "$linha" in
    HTTP\|403)
      aviso "A Lambda respondeu 403 (acesso negado)."
      info "Dica: a Function URL precisa ter o tipo de autenticação NONE (pública). Com AWS_IAM, o coletor não consegue enviar."
      return 1 ;;
    HTTP\|*)
      codigo=${linha#HTTP|}
      ok "Lambda acessível (resposta HTTP $codigo ao teste, nenhum arquivo foi enviado)."
      return 0 ;;
    ERRO\|*)
      aviso "Não consegui acessar a Lambda: ${linha#ERRO|}"
      info "Dica: confira a URL (copie inteira, com https:// e a barra final) e a internet/firewall do servidor (saída HTTPS na porta 443)."
      info "Sem isso os CSVs não são enviados (ficam salvos localmente)."
      return 1 ;;
    *)
      aviso "Não consegui testar a Lambda:"; printf '%s\n' "$saida" | tail -n 5
      return 1 ;;
  esac
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
modo_lambda() {
  [[ -x "$PY" && -f "$PYFILE" ]] || die "Instalação não encontrada em $INSTALL_DIR. Rode a instalação completa primeiro."
  titulo "Trocar a URL da Lambda"
  perguntar_valido URL_LAMBDA "URL da Lambda (Function URL)" "${DEFAULT_URL_LAMBDA:-$(valor_py URL_LAMBDA)}" v_url \
    "URL inválida. Exemplo: https://xxxx.lambda-url.us-east-1.on.aws/"
  aplicar_config_py
  validar_lambda || { aviso "URL gravada, mas a Lambda não respondeu como esperado."; exit 1; }
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
  local prev_url="" def_url
  if [[ -f "$PYFILE" ]]; then prev_url=$(valor_py URL_LAMBDA); fi
  obter_codigo
  def_url=${DEFAULT_URL_LAMBDA:-${prev_url:-$(valor_py URL_LAMBDA)}}

  local prev_host="" prev_user="" prev_name=""
  if [[ -f "$INSTALL_DIR/.env" ]]; then
    prev_host=$(sed -n -E 's/^DB_HOST=(.*)$/\1/p' "$INSTALL_DIR/.env" | head -n1)
    prev_user=$(sed -n -E 's/^DB_USER=(.*)$/\1/p' "$INSTALL_DIR/.env" | head -n1)
    prev_name=$(sed -n -E 's/^DB_NAME=(.*)$/\1/p' "$INSTALL_DIR/.env" | head -n1)
  fi

  titulo "2/5 Configuração"
  info "Lambda que recebe os CSVs e grava no S3 (não precisa de credenciais AWS):"
  perguntar_valido URL_LAMBDA "URL da Lambda (Function URL)" "$def_url" v_url \
    "URL inválida. Exemplo: https://xxxx.lambda-url.us-east-1.on.aws/"
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

  titulo "3/5 Ambiente Python"
  garantir_venv
  instalar_dependencias
  garantir_tmux

  titulo "4/5 Gravando configuração"
  aplicar_config_py
  escrever_env
  escrever_launcher
  copiar_instalador
  "$PY" -m py_compile "$INSTALL_DIR/Script_Extracao.py" "$INSTALL_DIR/Organizador.py" ||
    die "O código do coletor tem erro de sintaxe."

  titulo "5/5 Validando conexões"
  local pendencias=0
  validar_banco  || pendencias=$((pendencias + 1))
  validar_lambda || pendencias=$((pendencias + 1))

  titulo "Instalação concluída"
  info "Pasta: $INSTALL_DIR"
  echo
  info "Para iniciar a coleta (mantém rodando mesmo se o SSH cair):"
  info "  tmux new -s montech"
  info "  $INSTALL_DIR/iniciar_coleta.sh"
  info "Sair sem parar: Ctrl+B e depois D  |  Voltar: tmux attach -t montech  |  Parar: Ctrl+C"
  echo
  info "Se a URL da Lambda mudar:"
  info "  $INSTALL_DIR/instalar-coletor.sh --lambda"
  if (( pendencias > 0 )); then
    printf '\n'
    aviso "$pendencias validação(ões) falharam (veja acima). A instalação está pronta, mas corrija isso antes de coletar."
  fi
}

main() {
  case "${1:-}" in
    ""|--instalar)     modo_instalar ;;
    --lambda)          modo_lambda ;;
    -h|--ajuda|--help) uso ;;
    *) uso; exit 1 ;;
  esac
}

trap interrompido INT TERM
trap cursor_on EXIT


main "$@"
exit $?

# Para embutir o código do coletor neste instalador (arquivo único), veja o
# comando de empacotamento abaixo. A linha marcadora precisa ficar sozinha e
# o conteúdo base64 vem logo depois dela. Não é necessário se o
# Script_Extracao.py e o Organizador.py estiverem na mesma pasta do instalador.
