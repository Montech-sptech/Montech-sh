# Guia de Implantação MonTech

Passo a passo automatizado e consolidado para implantação da infraestrutura: VM EC2 (Ubuntu), MySQL no Docker, Coletor de Métricas no Windows e ETL agendado.

## 📋 Visão Geral do Ambiente

| Parte | Ambiente | O que faz | 
| ----- | ----- | ----- | 
| **Parte 0** | VM (SSH) | Provisionamento e auditoria de usuários (`config-acesso-ec2.sh`) | 
| **Parte 1** | VM (SSH) | Instalação do AWS CLI e criação automática dos buckets (`configurar-buckets.sh`) | 
| **Parte 2** | VM (SSH) | Instalação do Docker e subida do container MySQL | 
| **Parte 3** | Windows (PowerShell) | Coletor de métricas enviando CSV para o Data Lake | 
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

O script abaixo já instala dependências, configura o AWS CLI e cria toda a estrutura do S3.

1. **Criar o script de configuração de buckets (`configurar-buckets.sh`):**
   ```bash
   nano ~/configurar-buckets.sh
   ```
   *(Cole o conteúdo do seu script `configurar-buckets.sh`, salve e feche)*.

2. **Executar o script:**
   ```bash
   chmod +x ~/configurar-buckets.sh
   ~/configurar-buckets.sh
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
     -p 127.0.0.1:3307:3306 \
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

## 💻 PARTE 3: Coletor de Métricas (Windows)

No seu computador local (**PowerShell**):

1. **Criar o ambiente virtual e instalar as dependências:**
   ```powershell
   python -m venv venv
   .\venv\Scripts\Activate
   python -m pip install pandas psutil boto3 mysql-connector-python python-dotenv
   ```

2. **Configurar as credenciais da AWS:**
   ```powershell
   New-Item -ItemType Directory -Force "$env:USERPROFILE\.aws" | Out-Null
   notepad "$env:USERPROFILE\.aws\credentials"
   ```
   Cole o seguinte conteúdo e salve:
   ```ini
   [default]
   aws_access_key_id=COLE_ACCESS_KEY
   aws_secret_access_key=COLE_SECRET_KEY
   aws_session_token=COLE_SESSION_TOKEN
   ```

3. **Configurar o `.env` do projeto local:**
   Na mesma pasta do projeto, crie um arquivo chamado `.env`:
   ```env
   DB_HOST=127.0.0.1
   DB_USER=montech
   DB_PASSWORD=SENHA_MONTECH
   DB_NAME=montech
   ```

4. **Abrir o túnel SSH (em outra janela do PowerShell e deixá-la aberta):**
   ```powershell
   ssh -i "CAMINHO_DA_CHAVE.pem" -L 3307:127.0.0.1:3306 ubuntu@IP_PUBLICO
   ```
   *Abra outro terminal no mesmo diretório sem fechar esse da conexão SSH.*
   *Teste a conexão na janela principal:*
   ```powershell
   Test-NetConnection 127.0.0.1 -Port 3307
   ```

5. **Executar o Coletor:**
*No mesmo terminal que você rodou o teste acima*
   ```powershell
   python -m py_compile Script_Extracao.py Organizador.py
   python Script_Extracao.py
   ```

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
   (crontab -l 2>/dev/null | grep -v 'etl_1.py' | grep -v 'run_etl.sh'; echo '*/15 * * * * /home/ubuntu/montech-etl/run_etl.sh') > /tmp/cron_montech
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
