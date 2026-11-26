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
| **8** | Testes locais e inicialização real | Carga inicial |
| **9** | VM / Windows | Regras, manutenção (renovação de credenciais), possíveis problemas, solução de erros e entrega |
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

## 7. Dependências e funções AWS Lambda
 
O projeto usa **três funções Lambda**, cada uma com uma responsabilidade:
 
| Função | Arquivo do repositório | Quem aciona | Lê | Grava |
|---|---|---|---|---|
| `montech-ingest` | `lambda_ingest.py` | Function URL (HTTP `POST` do coletor) | corpo da requisição | `01-bronze/*` |
| `montech-bronze2silver` | `lambda_bronze2silver.py` | Evento S3 em `01-bronze/` | `01-bronze/*` | `02-silver/*` |
| `montech-silver2gold` | `lambda_silver2gold.py` | Evento S3 em `02-silver/` | `02-silver/*` | `03-gold/*` |
 
Fluxo completo:
 
```
Script_Extracao.py --POST text/csv--> montech-ingest (Function URL) --> 01-bronze/
   --> montech-bronze2silver --> 02-silver/ --> montech-silver2gold --> 03-gold/
```
 
O coletor **não usa credenciais AWS**: ele só precisa da URL da `montech-ingest`.
 
### 7.1 Layer (pandas / NumPy) — só para a `montech-silver2gold`
 
A `montech-silver2gold` usa pandas/NumPy. As outras duas funções não precisam de layer.
 
- **Recomendado:** Lambda Layer com `python/` contendo pandas e numpy compilados para Linux x86_64.
- **Alternativa (menos recomendada):** empacotar as dependências no ZIP da função (fica grande). Não copie pacotes instalados no Windows; gere em Linux ou Docker.
Build via Docker:
 
```bash
mkdir -p ~/montech-lambda-layer/python
docker run --rm -v "$HOME/montech-lambda-layer:/var/task" public.ecr.aws/lambda/python:3.14 \
  /bin/sh -c 'python -m pip install pandas numpy -t /var/task/python'
cd ~/montech-lambda-layer
zip -qr montech-pandas-py314.zip python
aws s3 cp montech-pandas-py314.zip s3://SEU_BUCKET/dependencias/ --region us-east-1
```
 
Depois: Console AWS → Lambda → Layers → Criar camada → faça upload do ZIP (ou aponte para o S3). Marque o runtime Python 3.14 e a arquitetura x86_64.
 
### 7.2 Criar as funções
 
Crie **na ordem abaixo** (região `us-east-1`). Em todas: Lambda → Criar função → Criar do zero, role do laboratório (`LabRole` ou a autorizada) e upload do arquivo `.py` do repositório.
 
| | `montech-ingest` | `montech-bronze2silver` | `montech-silver2gold` |
|---|---|---|---|
| Handler | `lambda_ingest.lambda_handler` | `lambda_bronze2silver.lambda_handler` | `lambda_silver2gold.lambda_handler` |
| Runtime | Python 3.12 ou 3.14 | Python 3.12 ou 3.14 | Python 3.14 (se a layer foi feita para 3.14) |
| Arquitetura | x86_64 | x86_64 | x86_64 |
| Memória | 256 MB | 1024 MB | 1024 MB |
| Timeout | 30 s | 120 s | 120 s |
| Permissão S3 | `PutObject` em `01-bronze/*` | `GetObject` em `01-bronze/*` e `PutObject` em `02-silver/*` | `GetObject` em `02-silver/*` e `PutObject` em `03-gold/*` |
| Extras | Function URL (seção 7.3) | — | Layer pandas/NumPy e **simultaneidade reservada = 1** |
 
> Simultaneidade reservada da `montech-silver2gold` (Configuration → Concurrency → Reserved concurrency = 1): evita sobrescrita concorrente dos arquivos diários.
 
### 7.3 Código-fonte das funções (`functions_lambda.zip`)
 
O repositório Python tem o arquivo **`functions_lambda.zip`**, que contém todos os arquivos das três Lambdas. Ele é o mesmo para as três funções; o que define qual código roda em cada uma é o **handler**. Repita o passo abaixo em `montech-ingest`, `montech-bronze2silver` e `montech-silver2gold`:
 
1. Abra a função e vá na aba **Code** (Código).
2. Em **Code source**, clique em **Upload from** (botão de upload) e escolha **.zip file**.
3. Clique em **Upload**, selecione o `functions_lambda.zip` do repositório e confirme em **Save**.
4. Ainda na aba **Code**, role até **Runtime settings** → **Edit** e confira o **Handler** da função:
| Função | Handler |
|---|---|
| `montech-ingest` | `lambda_ingest.lambda_handler` |
| `montech-bronze2silver` | `lambda_bronze2silver.lambda_handler` |
| `montech-silver2gold` | `lambda_silver2gold.lambda_handler` |
 
5. Confirme que os arquivos `.py` aparecem na raiz do editor de código (sem pasta intermediária). Se aparecerem dentro de uma pasta, o handler não será encontrado.
> Sempre que o código mudar no repositório, gere o ZIP novamente e repita os passos 1 a 3 nas três funções.
 
### 7.4 Function URL da `montech-ingest`
 
A `montech-ingest` é a única exposta por HTTP: recebe o CSV por `POST`, valida o caminho de `?filename=` e grava o objeto em `01-bronze/`.
 
1. Na função: **Configuração → URL da função → Criar URL da função**.
2. Tipo de autenticação: **NONE**. O coletor não assina requisições, então com `AWS_IAM` o envio falha com 403.
3. CORS: não é necessário (chamada servidor → servidor).
4. Copie a URL gerada (formato `https://<id>.lambda-url.us-east-1.on.aws/`). Ela é a que o instalador do coletor pede (seção 8.2).
Regras aplicadas pelo handler:
 
- Só aceita `POST`.
- Exige o parâmetro `filename` na query string.
- Só grava chaves que começam com `PREFIXO_BRONZE` (padrão `01-bronze/`).
- Rejeita caminhos com `..` (path traversal).
- Limite de **6 MB** por requisição (limite da Function URL).
### 7.5 Variáveis de ambiente
 
Defina em cada função (Configuration → Environment variables). Não use `testes-lambda`; use os prefixos definitivos:
 
| Chave | Valor exemplo | `montech-ingest` | `montech-bronze2silver` | `montech-silver2gold` |
|---|---|:---:|:---:|:---:|
| `NOME_BUCKET` | `montech-datalake-XXXX` | ✔ | ✔ | ✔ |
| `PREFIXO_BRONZE` | `01-bronze` (padrão, opcional) | ✔ | | |
| `PREFIXO_SILVER` | `02-silver` | | ✔ | ✔ |
| `PREFIXO_GOLD` | `03-gold` | | | ✔ |
 
---
 
## 8. Inicialização e validação
 
### 8.1 Instalar o coletor no servidor e testar o fluxo completo
 
1. No servidor do cliente, rode `bash instalar-coletor.sh` (com `Script_Extracao.py` e `Organizador.py` na mesma pasta). Informe a **URL da Lambda de ingestão** (7.4) e os dados do MySQL. O instalador grava a URL em `URL_LAMBDA` e testa o acesso à Lambda sem enviar arquivo.
2. Para trocar a URL depois: `~/montech-coletor/instalar-coletor.sh --lambda`.
3. Inicie a coleta: `tmux new -s montech` e depois `~/montech-coletor/iniciar_coleta.sh`. Deixe gerar alguns registros.
4. Pare com `Ctrl+C`: o coletor reenvia os arquivos pendentes.
5. Confira no host autorizado ou no console:
```bash
aws s3 ls s3://SEU_BUCKET/01-bronze/ --recursive --region us-east-1
aws s3 ls s3://SEU_BUCKET/03-gold/ --recursive --region us-east-1
aws logs tail /aws/lambda/montech-ingest --since 10m --region us-east-1
aws logs tail /aws/lambda/montech-silver2gold --since 10m --region us-east-1
```
 
> Se `URL_LAMBDA` estiver vazia, o coletor mantém os CSVs apenas localmente e não envia nada.
 
### 8.2 Reconstrução de histórico (replay controlado)
 
Se já existem CSVs na Bronze, use um host autorizado (com `lambda:InvokeFunction` e `s3:ListBucket`) para invocar a `montech-bronze2silver` para cada CSV de `01-bronze/`:
 
```python
import json, boto3
BUCKET = 'SEU_BUCKET'; FUNC = 'montech-bronze2silver'; R = 'us-east-1'
s3 = boto3.client('s3', region_name=R); lam = boto3.client('lambda', region_name=R)
keys = []
for page in s3.get_paginator('list_objects_v2').paginate(Bucket=BUCKET, Prefix='01-bronze/'):
    for o in page.get('Contents', []):
        if o['Key'].endswith('.csv'): keys.append(o['Key'])
for k in sorted(keys):
    lam.invoke(FunctionName=FUNC, InvocationType='RequestResponse',
               Payload=json.dumps({'bucket': BUCKET, 'chave': k}).encode())
    print('invoked', k)
```
 
Isso preenche `02-silver/` a partir da Bronze sem depender de gatilho. Só depois de validar a Silver, processe a Gold com a `montech-silver2gold`.
 
---

# 9. Regras, manutenção e solução de erros

## 9.1 Panorama rápido

- O coletor roda localmente e envia CSV via **Function URL**.
- A **Lambda** processa a camada Silver e gera os artefatos Gold.
- A EC2 normalmente usa um **Instance Profile** (`LabInstanceProfile`) para obter credenciais; no Windows, o AWS CLI usa `~/.aws/credentials`.

## 9.2 Renovar credenciais no Windows (PowerShell)

Edite o arquivo `~\.aws\credentials`:

```ini
[default]
aws_access_key_id=ACCESS_KEY_ATUAL
aws_secret_access_key=SECRET_KEY_ATUAL
aws_session_token=SESSION_TOKEN_ATUAL
```

Valide:

```powershell
aws sts get-caller-identity --region us-east-1
```

> **Importante:** renove sempre os **três valores juntos**. Nunca exponha essas credenciais em chats ou commits.

## 9.3 Renovar credenciais na EC2 (Bash)

```bash
mkdir -p ~/.aws
nano ~/.aws/credentials
chmod 600 ~/.aws/credentials
aws sts get-caller-identity --region us-east-1
```

> Se a EC2 usa um Instance Profile, **não é necessário** arquivo de credenciais.

## 9.4 Erros comuns e ações rápidas

| Sintoma | Verificação rápida |
|---|---|
| `aws` não reconhecido | Instale o AWS CLI v2 e reinicie o terminal (`aws --version`). |
| `NoCredentials` | Confira `~/.aws/credentials`, variáveis `AWS_*` e o Instance Profile. |
| `InvalidToken` | Tokens expirados: renove Access Key, Secret Key e Session Token. |
| `No module named pandas` na Lambda | Confirme a layer anexada e a compatibilidade de runtime/arquitetura. |
| `AccessDenied` no S3 | Confirme as permissões do role da Lambda e se o bucket está na mesma conta. |
| Upload concluiu, mas a Gold não mudou | Verifique `PREFIXO_SILVER`, `PREFIXO_GOLD` e os logs da Lambda. |
| Falha ao conectar no MySQL | Teste o Security Group/porta `3306` e o `.env` com `DB_HOST` correto. |
| `URL can't contain control characters` | Há espaço ou quebra de linha na `URL_LAMBDA`. |
| `URL_LAMBDA não foi configurada` | A constante `URL_LAMBDA` está vazia. |
| `Falha ao enviar ...` | Lambda fora do ar, URL incorreta ou servidor sem rede. O arquivo continua local e é reenviado depois. |
| HTTP 403 na ingestão | Function URL com autenticação `AWS_IAM` ou sem permissão pública. Use `NONE`. |
| Ingestão responde, mas nada aparece em `01-bronze/` | O role da `montech-ingest` não tem `PutObject`, ou `NOME_BUCKET` está incorreto. |
| Arquivo chega na Bronze, mas não gera Silver | Gatilho S3 da `montech-bronze2silver` ausente (prefixo `01-bronze/`, sufixo `.csv`). |
| Temperatura da CPU vazia | No Windows, terminal sem permissão de Administrador, ou a máquina não expõe o sensor. |
| `Erro ao conectar ao banco de dados` | Credenciais do `.env` incorretas ou MySQL inacessível. |
| `Servidor sem empresa/aeroporto definido` | O token não tem empresa e aeroporto vinculados no banco. |

## 10. Referências oficiais

- [Layers Python: versão, estrutura e compatibilidade](https://docs.aws.amazon.com/lambda/latest/dg/python-layers.html)
- [Eventos S3 com Lambda e prevenção de recursão](https://docs.aws.amazon.com/lambda/latest/dg/with-s3.html)
- [Estrutura do evento S3 e codificação da chave](https://docs.aws.amazon.com/AmazonS3/latest/userguide/notification-content-structure.html)
- [Simultaneidade reservada](https://docs.aws.amazon.com/lambda/latest/dg/configuration-concurrency.html)
