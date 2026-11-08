# Guia de Implantação MonTech

Passo a passo automatizado e consolidado para implantação da infraestrutura: VM EC2 (Ubuntu), MySQL no Docker, Coletor de Métricas no Windows/Linux e ETL incremental no AWS Lambda, acionada por upload no S3.

## 📋 Visão Geral do Ambiente

| Seção | Ambiente | O que faz |
| ----- | ----- | ----- |
| **1** | Console AWS | Configuração do IP Elástico (IP fixo) da EC2 |
| **2** | VM (SSH) | Provisionamento e auditoria de usuários (`config-acesso-ec2.sh`) |
| **3** | VM (SSH) | Preparação do ambiente e criação do Data Lake S3 (`configurar-ambiente-datalake.sh`) |
| **4** | VM (SSH) | Instalação do Docker e subida do container MySQL |
| **5** | Console AWS | Segurança da porta 3306 (MySQL) no Security Group |
| **6** | Windows / Linux | Coletor de métricas enviando CSV para o Data Lake |
| **6.1** | Windows (PowerShell) | Coletor de métricas no Windows |
| **6.2** | Linux (Bash) | Coletor de métricas no Linux |
| **7** | VM + console AWS | Construção da layer e criação da função Lambda |
| **8** | Console AWS + computador local | Carga inicial, gatilho S3, testes e ativação definitiva |
| **9** | VM / Windows | Regras, manutenção (renovação de credenciais), solução de erros e entrega |
| **10** | Web | Referências oficiais |

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

Crie uma EC2 Ubuntu x86_64 em `us-east-1`, aguarde o estado executando e use o usuário `ubuntu`. Os comandos Bash abaixo são executados nela, salvo indicação de outro ambiente. Para SSH, libere TCP 22 para seu IP público. No Windows, instale Python e AWS CLI v2 antes da seção 6.1; valide `python --version` e `aws --version`. O instalador oficial do AWS CLI está em https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html.

## 🌐 1. Configuração do IP Elástico (IP Fixo)

Por padrão, o IP público de uma instância EC2 muda sempre que ela é parada e iniciada novamente. Para manter um endereço fixo associe um **IP Elástico** à instância.

### 1.1 Acessar o console da AWS

- Entre em **EC2** → no menu lateral, em **Rede e segurança**, clique em **IPs elásticos** (*Elastic IPs*).

### 1.2 Alocar um novo endereço

- Clique em **Alocar endereço IP elástico** (*Allocate Elastic IP address*).
- Em *Grupo de bordas de rede*, mantenha a região padrão e em *Pool de endereços IPv4* deixe **Pool de endereços IPv4 da Amazon**.
- Clique em **Alocar**.

### 1.3 Associar o IP à instância

- Selecione o IP recém-criado → **Ações** → **Associar endereço IP elástico**.
- Em *Tipo de recurso*, escolha **Instância**.
- Selecione a instância EC2 do projeto.
- Em *Endereço IP privado*, escolha o IP privado listado para a instância.
- Clique em **Associar**.

### 1.4 Conferir a associação

- Em **Instâncias**, abra a instância e verifique se o campo **Endereço IPv4 público** agora mostra o IP elástico.
- A partir daqui, use **este IP** no lugar de `IP_PUBLICO` nos comandos de SSH.

### 1.5 Liberar a porta no Security Group (se ainda não estiver)

- Na instância, aba **Segurança** → clique no *Security Group* → **Editar regras de entrada**.
- Garanta uma regra **SSH (TCP 22)** para o seu IP (ou para o IP da equipe).

### 1.6 Testar o acesso com o novo IP

```bash
ssh -i "CAMINHO_DA_CHAVE.pem" ubuntu@IP_ELASTICO
```

> ⚠️ **Atenção:** o IP Elástico é gratuito **somente enquanto estiver associado a uma instância em execução**. Se ele ficar alocado sem uso (ou a instância estiver parada), a AWS cobra por hora. Se for desativar o ambiente, vá em **Ações** → **Desassociar endereço IP elástico** e depois **Liberar endereços IP elásticos** (*Release*).

---

## 🛠️ 2. Acesso e Política de Usuários

Conecte-se à VM EC2 via SSH e crie os usuários da equipe de forma automatizada.

### 2.1 Mudar permissão da chave

Linux, macOS ou WSL; não execute `chmod` no PowerShell.
```bash
chmod 400 "CAMINHO_DA_CHAVE.pem"
```

### 2.2 Conectar na VM (o comando SSH também funciona no PowerShell)

```bash
ssh -i "CAMINHO_DA_CHAVE.pem" ubuntu@IP_PUBLICO
```

### 2.3 Criar o script de acesso (`config-acesso-ec2.sh`)

```bash
nano ~/config-acesso-ec2.sh
```
*(Cole o conteúdo do seu script `config-acesso-ec2.sh`, salve com `Ctrl+O`, `Enter` e saia com `Ctrl+X`)*.

### 2.4 Rodar com privilégios de root

```bash
sudo chmod +x ~/config-acesso-ec2.sh
sudo ~/config-acesso-ec2.sh
```

### 2.5 Conferir se os usuários foram criados corretamente

```bash
getent passwd guilherme thiago lucas vinicius nicole montech | cut -d: -f1
```

---

## ☁️ 3. AWS CLI e Buckets (Data Lake)

O script abaixo já instala dependências (Python, OpenJDK 21), configura o AWS CLI e cria toda a estrutura do S3.

### 3.1 Criar o script de configuração do ambiente e Data Lake (`configurar-ambiente-datalake.sh`)

```bash
nano ~/configurar-ambiente-datalake.sh
```
*(Cole o conteúdo do seu script `configurar-ambiente-datalake.sh`, salve e feche)*.

### 3.2 Executar o script

```bash
chmod +x ~/configurar-ambiente-datalake.sh
~/configurar-ambiente-datalake.sh
```
*Nota: O script solicitará suas credenciais da AWS (`Access Key`, `Secret Key`, `Session Token`) e a região. Digite exatamente `us-east-1`.*

### 3.3 Conferir e anotar o nome do bucket gerado

Não execute o script novamente apenas para renovar credenciais, pois ele cria outro bucket.
```bash
aws sts get-caller-identity
aws s3 ls | grep montech-datalake
```

---

## 🐳 4. Docker e MySQL

### 4.1 Instalar o Docker

```bash
sudo apt install -y docker.io
sudo systemctl enable --now docker
sudo docker ps
```

### 4.2 Criar o arquivo de variáveis de ambiente do MySQL

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

### 4.3 Subir o container MySQL

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

### 4.4 Popular o banco de dados (`montech.sql`)

```bash
nano ~/montech.sql
```
*(Cole o script SQL com as tabelas e inserts, salve e feche).*

### 4.5 Importar e testar

```bash
sudo docker exec -i montech-mysql \
  sh -c 'mysql -u root -p"$MYSQL_ROOT_PASSWORD" montech' < ~/montech.sql

sudo docker exec -it montech-mysql \
  sh -c 'mysql -u montech -p"$MYSQL_PASSWORD" montech -e "SHOW TABLES;"'
```

---

## 🔐 5. Segurança na porta MySQL na AWS

Como a porta **3306** estará publicada nas interfaces de rede da VM, restrinja o acesso usando a **Security Group da VM** que hospeda o MySQL.

* Na tela de **Instâncias**, selecione a VM que está o MySQL no container Docker.
* Selecione a opção **"Segurança"**.
* Em **"Regras de entrada"** clique no **"Grupo de segurança"** que vai estar em azul.
* Clique no **"ID do grupo de segurança"** que vai estar em azul também.
* Agora clique em **"Editar regras de entrada"**.
* Clique em **"Adicionar regra"**.
* Preencha no **Tipo** com **MYSQL/Aurora**.
* **Intervalo de portas** coloque **3306**.
* Em **Origem** coloque o IP publico da máquina que deseja acessar o banco e **"/32"** no final (use seu IP público real seguido de /32; nunca 127.0.0.1, que é loopback) ou use 0.0.0.0/0.
* Clique em **"Salvar regras"** e pronto!

---

## 💻 6. Coletor de Métricas

Escolha a seção conforme o sistema operacional do computador que simula os servidores: se for Windows, siga a seção 6.1; se for Linux, siga a seção 6.2.

### 6.1 Coletor de Métricas (Windows)

No seu computador local simulando os servidores (**PowerShell**, dentro da pasta do projeto, onde estão o `Script_Extracao.py` e o `Organizador.py`).

Esta parte faz, na mão, o mesmo que o `instalar-coletor.sh` faz no Linux: prepara o Python, configura o bucket, o banco e as credenciais AWS, e **valida tudo antes de coletar**.

> **Antes de começar, tenha em mãos:** o nome do bucket (`montech-datalake-XXXX`), o IP público da EC2, a senha do usuário `montech` do MySQL e as 3 credenciais da AWS (Access Key, Secret Key e Session Token, todas da **mesma sessão** do laboratório).

---

#### 6.1.1 Criar o ambiente virtual e instalar as dependências

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

#### 6.1.2 Configurar o bucket e a região no código

Abra com `notepad Script_Extracao.py` (ou, de preferência no VS Code: `code Script_Extracao.py`; no Bloco de Notas, use `Ctrl+F` e procure `NOME_BUCKET`):

- Procure `NOME_BUCKET` e troque o nome pelo do seu bucket: `NOME_BUCKET = "montech-datalake-XXXX"`
- Procure `REGIAO_AWS` e confira a região: `REGIAO_AWS = "us-east-1"` (nunca `us-east-1d`, que é zona de disponibilidade)

Salve o arquivo em **UTF-8** e confirme que as duas linhas ficaram certas:

```powershell
Select-String -Path Script_Extracao.py -Pattern '^(NOME_BUCKET|REGIAO_AWS) ='
```

---

#### 6.1.3 Acesso ao MySQL e arquivo `.env`

Conexão direta — quando o container do MySQL publica a porta (`-p 3306:3306`) e o Security Group da EC2 libera **TCP 3306** para o seu IP público.

Descubra o seu IP público (é ele que vai no Security Group, no formato `IP/32`; não use o `192.168.x.x`):

```powershell
(Invoke-RestMethod https://checkip.amazonaws.com).Trim()
```

Teste a rede (deve mostrar `TcpTestSucceeded : True`):

```powershell
Test-NetConnection IP_PUBLICO -Port 3306
```
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

#### 6.1.4 Configurar as credenciais da AWS

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

Troque `SEU_BUCKET` pelo nome real. `get-caller-identity` valida a identidade; a listagem valida o acesso ao bucket. Se o CLI não for reconhecido, instale o AWS CLI v2 e reabra o PowerShell.

---

#### 6.1.5 Executar o Coletor

No mesmo terminal onde você rodou as validações (com o `(venv)` ativo):

```powershell
python -m py_compile Script_Extracao.py Organizador.py
python Script_Extracao.py
```

Faça login com o e-mail e a senha do sistema e informe o token do servidor. Na versão final, as medições são programadas a cada aproximadamente **10 segundos entre inícios de coleta**, sujeito ao tempo das métricas, rede e MySQL. Confira no código `intervaloColetaSegundos = 10` e a função de espera que usa `proximaColeta`. O fechamento do CSV é uma configuração separada: mantivemos `intervaloCSVSegundos = 5`, verificada apenas ao coletar.

Ao apertar `Ctrl+C`, o coletor envia o que estiver pendente e encerra. Deve aparecer `CSV enviado para s3://...`.

---

### 6.2 Coletor de Métricas (Linux/Ubuntu)

No seu computador local simulando os servidores (**Terminal**):

#### 6.2.1 Criar o script de instalação do Script de Captura (`instalar-captura.sh`)

```bash
nano ~/instalar-captura.sh
```
Colar o script `instalar-captura.sh`.

#### 6.2.2 Executar o script

```bash
chmod +x ~/instalar-captura.sh
~/instalar-captura.sh
```
Nota: informe o bucket gerado na sua conta, região `us-east-1`, IP público da sua EC2, usuário do banco `montech`, database `montech`, a senha escolhida e suas credenciais AWS atuais.

#### 6.2.3 Criar a sessão tmux para o Script de Captura

```bash
tmux new -s montech
```
Esse comando serve para criar uma sessão persistente, onde ele funcionará mesmo depois de desconectar do SSH

#### 6.2.4 Rodar o coletor dentro da sessão

Com o `tmux` você entrará numa sessão onde deve rodar:

```bash
montech-coletor/iniciar_coleta.sh
```
Nota: informe e-mail e senha de um usuário cadastrado no SQL que você importou e um token de servidor válido desse banco. Para parar a captura use `Ctrl+C`. Para deixar a sessão tmux rodando e voltar ao terminal, pressione `Ctrl+B` e depois `D`. 

#### 6.2.5 Extras

```bash
tmux attach -t montech
```
É utilizado para voltar para uma sessão que foi aberta e não foi finalizada

---

## 7. Dependências e função AWS Lambda

### 7.1 Construir a layer de pandas e NumPy — terminal da EC2

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

Em uma pasta `python/` nova, instale as versões usadas na validação:

```bash
sudo docker run --rm \
  --platform linux/amd64 \
  --entrypoint /bin/sh \
  -v "$HOME/montech-lambda-layer:/var/task" \
  public.ecr.aws/lambda/python:3.14 \
  -c 'python -m pip install --only-binary=:all: pandas==3.1.1 numpy==2.5.4 -t /var/task/python'
```

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

### 7.2 Criar e anexar a layer — console AWS

Na região `us-east-1`:

- **7.2.1** Abra Lambda → Camadas/Layers → Criar uma camada.
- **7.2.2** Nome: `montech-pandas-py314`.
- **7.2.3** Selecione criar a partir de um arquivo no Amazon S3.
- **7.2.4** Informe `s3://SEU_BUCKET/dependencias/montech-pandas-py314.zip`, com seu bucket real.
- **7.2.5** Arquitetura compatível: `x86_64`; runtime compatível: Python 3.14.
- **7.2.6** Crie e anote a versão retornada.

### 7.3 Criar a função — console AWS

- **7.3.1** Lambda → Criar função → Criar do zero.
- **7.3.2** Nome: `Montech-lambda`.
- **7.3.3** Runtime/Tempo de execução: **Python 3.14**.
- **7.3.4** Arquitetura: **x86_64**; não ative ARM64, execução durável ou provedor EC2.
- **7.3.5** Em configurações adicionais, personalize o perfil/papel de execução e selecione **LabRole**, se for o papel autorizado no seu laboratório.
- **7.3.6** Crie a função.
- **7.3.7** Na aba Código, em Camadas, clique em Adicionar camada ou Editar; escolha a camada personalizada `montech-pandas-py314` e a versão criada. Confirme que a lista deixa de mostrar zero camadas.
- **7.3.8** Configurações do runtime: manipulador **`lambda_function.lambda_handler`**.
- **7.3.9** Configuração geral: memória **1024 MB**, timeout **2 minutos**.
- **7.3.10** Configuração → Detecção de recursão e simultaneidade → Simultaneidade → Editar: configure **simultaneidade reservada = 1**. Não é simultaneidade provisionada. Mantenha a detecção de loops recursivos ativada.


### 7.4 Publicar o código e configurar variáveis

Na aba Código, substitua o conteúdo de `lambda_function.py` pelo **arquivo final incremental do repositório Python** e clique em **Deploy**. O código completo deve conter `processar_servidor`, suporte a eventos `Records` e ao teste manual com `bucket`/`chave`, e permitir os dois pares de prefixos abaixo tanto na validação de entrada quanto em `salvar_resultados`.

Comece em Configuração → Variáveis de ambiente:

| Chave (literal; não renomear) | Valor inicial |
| --- | --- |
| `NOME_BUCKET` | Nome real do bucket gerado na sua conta |
| `PREFIXO_SILVER` | `testes-lambda/02-silver` |
| `PREFIXO_GOLD` | `testes-lambda/03-gold` |

A função final não precisa da layer de `psutil`, `mysql-connector-python` ou `python-dotenv`: essas dependências são da captura. O runtime fornece boto3; pandas/NumPy vêm da layer.

## 8. Inicialização, gatilho e validação

### 8.1 Decidir entre ambiente novo e migração

**Ambiente novo, sem dados antigos:** configure e ative o gatilho antes da primeira captura. Não execute a ETL antiga. A primeira coleta cria sua Silver.

**Já existem CSVs na bronze:** configure a função, mas mantenha a captura parada e o gatilho ainda ausente/desativado. Faça a carga inicial abaixo antes de receber dados novos. Simplesmente ativar o Lambda não processa uploads antigos.

### 8.2 Carga inicial/reconstrução de histórico — somente quando necessária

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

### 8.3 Teste manual — console AWS

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

### 8.4 Conectar o gatilho real — console AWS

Na função → Adicionar gatilho → S3:

| Campo | Valor |
| --- | --- |
| Bucket | Seu bucket na região `us-east-1` |
| Tipos de evento | Todos os eventos de criação de objeto |
| Prefixo | `01-bronze/` |
| Sufixo | `.csv` |

Confira os filtros, marque o reconhecimento do aviso de invocação recursiva e clique em Adicionar. Não deixe o prefixo vazio: a função escreve no mesmo bucket e suas saídas precisam ficar fora do gatilho. O gatilho não executa automaticamente os CSVs que já existiam antes de sua criação.

### 8.5 Teste automático nas pastas de teste

Sem clicar em Testar e sem executar `etl_1.py`:

- **8.5.1** Inicie a captura no computador local.
- **8.5.2** Deixe aproximadamente 35 segundos.
- **8.5.3** Encerre com `Ctrl+C` para enviar o arquivo final.
- **8.5.4** Anote quantas coletas e uploads foram concluídos.
- **8.5.5** Confira CloudWatch em Lambda → Monitor → logs, e o JSON de saída.

```bash
aws s3 ls s3://SEU_BUCKET/testes-lambda/03-gold/ --recursive --region us-east-1
aws s3 cp "s3://SEU_BUCKET/testes-lambda/03-gold/ID_EMPRESA/ID_AEROPORTO/TOKEN/AAAA-MM-DD/TOKEN-AAAA-MM-DD.json" - --region us-east-1
```

Troque todos os identificadores. A quantidade de coletas por hora deve aumentar pelo número de linhas novas válidas, sem repetir as antigas. Se houver mais de uma hora, some `Qtd_Coletas` dos objetos do dia. Aguarde o processamento dos eventos e consulte novamente se o último upload acabou de terminar.

Logs por CLI, quando a identidade tiver permissão:

```bash
aws logs tail /aws/lambda/Montech-lambda --since 10m --region us-east-1
```

### 8.6 Ativar os destinos definitivos

Com a captura parada e as execuções pendentes concluídas:

- **8.6.1** Confira a base completa de teste e os resultados dos testes.
- **8.6.2** Na primeira migração, copie a Silver validada para o prefixo definitivo, usando a mesma estrutura de IDs/token/data. O comando abaixo copia todas as Silvers de teste; use apenas na inicialização planejada, depois de comparar a base, pois substitui objetos de mesmo nome no destino.

  ```bash
  aws s3 cp s3://SEU_BUCKET/testes-lambda/02-silver/ s3://SEU_BUCKET/02-silver/ --recursive --region us-east-1
  ```

- **8.6.3** Em Variáveis de ambiente, mantenha `NOME_BUCKET` e altere `PREFIXO_SILVER=02-silver` e `PREFIXO_GOLD=03-gold`. O código final precisa aceitar esse par também; alterar apenas as variáveis em uma versão que bloqueia produção gera erro.
- **8.6.4** Execute uma vez o replay da seção 8.2 com esses destinos para regenerar a Gold definitiva de todos os dias a partir da base validada. Para verificar só um dia afetado, o evento manual pode apontar para um arquivo daquele dia.
- **8.6.5** Confira os caminhos `02-silver/` e `03-gold/` nos logs.
- **8.6.6** Reative o gatilho se ele foi desativado e teste novos uploads reais, sem invocação manual. Confira o aumento esperado das coletas na Gold definitiva.


## 9. Regras, manutenção e solução de erros

### 9.2 Renovar credenciais no Windows — PowerShell

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

### 9.3 Renovar credenciais na EC2 — Bash

```bash
mkdir -p ~/.aws
nano ~/.aws/credentials
chmod 600 ~/.aws/credentials
aws sts get-caller-identity --region us-east-1
```

Use o mesmo formato do bloco acima. Não rode novamente o criador de Data Lake só para renovar credenciais. Se o coletor Linux usa arquivos isolados em sua própria pasta, renove os arquivos que o launcher aponta; use a opção `--credenciais` do instalador somente se ela estiver presente nessa versão. Credenciais salvas no Windows não se propagam para a EC2. O Lambda utiliza o papel de execução; não recebe automaticamente essas credenciais locais.

### 9.4 Erros comuns

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

## 10. Referências oficiais

- [Layers Python: versão, estrutura e compatibilidade](https://docs.aws.amazon.com/lambda/latest/dg/python-layers.html)
- [Eventos S3 com Lambda e prevenção de recursão](https://docs.aws.amazon.com/lambda/latest/dg/with-s3.html)
- [Estrutura do evento S3 e codificação da chave](https://docs.aws.amazon.com/AmazonS3/latest/userguide/notification-content-structure.html)
- [Simultaneidade reservada](https://docs.aws.amazon.com/lambda/latest/dg/configuration-concurrency.html)