# Guia de Implantação MonTech

Passo a passo automatizado e consolidado para implantação da infraestrutura: VM EC2 (Ubuntu), MySQL no Docker, Coletor de Métricas no Windows/Linux e ETL incremental no AWS Lambda, acionada por upload no S3.

Os scripts `.sh` da equipe são mantidos sem alterações neste documento. Este guia substitui a instalação/agendamento da ETL na EC2 pela função `lambda_function.py`. O MySQL continua no Docker da EC2 para cadastro, login e configuração da captura. O Lambda desta versão usa S3 e não consulta o MySQL.

**Use os arquivos finais da mesma revisão do projeto:** `Script_Extracao.py`, `Organizador.py`, `lambda_function.py`, SQL do banco e scripts `.sh`. Não use as versões intermediárias da conversa, que listavam toda a bronze ou restringiam a função somente às saídas de teste.

## 📋 Visão Geral do Ambiente

| Parte | Ambiente | O que faz | 
| ----- | ----- | ----- | 
| **Parte 0** | VM (SSH) | Provisionamento e auditoria de usuários (`config-acesso-ec2.sh`) | 
| **Parte 1** | VM (SSH) | Preparação do ambiente e criação do Data Lake S3 (`configurar-ambiente-datalake.sh`) | 
| **Parte 2** | VM (SSH) | Instalação do Docker e subida do container MySQL | 
| **Parte 3.1** | Windows (PowerShell) | Coletor de métricas enviando CSV para o Data Lake | 
| **Parte 3.2** | Linux (Bash) | Coletor de métricas enviando CSV para o Data Lake |
| **Parte 4** | VM + console AWS | Construção da layer e criação da função Lambda | 
| **Parte 5** | Console AWS + computador local | Carga inicial, gatilho S3, testes e ativação definitiva | 
| **Parte 6** | VM / Windows | Manutenção (renovação de credenciais) e solução de erros | 

---

## Antes de começar: valores de cada integrante

Cada pessoa usa sua própria conta/sessão do laboratório e seu próprio bucket. O bucket `montech-datalake-2492` foi o usado na validação e não deve ser copiado como destino de outra conta.

| Identificador no guia | Substituir por |
| --- | --- |
| `SEU_BUCKET` ou `montech-datalake-XXXX` | Nome exibido pelo script de criação do Data Lake |
| `IP_PUBLICO` | IP público atual da EC2 que hospeda o MySQL |
| `CAMINHO_DA_CHAVE.pem` | Caminho da chave SSH dessa instância |
| `SENHA_ROOT` / `SENHA_MONTECH` | Senhas escolhidas para o container |
| Credenciais AWS | Access Key, Secret Key e Session Token da mesma sessão atual do lab |
| Empresa, aeroporto e token nos caminhos | IDs e token cadastrados no banco usado pela captura |

Crie uma EC2 Ubuntu x86_64 em `us-east-1`, aguarde o estado executando e use o usuário `ubuntu`. Os comandos Bash abaixo são executados nela, salvo indicação de outro ambiente. Para SSH, libere TCP 22 para seu IP público. No Windows, instale Python e AWS CLI v2 antes da Parte 3.1; valide `python --version` e `aws --version`. O instalador oficial do AWS CLI está em https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html.

**Banco:** importe o SQL da mesma revisão do projeto. Se optar por um banco local além do da EC2, importe o mesmo SQL nos dois e confira IDs/vínculos/token; não há sincronização automática entre eles. No fluxo principal deste guia, a captura acessa o banco central da EC2.

## 🛠️ PARTE 0: Acesso e Política de Usuários

Conecte-se à VM EC2 via SSH e crie os usuários da equipe de forma automatizada.

0. **Mudar permissão da chave (Linux, macOS ou WSL; não executar `chmod` no PowerShell):**
   ```bash
   chmod 400 "CAMINHO_DA_CHAVE.pem"
   ```

1. **Conectar na VM (o comando SSH também funciona no PowerShell):**
   ```bash
   ssh -i "CAMINHO_DA_CHAVE.pem" ubuntu@IP_PUBLICO
   ```

2. **Criar o script de acesso (`config-acesso-ec2.sh`):**
   ```bash
   nano ~/config-acesso-ec2.sh
   ```
   *(Cole o conteúdo do seu script `config-acesso-ec2.sh`, salve com `Ctrl+O`, `Enter` e saia com `Ctrl+X`)*.

3. **Rodar com privilégios de root:**
   ```bash
   sudo chmod +x ~/config-acesso-ec2.sh
   sudo ~/config-acesso-ec2.sh
   ```

4. **Conferir se os usuários foram criados corretamente:**
   ```bash
   getent passwd guilherme thiago lucas vinicius nicole montech | cut -d: -f1
   ```

---

## ☁️ PARTE 1: AWS CLI e Buckets (Data Lake)

O script abaixo já instala dependências (Python, OpenJDK 21), configura o AWS CLI e cria toda a estrutura do S3.

1. **Criar o script de configuração do ambiente e Data Lake (`configurar-ambiente-datalake.sh`):**
   ```bash
   nano ~/configurar-ambiente-datalake.sh
   ```
   *(Cole o conteúdo do seu script `configurar-ambiente-datalake.sh`, salve e feche)*.

2. **Executar o script:**
   ```bash
   chmod +x ~/configurar-ambiente-datalake.sh
   ~/configurar-ambiente-datalake.sh
   ```
   *Nota: O script solicitará suas credenciais da AWS (`Access Key`, `Secret Key`, `Session Token`) e a região. Digite exatamente `us-east-1`.*

3. **Conferir e anotar o nome do bucket gerado (não execute esse script novamente apenas para renovar credenciais, pois ele cria outro bucket):**
   ```bash
   aws sts get-caller-identity
   aws s3 ls | grep montech-datalake
   ```

---

## 🐳 PARTE 2: Docker e MySQL

1. **Instalar o Docker:**
   ```bash
   sudo apt install -y docker.io
   sudo systemctl enable --now docker
   sudo docker ps
   ```

2. **Criar o arquivo de variáveis de ambiente do MySQL:**
   ```bash
   cat > ~/montech-mysql.env << 'EOF'
   MYSQL_ROOT_PASSWORD=SENHA_ROOT
   MYSQL_DATABASE=montech
   MYSQL_ROOT_HOST=localhost
   MYSQL_USER=montech
   MYSQL_PASSWORD=SENHA_MONTECH
   EOF
   chmod 600 ~/montech-mysql.env
   ```
   *(Lembre-se de alterar `SENHA_ROOT` e `SENHA_MONTECH` antes de rodar, sem espaços ao redor do `=`).*

3. **Subir o container MySQL:**
   ```bash
   sudo docker run -d --name montech-mysql --restart unless-stopped \
   --env-file "$HOME/montech-mysql.env" \
   -p 3306:3306 \
   -v montech_mysql_data:/var/lib/mysql \
   mysql:8.4
   ```
   *Aguarde cerca de 30 segundos e verifique os logs:*
   ```bash
   sudo docker logs --tail 30 montech-mysql
   ```

4. **Popular o banco de dados (`montech.sql`):**
   ```bash
   nano ~/montech.sql
   ```
   *(Cole o script SQL com as tabelas e inserts, salve e feche).*

5. **Importar e testar:**
   ```bash
   sudo docker exec -i montech-mysql \
     sh -c 'mysql -u root -p"$MYSQL_ROOT_PASSWORD" montech' < ~/montech.sql
   
   sudo docker exec -it montech-mysql \
     sh -c 'mysql -u montech -p"$MYSQL_PASSWORD" montech -e "SHOW TABLES;"'
   ```
   
---
## 🔐 Parte 3: Segurança na porta MySQL na AWS
---

Como a porta **3306** estará publicada nas interfaces de rede da VM, restrinja o acesso usando a **Security Group da VM** que hospeda o MySQL.

* Na tela de **Instâncias**, selecione a VM que está o MySQL no container Docker.
* Selecione a opção **"Segurança"**.
* Em **"Regras de entrada"** clique no **"Grupo de segurança"** que vai estar em azul.
* Clique no **"ID do grupo de segurança"** que vai estar em azul também.
* Agora clique em **"Editar regras de entrada"**.
* Clique em **"Adicionar regra"**.
* Preencha no **Tipo** com **MYSQL/Aurora**.
* **Intervalo de portas** coloque **3306**.
* Em **Origem** coloque o IP publico da máquina que deseja acessar o banco e **"/32"** no final (use seu IP público real seguido de /32; nunca 127.0.0.1, que é loopback).
* Clique em **"Salvar regras"** e pronto!

Caso seu SO seja Windows, faça a "PARTE 3.1". Se for Linux, faça a "PARTE 3.2".

---
## 💻 PARTE 3.1: Coletor de Métricas (Windows)

No seu computador local simulando os servidores (**PowerShell**, dentro da pasta do projeto, onde estão o `Script_Extracao.py` e o `Organizador.py`).

Esta parte faz, na mão, o mesmo que o `instalar-coletor.sh` faz no Linux: prepara o Python, configura o bucket, o banco e as credenciais AWS, e **valida tudo antes de coletar**.

> **Antes de começar, tenha em mãos:** o nome do bucket (`montech-datalake-XXXX`), o IP público da EC2, a senha do usuário `montech` do MySQL e as 3 credenciais da AWS (Access Key, Secret Key e Session Token, todas da **mesma sessão** do laboratório).

---

### 1. Criar o ambiente virtual e instalar as dependências

```powershell
python --version
python -m venv venv
.\venv\Scripts\Activate
python -m pip install pandas psutil boto3 mysql-connector-python python-dotenv
```

Valide (deve imprimir `Dependencias OK`; use Python **3.14** para seguir o ambiente de referência):

```powershell
python -c "import pandas, psutil, boto3, mysql.connector, dotenv; print('Dependencias OK')"
```

> Se o `Activate` der o erro *"a execução de scripts foi desabilitada neste sistema"*, rode `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` (vale só para esta janela) e ative de novo. O prompt deve passar a começar com `(venv)`.

---

### 2. Configurar o bucket e a região no código

Abra com `notepad Script_Extracao.py` (ou, de preferência no VS Code: `code Script_Extracao.py`; no Bloco de Notas, use `Ctrl+F` e procure `NOME_BUCKET`):

- Procure `NOME_BUCKET` e troque o nome pelo do seu bucket: `NOME_BUCKET = "montech-datalake-XXXX"`
- Procure `REGIAO_AWS` e confira a região: `REGIAO_AWS = "us-east-1"` (nunca `us-east-1d`, que é zona de disponibilidade)

Salve o arquivo em **UTF-8** e confirme que as duas linhas ficaram certas:

```powershell
Select-String -Path Script_Extracao.py -Pattern '^(NOME_BUCKET|REGIAO_AWS) ='
```

---

### 3. Acesso ao MySQL e arquivo `.env`

Escolha **A** ou **B**, conforme a EC2.

**A. Conexão direta (recomendado)** — quando o container do MySQL publica a porta (`-p 3306:3306`) e o Security Group da EC2 libera **TCP 3306** para o seu IP público.

Descubra o seu IP público (é ele que vai no Security Group, no formato `IP/32`; não use o `192.168.x.x`):

```powershell
(Invoke-RestMethod https://checkip.amazonaws.com).Trim()
```

Teste a rede (deve mostrar `TcpTestSucceeded : True`):

```powershell
Test-NetConnection IP_PUBLICO -Port 3306
```

**B. Túnel SSH** — só se a porta 3306 da EC2 **não** estiver aberta. Em **outra janela do PowerShell**, rode e deixe aberta:

```powershell
ssh -i "CAMINHO_DA_CHAVE.pem" -L 3306:127.0.0.1:3306 ubuntu@IP_PUBLICO
```

Na janela principal, teste (deve mostrar `TcpTestSucceeded : True`):

```powershell
Test-NetConnection 127.0.0.1 -Port 3306
```

> ⚠️ O túnel precisa usar a porta local **3306** (não 3307), porque o coletor não lê `DB_PORT` e sempre conecta na 3306. Se houver um MySQL instalado no Windows ocupando a 3306, pare-o antes.

Você também pode abrir o arquivo com `notepad .env` e preencher os dados. Para criá-lo pelo terminal, use o bloco abaixo (troque `IP_PUBLICO` e `SENHA_MONTECH`; na opção **B**, use `DB_HOST=127.0.0.1`):

```powershell
@'
DB_HOST=IP_PUBLICO
DB_USER=montech
DB_PASSWORD=SENHA_MONTECH
DB_NAME=montech
'@ | Set-Content -Path .env -Encoding ascii
```

Confira (a senha aparece mascarada):

```powershell
(Get-Content .env) -replace '(?<=^DB_PASSWORD=).*', '***'
```

> Use uma senha só com caracteres ASCII, sem espaços, aspas, `#` ou a sequência `${`: o `.env` não as interpreta corretamente. Sem espaços ao redor do `=`.

---

### 4. Configurar as credenciais da AWS

Antes, limpe variáveis `AWS_*` que possam estar sobrescrevendo o arquivo (causa comum de `InvalidToken`):

```powershell
Get-ChildItem Env:AWS*
Remove-Item Env:AWS_ACCESS_KEY_ID, Env:AWS_SECRET_ACCESS_KEY, Env:AWS_SESSION_TOKEN, Env:AWS_PROFILE -ErrorAction SilentlyContinue
```

Crie o arquivo de credenciais:

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.aws" | Out-Null
notepad "$env:USERPROFILE\.aws\credentials"
```

Cole o seguinte conteúdo (os 3 valores inteiros, sem espaços nem quebras de linha) e salve:

```
[default]
aws_access_key_id=COLE_ACCESS_KEY
aws_secret_access_key=COLE_SECRET_KEY
aws_session_token=COLE_SESSION_TOKEN
```

Confira se o arquivo ficou com as 4 linhas (valores mascarados):

```powershell
(Get-Content "$env:USERPROFILE\.aws\credentials") -replace '(?<==).+', '***'
```

> As credenciais do laboratório são temporárias. Use a validade informada pelo lab e renove o conjunto completo quando necessário. Salve o arquivo como `credentials`, sem extensão `.txt`.

Valide o acesso antes de iniciar a captura:

```powershell
aws --version
aws configure set region us-east-1
aws sts get-caller-identity --region us-east-1
aws s3 ls s3://SEU_BUCKET/ --region us-east-1
```

Troque `SEU_BUCKET` pelo nome real. `get-caller-identity` valida a identidade; a listagem valida o acesso ao bucket. Se o CLI não for reconhecido, instale o AWS CLI v2 e reabra o PowerShell. Credenciais corretas no CLI não garantem que um launcher com arquivos próprios esteja usando as mesmas credenciais; veja a manutenção.

---

### 5. Executar o Coletor

No mesmo terminal onde você rodou as validações (com o `(venv)` ativo):

```powershell
python -m py_compile Script_Extracao.py Organizador.py
python Script_Extracao.py
```

Faça login com o e-mail e a senha do sistema e informe o token do servidor. Na versão final, as medições são programadas a cada aproximadamente **10 segundos entre inícios de coleta**, sujeito ao tempo das métricas, rede e MySQL. Confira no código `intervaloColetaSegundos = 10` e a função de espera que usa `proximaColeta`. O fechamento do CSV é uma configuração separada: mantivemos `intervaloCSVSegundos = 5`, verificada apenas ao coletar. Com medições a cada 10 segundos, normalmente há um CSV por coleta; o arquivo anterior é enviado na coleta seguinte. Portanto, 5 segundos nessa variável não significam envio exato a cada 5 segundos.

Ao apertar `Ctrl+C`, o coletor envia o que estiver pendente e encerra. Deve aparecer `CSV enviado para s3://...`.

---
### 💻 PARTE 3.2: Coletor de Métricas (Linux/Ubuntu)
---

No seu computador local simulando os servidores (**Terminal**):

1. Criar o script de instalação do Script de Captura (instalar-captura.sh):
```bash
nano ~/instalar-captura.sh
```
Colar o script `instalar-captura.sh`.

2. Executar o script:
```bash
chmod +x ~/instalar-captura.sh
~/instalar-captura.sh
```
Nota: informe o bucket gerado na sua conta, região `us-east-1`, IP público da sua EC2, usuário do banco `montech`, database `montech`, a senha escolhida e suas credenciais AWS atuais.

O instalador pode conter cópias antigas dos scripts Python embutidas. Antes de executá-lo, coloque os arquivos finais `Script_Extracao.py` e `Organizador.py` junto ao instalador se essa versão priorizar os arquivos vizinhos. Após a instalação, confira os arquivos efetivamente usados pelo launcher. Se forem antigos, substitua-os pelas versões finais antes de coletar. O `.sh` não foi alterado neste trabalho; sua cópia embutida não se atualiza ao editar outro repositório.

3. Rodando o Script de Captura:
```bash
tmux new -s montech
```
Esse comando serve para criar uma sessão persistente, onde ele funcionará mesmo depois de desconectar do SSH

4. Com ele você entrará numa sessão onde deve rodar:
```bash
montech-coletor/iniciar_coleta.sh
```
Nota: informe e-mail e senha de um usuário cadastrado no SQL que você importou e um token de servidor válido desse banco. Para parar a captura use `Ctrl+C`. Para deixar a sessão tmux rodando e voltar ao terminal, pressione `Ctrl+B` e depois `D`. 

5. Extras:
```bash
tmux attach -t montech
```
É utilizado para voltar para uma sessão que foi aberta e não foi finalizada

---

## Parte 4: Dependências e função AWS Lambda

### 4.1 Arquitetura e arquivos

A captura envia CSVs para `01-bronze/`. Um evento S3 chama o Lambda, que lê o CSV recebido, incorpora as linhas à Silver diária e gera a Gold por hora. A EC2 não precisa executar `etl_1.py` nem agendar cron para esse fluxo.

Estrutura dentro de um único bucket:

```text
01-bronze/ID_EMPRESA/ID_AEROPORTO/TOKEN/AAAA-MM-DD/arquivo.csv
02-silver/ID_EMPRESA/ID_AEROPORTO/TOKEN/AAAA-MM-DD/TOKEN-AAAA-MM-DD.csv
03-gold/ID_EMPRESA/ID_AEROPORTO/TOKEN/AAAA-MM-DD/TOKEN-AAAA-MM-DD.json
```

No S3, as “pastas” são prefixos: gravar o objeto cria o caminho necessário. O Organizador continua ajudando a captura a resolver IDs e pastas locais. A função Lambda monta os caminhos a partir da chave S3 e não importa o Organizador nem exige `.env` de banco.

### 4.2 Construir a layer de pandas e NumPy — terminal da EC2

O runtime da função será Python 3.14 x86_64. A layer precisa ser compatível com esse Python e com Linux; não compacte as bibliotecas instaladas no Windows.

```bash
sudo apt update
sudo apt install -y docker.io zip
sudo systemctl enable --now docker
docker --version
uname -m
mkdir -p ~/montech-lambda-layer/python
cd ~/montech-lambda-layer
```

- `apt`: instala Docker e o compactador.
- `systemctl`: inicia o Docker e habilita sua inicialização.
- `uname -m`: deve mostrar `x86_64` nesta implantação.
- `mkdir` e `cd`: criam e acessam uma pasta exclusiva para montar a layer.

Em uma pasta `python/` nova, instale as versões usadas na validação:

```bash
sudo docker run --rm \
  --platform linux/amd64 \
  --entrypoint /bin/sh \
  -v "$HOME/montech-lambda-layer:/var/task" \
  public.ecr.aws/lambda/python:3.14 \
  -c 'python -m pip install --only-binary=:all: pandas==3.1.1 numpy==2.5.4 -t /var/task/python'
```

O container é temporário (`--rm`); os pacotes permanecem na pasta montada (`-v`). A imagem é a oficial do Lambda. Se reconstruir a layer, use outra pasta vazia para não misturar versões. Se essas versões não estiverem disponíveis, registre e valide as substitutas antes de seguir; não mude somente o runtime da função.

Valide as importações no mesmo ambiente:

```bash
sudo docker run --rm \
  --platform linux/amd64 \
  --entrypoint /bin/sh \
  -v "$HOME/montech-lambda-layer:/var/task" \
  public.ecr.aws/lambda/python:3.14 \
  -c 'PYTHONPATH=/var/task/python python -c "import pandas, numpy; print(\"pandas:\", pandas.__version__); print(\"numpy:\", numpy.__version__)"'
```

Compacte e envie ao seu bucket:

```bash
cd ~/montech-lambda-layer
zip -qr montech-pandas-py314.zip python
ls -lh montech-pandas-py314.zip
aws sts get-caller-identity --region us-east-1
aws s3 cp montech-pandas-py314.zip s3://SEU_BUCKET/dependencias/montech-pandas-py314.zip --region us-east-1
```

Troque `SEU_BUCKET`. O ZIP precisa ter `python/` na raiz. O arquivo da validação tinha aproximadamente 45 MB. O caminho `dependencias/` fica fora do gatilho.

### 4.3 Criar e anexar a layer — console AWS

Na região `us-east-1`:

1. Abra Lambda → Camadas/Layers → Criar uma camada.
2. Nome: `montech-pandas-py314`.
3. Selecione criar a partir de um arquivo no Amazon S3.
4. Informe `s3://SEU_BUCKET/dependencias/montech-pandas-py314.zip`, com seu bucket real.
5. Arquitetura compatível: `x86_64`; runtime compatível: Python 3.14.
6. Crie e anote a versão retornada.

### 4.4 Criar a função — console AWS

1. Lambda → Criar função → Criar do zero.
2. Nome: `Montech-lambda`.
3. Runtime/Tempo de execução: **Python 3.14**.
4. Arquitetura: **x86_64**; não ative ARM64, execução durável ou provedor EC2.
5. Em configurações adicionais, personalize o perfil/papel de execução e selecione **LabRole**, se for o papel autorizado no seu laboratório.
6. Crie a função.
7. Na aba Código, em Camadas, clique em Adicionar camada ou Editar; escolha a camada personalizada `montech-pandas-py314` e a versão criada. Confirme que a lista deixa de mostrar zero camadas.
8. Configurações do runtime: manipulador **`lambda_function.lambda_handler`**.
9. Configuração geral: memória **1024 MB**, timeout **2 minutos**.
10. Configuração → Detecção de recursão e simultaneidade → Simultaneidade → Editar: configure **simultaneidade reservada = 1**. Não é simultaneidade provisionada. Mantenha a detecção de loops recursivos ativada.

A execução serial evita que duas invocações dessa função leiam a mesma Silver e sobrescrevam as alterações uma da outra. Não execute outro escritor, como a ETL antiga, nos mesmos destinos. Não aumente essa simultaneidade sem implementar coordenação das gravações.

**Permissões:** o papel precisa de leitura em `01-bronze/`, leitura e gravação nos prefixos Silver/Gold selecionados e publicação de logs no CloudWatch. Acesso ao bucket para carga inicial/listagens exige `s3:ListBucket`; objetos exigem `s3:GetObject`/`s3:PutObject` conforme a operação. O console também adiciona a autorização para o S3 invocar a função ao criar o gatilho. Em lab, não presuma que é possível editar o LabRole: se uma ação for negada, confirme as permissões permitidas pelo laboratório. Não coloque chaves AWS pessoais no código ou nas variáveis do Lambda.

### 4.5 Publicar o código e configurar variáveis

Na aba Código, substitua o conteúdo de `lambda_function.py` pelo **arquivo final incremental do repositório Python** e clique em **Deploy**. O código completo deve conter `processar_servidor`, suporte a eventos `Records` e ao teste manual com `bucket`/`chave`, e permitir os dois pares de prefixos abaixo tanto na validação de entrada quanto em `salvar_resultados`.

Comece em Configuração → Variáveis de ambiente:

| Chave (literal; não renomear) | Valor inicial |
| --- | --- |
| `NOME_BUCKET` | Nome real do bucket gerado na sua conta |
| `PREFIXO_SILVER` | `testes-lambda/02-silver` |
| `PREFIXO_GOLD` | `testes-lambda/03-gold` |

`NOME_BUCKET` é o nome da variável; o nome do seu bucket vai no campo **Valor**. Prefixos não incluem `s3://` nem o nome do bucket.

A função final não precisa da layer de `psutil`, `mysql-connector-python` ou `python-dotenv`: essas dependências são da captura. O runtime fornece boto3; pandas/NumPy vêm da layer.

## Parte 5: Inicialização, gatilho e validação

### 5.1 Decidir entre ambiente novo e migração

**Ambiente novo, sem dados antigos:** configure e ative o gatilho antes da primeira captura. Não execute a ETL antiga. A primeira coleta cria sua Silver.

**Já existem CSVs na bronze:** configure a função, mas mantenha a captura parada e o gatilho ainda ausente/desativado. Faça a carga inicial abaixo antes de receber dados novos. Simplesmente ativar o Lambda não processa uploads antigos.

**Já existe cron da ETL antiga:** na EC2, rode `crontab -l`. Se houver linha com `etl_1.py` ou `run_etl.sh`, salve uma cópia com `crontab -l > ~/crontab-antes-lambda.txt`, abra `crontab -e` e comente somente a tarefa da ETL com `#`. Preserve as outras tarefas. Confira novamente com `crontab -l`. `no crontab for ubuntu` significa apenas que esse usuário não possui crontab; se a equipe agendou a ETL com outro usuário ou mecanismo, desative esse escritor também.

### 5.2 Carga inicial/reconstrução de histórico — somente quando necessária

A função incremental usa a Silver existente como base. Para montar uma base de teste a partir da bronze, reenvie cada caminho à função em sequência, sem alterar os objetos Bronze. Isso também permite retomar uma carga interrompida: eventos repetidos não devem duplicar linhas.

No PowerShell, na pasta do projeto Python, abra:

```powershell
notepad reconstruir_silver.py
```

Cole e salve:

```python
import json
import boto3
from botocore.config import Config

BUCKET = "SEU_BUCKET"
FUNCAO = "Montech-lambda"
REGIAO = "us-east-1"

s3 = boto3.client("s3", region_name=REGIAO)
lambda_aws = boto3.client(
    "lambda", region_name=REGIAO,
    config=Config(read_timeout=150, connect_timeout=10),
)

# Lista antes de começar; não depende de uma única página do S3.
chaves = []
for pagina in s3.get_paginator("list_objects_v2").paginate(
    Bucket=BUCKET, Prefix="01-bronze/"
):
    for objeto in pagina.get("Contents", []):
        if objeto["Key"].endswith(".csv"):
            chaves.append(objeto["Key"])

print(f"CSVs encontrados: {len(chaves)}")
for indice, chave in enumerate(sorted(chaves), start=1):
    resposta = lambda_aws.invoke(
        FunctionName=FUNCAO,
        InvocationType="RequestResponse",
        Payload=json.dumps({"bucket": BUCKET, "chave": chave}).encode("utf-8"),
    )
    corpo = resposta["Payload"]
    try:
        retorno = corpo.read().decode("utf-8")
    finally:
        corpo.close()
    if resposta.get("FunctionError"):
        raise RuntimeError(f"Falha em {chave}: {retorno}")
    print(f"{indice}/{len(chaves)}: {chave}")
```

Troque `SEU_BUCKET`, confirme o nome da função, ative o venv da captura e execute:

```powershell
python reconstruir_silver.py
```

O script requer `lambda:InvokeFunction` para a identidade local, além de listagem da bronze. O cliente usa timeout de leitura de 150 segundos, maior que os 120 segundos configurados na função. Se o laboratório negar invocação pela API, não prossiga com uma Silver incompleta: use uma identidade autorizada ou o fluxo de invocação permitido no lab.

Esta recuperação incorpora os registros à base existente. **Não remove dados antigos ou corrige CSVs sobrescritos**; reconstrução exata após exclusão/correção de fontes exige um novo par de prefixos autorizado no código e uma base vazia. Não apague Silver em uso. Mantenha a captura e o gatilho parados durante a carga inicial e a troca dos destinos.

Na validação deste projeto, uma reconstrução com a versão anterior completa também foi usada para preparar a base. Para novas contas, o replay acima usa a versão final e não depende do limite antigo de 500 arquivos.

### 5.3 Teste manual — console AWS

Liste os caminhos reais no PowerShell ou na EC2:

```bash
aws s3 ls s3://SEU_BUCKET/01-bronze/ --recursive --region us-east-1
```

Crie um evento privado na aba Testar. Substitua o bucket e a chave por um CSV existente, sem `s3://` no campo `chave`:

```json
{
  "bucket": "SEU_BUCKET",
  "chave": "01-bronze/ID_EMPRESA/ID_AEROPORTO/TOKEN/AAAA-MM-DD/ARQUIVO.csv"
}
```

Salve e execute. Espere `modo: incremental_por_dia`, `arquivos_bronze_lidos: 1` e o total consolidado em `resultados_por_dia`. Repita o mesmo evento: a quantidade de coletas deve permanecer igual. O número de linhas recebidas no evento é diferente do total acumulado na Silver.

Para testar o formato S3, crie outro evento, substituindo os mesmos valores:

```json
{
  "Records": [
    {
      "eventSource": "aws:s3",
      "eventName": "ObjectCreated:Put",
      "s3": {
        "bucket": {"name": "SEU_BUCKET"},
        "object": {
          "key": "01-bronze/ID_EMPRESA/ID_AEROPORTO/TOKEN/AAAA-MM-DD/ARQUIVO.csv"
        }
      }
    }
  ]
}
```

Espere `arquivos_processados: 1`. Vários arquivos do mesmo servidor no mesmo evento devem ser incorporados individualmente; a deduplicação do handler inclui a chave do objeto.

### 5.4 Conectar o gatilho real — console AWS

Na função → Adicionar gatilho → S3:

| Campo | Valor |
| --- | --- |
| Bucket | Seu bucket na região `us-east-1` |
| Tipos de evento | Todos os eventos de criação de objeto |
| Prefixo | `01-bronze/` |
| Sufixo | `.csv` |

Confira os filtros, marque o reconhecimento do aviso de invocação recursiva e clique em Adicionar. Não deixe o prefixo vazio: a função escreve no mesmo bucket e suas saídas precisam ficar fora do gatilho. O gatilho não executa automaticamente os CSVs que já existiam antes de sua criação.

### 5.5 Teste automático nas pastas de teste

Sem clicar em Testar e sem executar `etl_1.py`:

1. Inicie a captura no computador local.
2. Deixe aproximadamente 35 segundos.
3. Encerre com `Ctrl+C` para enviar o arquivo final.
4. Anote quantas coletas e uploads foram concluídos.
5. Confira CloudWatch em Lambda → Monitor → logs, e o JSON de saída.

```bash
aws s3 ls s3://SEU_BUCKET/testes-lambda/03-gold/ --recursive --region us-east-1
aws s3 cp "s3://SEU_BUCKET/testes-lambda/03-gold/ID_EMPRESA/ID_AEROPORTO/TOKEN/AAAA-MM-DD/TOKEN-AAAA-MM-DD.json" - --region us-east-1
```

Troque todos os identificadores. A quantidade de coletas por hora deve aumentar pelo número de linhas novas válidas, sem repetir as antigas. Se houver mais de uma hora, some `Qtd_Coletas` dos objetos do dia. Aguarde o processamento dos eventos e consulte novamente se o último upload acabou de terminar.

Logs por CLI, quando a identidade tiver permissão:

```bash
aws logs tail /aws/lambda/Montech-lambda --since 10m --region us-east-1
```

### 5.6 Ativar os destinos definitivos

Com a captura parada e as execuções pendentes concluídas:

1. Confira a base completa de teste e os resultados dos testes.
2. Na primeira migração, copie a Silver validada para o prefixo definitivo, usando a mesma estrutura de IDs/token/data. O comando abaixo copia todas as Silvers de teste; use apenas na inicialização planejada, depois de comparar a base, pois substitui objetos de mesmo nome no destino.

```bash
aws s3 cp s3://SEU_BUCKET/testes-lambda/02-silver/ s3://SEU_BUCKET/02-silver/ --recursive --region us-east-1
```

3. Em Variáveis de ambiente, mantenha `NOME_BUCKET` e altere `PREFIXO_SILVER=02-silver` e `PREFIXO_GOLD=03-gold`. O código final precisa aceitar esse par também; alterar apenas as variáveis em uma versão que bloqueia produção gera erro.
4. Execute uma vez o replay da seção 5.2 com esses destinos para regenerar a Gold definitiva de todos os dias a partir da base validada. Para verificar só um dia afetado, o evento manual pode apontar para um arquivo daquele dia.
5. Confira os caminhos `02-silver/` e `03-gold/` nos logs.
6. Reative o gatilho se ele foi desativado e teste novos uploads reais, sem invocação manual. Confira o aumento esperado das coletas na Gold definitiva.

A cópia de Silver e as saídas Gold não acionam o gatilho restrito à bronze. Não use `sync --delete` nesta migração. Depois da troca, a pasta `testes-lambda/` fica como resultado de validação; não continua se atualizando automaticamente.

**Não crie um cron para o Lambda.** A chegada dos CSVs aciona a função. A EC2/MySQL permanece necessária para o cadastro e acesso da captura, mas não para executar essa ETL.

### 5.7 Evidências obtidas na validação

- Gold da ETL original e da primeira versão Lambda coincidiram para 345 coletas em duas horas do dia 01/11/2026.
- Depois foi corrigido o tratamento de lacunas: deltas entre leituras separadas por mais de 30 segundos são descartados.
- Captura ajustada e observada com aproximadamente 10 segundos entre coletas.
- A versão incremental leu 1 CSV Bronze e preservou 12 coletas ao repetir um arquivo existente.
- Novos uploads aumentaram a Gold de teste de 12 para 15 coletas.
- Após a migração, novos uploads aumentaram a Gold definitiva de 15 para 18 coletas.
- Repetição, chegada atrasada, mudança de dia e lacuna longa foram simuladas localmente. O teste real na AWS cobriu um servidor e volume pequeno; não constitui teste de carga ou garantia de escala.

## Parte 6: Regras, manutenção e solução de erros

### Regras da versão incremental

- Conserva as colunas originais para recalcular deltas; descarta flags/deltas anteriores antes de unir os dados.
- Exige as métricas conhecidas de `COLUNAS_NUMERICAS`. Mudança de schema exige atualização coordenada do código e da base.
- Deduplica linhas originais iguais. Valores conflitantes no mesmo timestamp geram erro; não há resolução automática.
- Ordena por timestamp. Calcula deltas entre leituras com intervalo maior que zero e até 30 segundos. Primeira leitura, contador decrescente ou lacuna maior recebem zero; zero nesses casos representa falta de delta confiável e pode subestimar totais.
- Usa a última leitura do dia anterior como contexto; uma chegada atrasada pode recalcular também o dia seguinte já existente.
- Flags IQR são diárias. Essa regra difere das flags calculadas sobre todo o histórico pela implementação anterior; não removem linhas por serem outliers.
- Gold continua agregada por hora, com média/máximo das métricas, soma dos deltas e quantidade de coletas. Atualização a cada upload não significa resolução de 10 segundos na Gold: a Silver mantém as leituras individuais.
- Timestamps atuais são sem fuso explícito. A função não converte UTC/São Paulo. Mantenha os relógios dos coletores alinhados; `Hora` no JSON representa o horário recebido e não informa offset.
- A captura valida acesso/cadastro no MySQL. O Lambda confia nos IDs/token do caminho e confere `IdAeroporto` no CSV; não valida no banco a associação completa token/empresa/aeroporto.
- Bronze deve ser imutável após o envio: use nomes novos para novas coletas. Correção, sobrescrita ou exclusão de fontes não remove automaticamente linhas da Silver.
- A função não relê todo o histórico nem usa o limite antigo de 500 CSVs. Ainda lê e regrava a Silver diária dos dias envolvidos. O custo e a duração crescem com o volume diário; monitore antes de ampliar servidores/frequência.
- As gravações Silver/Gold não são uma transação. Um erro pode deixar Gold temporariamente defasada; repetir o evento deve reconstruí-la. A entrega do S3 pode repetir eventos e não garante ordem.
- Simultaneidade reservada 1 é necessária nesta versão, mas não garante que o processamento acompanhe qualquer taxa de uploads. Monitore erros, throttling, duração e atraso; filas/retenção de falhas e coordenação por servidor são evoluções futuras, não recursos já implantados.
- Arquivos pendentes da captura ficam em memória e no disco local; reiniciar o processo não descobre automaticamente todos os CSVs antigos não enviados. Confira falhas de upload e faça reenvio controlado ao mesmo destino.

### Renovar credenciais no Windows — PowerShell

```powershell
notepad "$env:USERPROFILE\.aws\credentials"
```

Substitua os três valores da sessão e salve, preservando `[default]`:

```ini
[default]
aws_access_key_id=ACCESS_KEY_ATUAL
aws_secret_access_key=SECRET_KEY_ATUAL
aws_session_token=SESSION_TOKEN_ATUAL
```

```powershell
aws sts get-caller-identity --region us-east-1
```

O arquivo se chama `credentials`, sem `.txt`. Não cole credenciais no chat, no README ou em commits. Se o CLI funcionar e Python não, confira configurações AWS no processo/launcher, incluindo `AWS_SHARED_CREDENTIALS_FILE` e `AWS_CONFIG_FILE`, e reinicie a captura depois da renovação.

### Renovar credenciais na EC2 — Bash

```bash
mkdir -p ~/.aws
nano ~/.aws/credentials
chmod 600 ~/.aws/credentials
aws sts get-caller-identity --region us-east-1
```

Use o mesmo formato do bloco acima. Não rode novamente o criador de Data Lake só para renovar credenciais. Se o coletor Linux usa arquivos isolados em sua própria pasta, renove os arquivos que o launcher aponta; use a opção `--credenciais` do instalador somente se ela estiver presente nessa versão. Credenciais salvas no Windows não se propagam para a EC2. O Lambda utiliza o papel de execução; não recebe automaticamente essas credenciais locais.

### Erros comuns

| Mensagem/sintoma | Verificação e ação |
| --- | --- |
| `aws` não reconhecido | Instale AWS CLI, reabra o terminal e confira `aws --version`. |
| `NoCredentials` | Confira nome/local do arquivo, perfil e variáveis AWS do processo. |
| `InvalidToken` / token expirado | Renove o trio inteiro da mesma sessão; confira valores que sobrescrevem o arquivo. |
| `No module named pandas` no Lambda | Crie e anexe a layer; confirme Python 3.14 e x86_64 tanto na função quanto na layer. |
| Erro de binário/import NumPy | Refaça em pasta vazia usando a imagem oficial do Lambda; não use pacotes do Windows. |
| `AccessDenied` | Verifique identidade local, permissões do papel Lambda e bucket da conta correta; permissões são distintas para cada ambiente. |
| 404 / `Not Found` ao ler Gold | Confira bucket, prefixo de teste/definitivo, IDs, token, data e nome exato; uma pasta vazia não é um JSON. |
| Upload concluiu, Gold não mudou | Confira gatilho, prefixo/sufixo, logs, variáveis e base Silver. Não conclua sucesso apenas pela mensagem de upload. |
| Falta de conexão MySQL | Confira EC2/container, Security Group para seu IP público, `.env`, usuário/senha, SQL e eventual túnel SSH. |
| `DB_HOST` | É IP/hostname; 3306 é a porta, não o host. |
| Limite de 500 arquivos | Versão antiga ainda implantada; confira código final incremental e Deploy. |
| Gold com total menor após migração | A base Silver usada na troca estava incompleta; pare novos escritores e reconstrua em destino controlado a partir da bronze. |
| `Coletas conflitantes no mesmo timestamp` | Investigue dois produtores com mesmo token, relógio/reinício ou fonte alterada; não remova a validação para esconder o conflito. |

### Versionamento e entrega

O repositório dos `.sh` deve receber este README atualizado. O repositório Python deve receber o código final salvo em `lambda_function.py`, a captura atualizada e as demais mudanças revisadas. Se forem repositórios diferentes, faça commits separados e indique no guia qual revisão do Python usar.

Confira antes de adicionar arquivos:

```powershell
git status --short
git diff -- Script_Extracao.py etl_1.py .gitignore
python -m py_compile Script_Extracao.py Organizador.py lambda_function.py
```

`py_compile` verifica sintaxe, não executa a função nem valida dependências da layer. A mudança em `etl_1.py` pode ser apenas o bucket para comparação; revise se deve entrar na entrega. Ele não é o executor principal após a migração.

Inclua no `.gitignore`, conforme o repositório:

```gitignore
.env
.env.*
.aws/
venv/
.venv/
__pycache__/
/bronze/**/*.csv
```

Preserve arquivos de exemplo, quando usados, com exceções explícitas como `!.env.example`. Regras de ignore não removem arquivos já rastreados. Não use `git add .` sem revisar a lista.

Exemplos de mensagens com prefixo:

```text
feat: implementar ETL incremental com AWS Lambda e gatilho S3
```

```text
docs: atualizar guia de implantação para AWS Lambda
```

## Referências oficiais

- [Layers Python: versão, estrutura e compatibilidade](https://docs.aws.amazon.com/lambda/latest/dg/python-layers.html)
- [Eventos S3 com Lambda e prevenção de recursão](https://docs.aws.amazon.com/lambda/latest/dg/with-s3.html)
- [Estrutura do evento S3 e codificação da chave](https://docs.aws.amazon.com/AmazonS3/latest/userguide/notification-content-structure.html)
- [Simultaneidade reservada](https://docs.aws.amazon.com/lambda/latest/dg/configuration-concurrency.html)
