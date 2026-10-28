# Guia de Implantação MonTech

Passo a passo automatizado e consolidado para implantação da infraestrutura: VM EC2 (Ubuntu), MySQL no Docker, Coletor de Métricas no Windows e ETL agendado.

## 📋 Visão Geral do Ambiente

| Parte | Ambiente | O que faz | 
| ----- | ----- | ----- | 
| **Parte 0** | VM (SSH) | Provisionamento e auditoria de usuários (`config-acesso-ec2.sh`) | 
| **Parte 1** | VM (SSH) | Preparação do ambiente e criação do Data Lake S3 (`configurar-ambiente-datalake.sh`) | 
| **Parte 2** | VM (SSH) | Instalação do Docker e subida do container MySQL | 
| **Parte 3.1** | Windows (PowerShell) | Coletor de métricas enviando CSV para o Data Lake | 
| **Parte 3.2** | Linux (Bash) | Coletor de métricas enviando CSV para o Data Lake |
| **Parte 4** | VM (SSH) | Execução do ETL para as camadas Prata e Ouro | 
| **Parte 5** | VM (SSH) | Agendamento do ETL a cada 15 minutos via `cron` | 
| **Parte 6** | VM / Windows | Manutenção (renovação de credenciais) e solução de erros | 

---

## 🛠️ PARTE 0: Acesso e Política de Usuários

Conecte-se à VM EC2 via SSH e crie os usuários da equipe de forma automatizada.

0. **Mudar permissão da chave:**
   ```bash
   chmod 400 "CAMINHO_DA_CHAVE.pem"
   ```

1. **Conectar na VM:**
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

3. **Conferir e anotar o nome do bucket gerado:**
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
## 🔐 Parte 3: Segurança na porta MyQL na AWS
---

Como a porta **3306** estará publicada nas interfaces de rede da VM, restrinja o acesso usando a **Security Group da VM** que hospeda o MySQL.

* Na tela de **Instâncias**, selecione a VM que está o MySQL no container Docker.
* Selecione a opção **"Segurança"**.
* Em **"Regras de entrada"** clique no **"Grupo de segurança"** que vai estar em azul.
* Clique no **"ID do grupo de segurança"** que vai estar em azul também.
* Agora clique em **"Editar regras de entrada"**.
* Clique em **"Adicionar regra"**.
* Preenhca no **Tipo** com **MYSQL/Aurora**.
* **Intervalo de portas** coloque **3306**.
* Em **Origem** coloque o IP publico da máquina que deseja acessar o banco e **"/32"** no final (ex: 127.0.0.1/32).
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

Valide (deve imprimir `Dependencias OK`; precisa ser Python **3.9 ou superior**):

```powershell
python -c "import pandas, psutil, boto3, mysql.connector, dotenv; print('Dependencias OK')"
```

> Se o `Activate` der o erro *"a execução de scripts foi desabilitada neste sistema"*, rode `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` (vale só para esta janela) e ative de novo. O prompt deve passar a começar com `(venv)`.

---

### 2. Configurar o bucket e a região no código

Abra o `Script_Extracao.py` (de preferência no VS Code: `code Script_Extracao.py`; no Bloco de Notas, use `Ctrl+F` e procure `NOME_BUCKET`):

- **Linha 36:** troque o nome pelo do seu bucket: `NOME_BUCKET = "montech-datalake-XXXX"`
- **Linha 39:** confira a região: `REGIAO_AWS = "us-east-1"` (nunca `us-east-1d`, que é zona de disponibilidade)

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

Crie o `.env` na pasta do projeto (troque `IP_PUBLICO` e `SENHA_MONTECH`; na opção **B**, use `DB_HOST=127.0.0.1`):

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

> As credenciais do laboratório expiram (cerca de 4 horas) e mudam a cada nova sessão. Quando isso acontecer, repita este passo e o 5.

---

### 5. Executar o Coletor

No mesmo terminal onde você rodou as validações (com o `(venv)` ativo):

```powershell
python -m py_compile Script_Extracao.py Organizador.py
python Script_Extracao.py
```

Faça login com o e-mail e a senha do sistema e informe o token do servidor. O CSV é enviado ao S3 a cada 15 minutos; ao apertar `Ctrl+C`, o coletor envia o que estiver pendente e encerra. Deve aparecer `CSV enviado para s3://...`.

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
Nota: O script solicitará o nome do Bucket `montech-datalake-2014`, a região, o IP público do servidor `18.212.230.200`, usuário do banco `montech`, nome do database `montech` e suas credenciais da AWS (`Access Key`, `Secret Key`, `Session Token`).

3. Rodando o Script de Captura:
```bash
tmux new -s montech
```
Esse comando serve para criar uma sessão persistente, onde ele funcionará mesmo depois de desconectar do SSH

4. Com ele você entrará numa sessão onde deve rodar:
```bash
montech-coletor/iniciar_coleta.sh
```
Nota: Ele vai pedir email, senha e token. O email use `carlos.silva@aeroportospaulistas.com.br` e na senha use `Admin@123` como teste. Em token utilize um token gerado por um servidor que esteja cadastrado no banco. Para sair é só utilizar `Ctrl + C` e depois 

5. Extras:
```bash
tmux attach -t montech
```
É utilizado para voltar para uma sessão que foi aberta e não foi finalizada

---

## 🔄 PARTE 4: Executando o ETL na VM

1. **Preparar o ambiente Python na VM:**
   ```bash
   sudo apt install -y python3-venv
   mkdir -p ~/montech-etl && cd ~/montech-etl
   python3 -m venv .venv
   source .venv/bin/activate
   pip install pandas boto3 mysql-connector-python python-dotenv
   ```

2. **Enviar os scripts do ETL (do Windows via SCP):**
   ```bash
   scp -i "CAMINHO_DA_CHAVE.pem" Organizador.py etl_1.py ubuntu@IP_PUBLICO:/home/ubuntu/montech-etl/
   ```

2.1. **Ajustar nome do Bucket:**
   ```bash
   nano /home/ubuntu/montech-etl/etl_1.py
   ```
**Nota:** Altere a linha 33 o nome do Bucket para o nome do seu.
     

3. **Criar o `.env` do ETL na VM:**
   ```bash
   cat > ~/montech-etl/.env << 'EOF'
   DB_HOST=127.0.0.1
   DB_USER=montech
   DB_PASSWORD=SENHA_MONTECH
   DB_NAME=montech
   EOF
   chmod 600 ~/montech-etl/.env
   ```

4. **Executar o ETL:**
   ```bash
   cd ~/montech-etl
   source .venv/bin/activate
   python etl_1.py
   ```

---

## ⏱️ PARTE 5: Agendamento Automático (cron)

1. **Criar o script de execução segura com `flock`:**
   ```bash
   cat > ~/montech-etl/run_etl.sh << 'EOF'
   #!/bin/bash
   cd /home/ubuntu/montech-etl || exit 1
   source .venv/bin/activate
   exec /usr/bin/flock -n etl.lock python etl_1.py >> etl.log 2>&1
   EOF
   chmod +x ~/montech-etl/run_etl.sh
   ```

2. **Agendar no cron (a cada 15 minutos):**
   ```bash
   (crontab -l 2>/dev/null | grep -v 'etl_1.py' | grep -v 'run_etl.sh'; echo '* * * * * /home/ubuntu/montech-etl/run_etl.sh') > /tmp/cron_montech
   crontab /tmp/cron_montech
   ```

---

## 🔧 PARTE 6: Manutenção e Erros Comuns

* **Renovar credenciais AWS expiradas na VM:**
  ```bash
  aws configure set aws_access_key_id "NOVA_ACCESS_KEY"
  aws configure set aws_secret_access_key "NOVA_SECRET_KEY"
  aws configure set aws_session_token "NOVA_SESSION_TOKEN"
  aws configure set region us-east-1
  ```
