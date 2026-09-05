#!/bin/bash

# ============================================================
#  Setup SSH + Cloudflare Tunnel para PuTTY - Ubuntu 24
#  Uso: sudo bash setup-ssh-cloudflare.sh
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_ok()      { echo -e "${GREEN}[✓]${NC} $1"; }
log_info()    { echo -e "${CYAN}[→]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
log_error()   { echo -e "${RED}[✗] ERRO: $1${NC}"; exit 1; }
log_section() { echo -e "\n${CYAN}══════════════════════════════════════${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}══════════════════════════════════════${NC}\n"; }

# Verificar root
[ "$EUID" -ne 0 ] && log_error "Execute com: sudo bash $0"

# Detectar usuário real (quem rodou o sudo)
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo $USER)}"
REAL_HOME=$(eval echo "~${REAL_USER}")
DOMINIO="ia1.equipelsquid.dev"

clear
echo -e "${CYAN}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║   SSH + Cloudflare Tunnel → PuTTY        ║"
echo "  ║   Ubuntu 24 - Setup Completo             ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  Usuário: ${GREEN}${REAL_USER}${NC}"
echo -e "  Domínio: ${GREEN}${DOMINIO}${NC}"
echo ""

# ============================================================
# ETAPA 1 - Atualizar e instalar dependências
# ============================================================
log_section "ETAPA 1: Atualizando sistema"
apt update -y -qq
apt install -y -qq curl gnupg2 apt-transport-https openssh-server ufw
log_ok "Pacotes instalados!"

# ============================================================
# ETAPA 2 - Configurar SSH Server
# ============================================================
log_section "ETAPA 2: Configurando SSH Server"

# Backup
[ -f /etc/ssh/sshd_config ] && cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
log_info "Backup criado: /etc/ssh/sshd_config.bak"

# Escrever config SSH limpa
cat > /etc/ssh/sshd_config << 'EOF'
# SSH Server - Setup Cloudflare Tunnel + PuTTY
Port 22
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::

# Login
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication yes
PermitEmptyPasswords no

# Segurança
MaxAuthTries 5
LoginGraceTime 30
UsePAM yes
X11Forwarding no
PrintMotd no

# Manter conexão ativa (importante para Cloudflare Tunnel + PuTTY)
ClientAliveInterval 60
ClientAliveCountMax 10
TCPKeepAlive yes

AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

# Reiniciar SSH
systemctl enable ssh --quiet
systemctl restart ssh

systemctl is-active --quiet ssh \
    && log_ok "SSH Server rodando na porta 22!" \
    || log_error "SSH não iniciou! Veja: journalctl -xe"

# ============================================================
# ETAPA 3 - Instalar cloudflared
# ============================================================
log_section "ETAPA 3: Instalando cloudflared"

if command -v cloudflared &>/dev/null; then
    log_warn "cloudflared já instalado: $(cloudflared --version 2>&1 | head -1)"
else
    mkdir -p /usr/share/keyrings

    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
        -o /usr/share/keyrings/cloudflare-main.gpg

    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] \
https://pkg.cloudflare.com/cloudflared jammy main" \
        > /etc/apt/sources.list.d/cloudflared.list

    apt update -y -qq
    apt install -y -qq cloudflared
    log_ok "cloudflared instalado: $(cloudflared --version 2>&1 | head -1)"
fi

# ============================================================
# ETAPA 4 - Autenticar e criar Tunnel
# ============================================================
log_section "ETAPA 4: Configurando Tunnel Cloudflare"

CRED_DIR="${REAL_HOME}/.cloudflared"
CONFIG_FILE="/etc/cloudflared/config.yml"
mkdir -p /etc/cloudflared

# Verificar se já existe configuração
if [ -f "$CONFIG_FILE" ]; then
    log_ok "config.yml já existe! Usando configuração atual."
    cat "$CONFIG_FILE"
else
    # Verificar se já tem credenciais
    TUNNEL_JSON=$(find "${CRED_DIR}" -name "*.json" 2>/dev/null | head -1)

    if [ -z "$TUNNEL_JSON" ]; then
        echo ""
        log_warn "Nenhum tunnel encontrado. Iniciando autenticação..."
        echo ""
        echo -e "${YELLOW}  Abrirá um link para autenticar no Cloudflare.${NC}"
        echo -e "${YELLOW}  Faça login e autorize o domínio equipelsquid.dev${NC}"
        echo ""
        sleep 2

        # Login como usuário real (não root)
        sudo -u "${REAL_USER}" cloudflared tunnel login

        # Criar o tunnel
        echo ""
        log_info "Criando tunnel 'ssh-equipelsquid'..."
        sudo -u "${REAL_USER}" cloudflared tunnel create ssh-equipelsquid

        # Buscar JSON gerado
        TUNNEL_JSON=$(find "${CRED_DIR}" -name "*.json" 2>/dev/null | head -1)
    fi

    # Extrair Tunnel ID do JSON
    TUNNEL_ID=$(basename "$TUNNEL_JSON" .json)
    log_ok "Tunnel ID: ${TUNNEL_ID}"

    # Copiar credencial para /etc/cloudflared
    cp "$TUNNEL_JSON" "/etc/cloudflared/${TUNNEL_ID}.json"
    chown root:root "/etc/cloudflared/${TUNNEL_ID}.json"
    chmod 600 "/etc/cloudflared/${TUNNEL_ID}.json"

    # Criar config.yml
    cat > "$CONFIG_FILE" << EOF
tunnel: ${TUNNEL_ID}
credentials-file: /etc/cloudflared/${TUNNEL_ID}.json

ingress:
  - hostname: ${DOMINIO}
    service: ssh://localhost:22
  - service: http_status:404
EOF

    log_ok "config.yml criado em ${CONFIG_FILE}"

    # Criar DNS (apontar domínio para o tunnel)
    log_info "Criando rota DNS para ${DOMINIO}..."
    sudo -u "${REAL_USER}" cloudflared tunnel route dns ssh-equipelsquid "${DOMINIO}" 2>/dev/null \
        && log_ok "DNS configurado!" \
        || log_warn "DNS pode já existir (ok se já configurou no dashboard)"
fi

# ============================================================
# ETAPA 5 - Instalar cloudflared como serviço
# ============================================================
log_section "ETAPA 5: Instalando serviço systemd"

# Instalar serviço
cloudflared --config "$CONFIG_FILE" service install 2>/dev/null || true
systemctl daemon-reload
systemctl enable cloudflared --quiet
systemctl restart cloudflared

sleep 3

if systemctl is-active --quiet cloudflared; then
    log_ok "cloudflared rodando como serviço!"
else
    log_warn "cloudflared não iniciou corretamente."
    log_warn "Veja os logs: journalctl -u cloudflared -n 50"
fi

# ============================================================
# ETAPA 6 - Firewall
# ============================================================
log_section "ETAPA 6: Configurando Firewall"

if command -v ufw &>/dev/null; then
    ufw allow 22/tcp comment "SSH" 2>/dev/null || true
    log_ok "UFW: porta 22 liberada"
else
    log_warn "UFW não encontrado"
fi

# ============================================================
# RESUMO E INSTRUÇÕES PUTTY
# ============================================================
log_section "INSTALAÇÃO CONCLUÍDA!"

echo -e "${GREEN}✅ SSH Server:${NC}    $(systemctl is-active ssh)"
echo -e "${GREEN}✅ cloudflared:${NC}   $(systemctl is-active cloudflared 2>/dev/null || echo 'verificar')"
echo -e "${GREEN}✅ Domínio:${NC}       ${DOMINIO}"
echo ""

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}  📌 COMO CONECTAR PELO PUTTY (Windows)${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${CYAN}PASSO 1:${NC} Instale o cloudflared no Windows:"
echo -e "           winget install Cloudflare.cloudflared"
echo ""
echo -e "  ${CYAN}PASSO 2:${NC} Configure o PuTTY:"
echo -e "           Session → Host Name: ${DOMINIO}"
echo -e "           Session → Port: 22"
echo ""
echo -e "           Connection → Proxy:"
echo -e "           • Proxy type: ${GREEN}Local${NC}"
echo -e "           • Telnet command: ${GREEN}cloudflared access ssh --hostname %host${NC}"
echo ""
echo -e "           Connection → Data:"
echo -e "           • Auto-login username: ${GREEN}${REAL_USER}${NC}"
echo ""
echo -e "  ${CYAN}PASSO 3:${NC} Salve a sessão e clique em ${GREEN}Open${NC}!"
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${YELLOW}Logs do tunnel:${NC} journalctl -u cloudflared -f"
echo -e "  ${YELLOW}Status:${NC}         systemctl status cloudflared"
echo ""
