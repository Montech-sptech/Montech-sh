# Guia de Implantação - MonTech

Este guia consolida os passos automatizados para a implantação do ambiente na VM EC2 (Ubuntu).

---

## 1. Configuração do Ambiente e AWS CLI

Em vez de instalar pacotes manualmente, utilize o script automatizado de buckets/ambiente:

1. Crie o arquivo do script na VM:
   ```bash
   nano ~/configurar-buckets.sh
   ```
2. Cole o código do script `configurar-buckets.sh`, salve e feche (`Ctrl+O`, `Enter`, `Ctrl+X`).
3. Dê permissão e execute o script:
   ```bash
   chmod +x ~/configurar-buckets.sh
   ~/configurar-buckets.sh
   ```
   *(O script vai solicitar suas credenciais da AWS e configurar o Data Lake S3 automaticamente).*

---

## 2. Provisionamento de Acessos e Usuários da Equipe

Para criar os usuários da equipe (`guilherme`, `thiago`, `lucas`, `vinicius`, `nicole`) e o usuário de serviço `montech` de forma automática:

1. Crie o arquivo do script de acesso na VM:
   ```bash
   nano ~/config-acesso-ec2.sh
   ```
2. Cole o código do script `config-acesso-ec2.sh`, salve e feche.
3. Execute o script com privilégios de root:
   ```bash
   sudo chmod +x ~/config-acesso-ec2.sh
   sudo ~/config-acesso-ec2.sh
   ```

### Auditoria de Usuários
Para confirmar se todos os 6 usuários foram criados corretamente no sistema, rode:
```bash
getent passwd guilherme thiago lucas vinicius nicole montech
```

---

## 3. Configuração do Ambiente Local (Windows / Git Bash / PowerShell)

### 3.1. Ativação do Ambiente Virtual (venv)
Se estiver utilizando o Windows (Git Bash ou PowerShell), ative o ambiente virtual antes de instalar as dependências:

* **No Git Bash:**
  ```bash
  source venv/Scripts/activate
  ```
* **No PowerShell** (caso dê erro de permissão de script, rode `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process` antes):
  ```powershell
  .\venv\Scripts\Activate
  ```

### 3.2. Instalação das Bibliotecas do Projeto
Com o ambiente virtual ativado, instale os pacotes necessários:
```bash
python -m pip install pandas psutil boto3 mysql-connector-python python-dotenv
```

---

## 4. Acesso e Túnel SSH para o Banco de Dados (MySQL)

### 4.1. Correção de Permissões da Chave Privada (`.pem`) no Windows
O cliente SSH do Windows exige que a chave `.pem` seja restrita. Abra o **PowerShell** na pasta da chave e execute:
```powershell
icacls CAMINHO_DA_CHAVE.pem /inheritance:r
icacls CAMINHO_DA_CHAVE.pem /grant "$($env:USERNAME):(F)"
```

### 4.2. Abrindo o Túnel SSH
Para conectar à base de dados na AWS de forma segura através de uma porta local (utilizando a porta `3307` para evitar conflitos com o MySQL local do Windows):
```powershell
ssh -i "CAMINHO_DA_CHAVE.pem" -L 3307:127.0.0.1:3306 ubuntu@IP_DA_SUA_VM_EC2
```
*(Deixe essa janela do terminal aberta enquanto precisar se conectar ao banco de dados).*