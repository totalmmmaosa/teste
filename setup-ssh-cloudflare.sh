#!/bin/bash

# ============================================================
#  Setup SSH + Cloudflare Tunnel - Ubuntu 24
#  Autor: equipelsquid
#  Uso: sudo bash setup-ssh-cloudflare.sh
# ============================================================

set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Funções de log ---
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()      { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[AVISO]${NC} $1"; }
log_error()   { echo -e "${RED}[ERRO]${NC} $1"; exit 1; }
log_section() { echo -e "\n${CYAN}========== $1 ==========${NC}\n"; }

# --- Verificar root ---
if [ "$EUID" -ne 0 ]; then
    log_error "Execute como root: sudo bash $0"
fi

# ============================================================
# VARIÁVEIS - Altere conforme necessário
# ============================================================
SSH_PORT=22
SSH_USER=$(logname 2>/dev/null || echo "${SUDO_USER:-$USER}")
CLOUDFLARE_TUNNEL_NAME="meu-servidor"

# ============================================================
# INÍCIO
# ============================================================
clear
echo -e "${CYAN}"
echo "╔═══════════════════════════════════════════════╗"
echo "║     Setup SSH + Cloudflare Tunnel Ubuntu      ║"
echo "╚═══════════════════════════════════════════════╝"
echo -e "${NC}"

log_info "Usuário detectado: ${SSH_USER}"
log_info "Porta SSH: ${SSH_PORT}"

# ============================================================
# ETAPA 1 - Atualizar sistema
# ============================================================
log_section "ETAPA 1: Atualizando pacotes"
apt update -y
log_ok "Pacotes atualizados!"

# ============================================================
# ETAPA 2 - Instalar e configurar SSH
# ============================================================
log_section "ETAPA 2: Configurando SSH Server"

apt install -y openssh-server
log_ok "openssh-server instalado!"

# Fazer backup da config original
if [ -f /etc/ssh/sshd_config ]; then
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
    log_info "Backup de sshd_config criado em /etc/ssh/sshd_config.backup"
fi

# Configurar sshd_config
cat > /etc/ssh/sshd_config << EOF
# SSH Server Config - Gerado automaticamente
Port ${SSH_PORT}
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::

# Autenticação
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication yes
PermitEmptyPasswords no
ChallengeResponseAuthentication no

# Segurança
UsePAM yes
X11Forwarding no
PrintMotd no
MaxAuthTries 5
LoginGraceTime 30

# Aceitar variáveis de ambiente
AcceptEnv LANG LC_*

# SFTP
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

log_ok "sshd_config configurado!"

# Habilitar e reiniciar SSH
systemctl enable ssh
systemctl restart ssh

# Verificar se está rodando
if systemctl is-active --quiet ssh; then
    log_ok "SSH rodando na porta ${SSH_PORT}!"
else
    log_error "SSH não iniciou corretamente. Verifique: journalctl -xe"
fi

# ============================================================
# ETAPA 3 - Instalar cloudflared
# ============================================================
log_section "ETAPA 3: Instalando cloudflared"

# Verificar se já está instalado
if command -v cloudflared &> /dev/null; then
    CURRENT_VERSION=$(cloudflared --version 2>&1 | head -1)
    log_warn "cloudflared já instalado: ${CURRENT_VERSION}"
    log_info "Pulando instalação..."
else
    # Adicionar repositório Cloudflare
    mkdir -p /usr/share/keyrings

    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
        | tee /usr/share/keyrings/cloudflare-main.gpg > /dev/null

    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] \
https://pkg.cloudflare.com/cloudflared jammy main" \
        | tee /etc/apt/sources.list.d/cloudflared.list

    apt update -y
    apt install -y cloudflared

    log_ok "cloudflared instalado: $(cloudflared --version 2>&1 | head -1)"
fi

# ============================================================
# ETAPA 4 - Verificar/Configurar Tunnel existente
# ============================================================
log_section "ETAPA 4: Configurando Cloudflare Tunnel"

CLOUDFLARED_CONFIG="/etc/cloudflared/config.yml"

if [ -f "$CLOUDFLARED_CONFIG" ]; then
    log_ok "Arquivo config.yml já existe em ${CLOUDFLARED_CONFIG}"
    log_info "Conteúdo atual:"
    cat "$CLOUDFLARED_CONFIG"
else
    log_warn "Nenhum config.yml encontrado."
    log_warn "Você precisa autenticar e criar o tunnel manualmente."
    echo ""
    echo -e "${YELLOW}Execute os seguintes comandos como seu usuário (NÃO root):${NC}"
    echo ""
    echo -e "  ${CYAN}cloudflared tunnel login${NC}"
    echo -e "  ${CYAN}cloudflared tunnel create ${CLOUDFLARE_TUNNEL_NAME}${NC}"
    echo ""
    echo -e "${YELLOW}Depois edite o arquivo:${NC} ${CYAN}/etc/cloudflared/config.yml${NC}"
    echo ""
    echo -e "Com este conteúdo (substituindo <TUNNEL_ID> e <SEU_DOMINIO>):"
    echo ""

    # Criar diretório e exemplo de config
    mkdir -p /etc/cloudflared

    cat > /etc/cloudflared/config.yml.example << 'EXAMPLE'
# /etc/cloudflared/config.yml
tunnel: <TUNNEL_ID>
credentials-file: /root/.cloudflared/<TUNNEL_ID>.json

ingress:
  - hostname: <SEU_DOMINIO>   # ex: ia1.equipelsquid.dev
    service: ssh://localhost:22
  - service: http_status:404
EXAMPLE

    cat /etc/cloudflared/config.yml.example
    echo ""
fi

# ============================================================
# ETAPA 5 - Instalar cloudflared como serviço
# ============================================================
log_section "ETAPA 5: Registrando cloudflared como serviço"

if [ -f "$CLOUDFLARED_CONFIG" ]; then
    cloudflared service install 2>/dev/null || true
    systemctl enable cloudflared 2>/dev/null || true
    systemctl restart cloudflared 2>/dev/null || true

    if systemctl is-active --quiet cloudflared; then
        log_ok "cloudflared rodando como serviço!"
    else
        log_warn "cloudflared não iniciou. Verifique a configuração do tunnel."
        log_warn "Logs: journalctl -u cloudflared -f"
    fi
else
    log_warn "Pulando instalação do serviço (sem config.yml)"
fi

# ============================================================
# ETAPA 6 - Firewall UFW (opcional)
# ============================================================
log_section "ETAPA 6: Configurando Firewall (UFW)"

if command -v ufw &> /dev/null; then
    ufw allow ${SSH_PORT}/tcp comment "SSH" 2>/dev/null || true
    log_ok "Regra SSH adicionada no UFW!"
else
    log_warn "UFW não encontrado, pulando..."
fi

# ============================================================
# ETAPA 7 - Gerar chave SSH (se não existir)
# ============================================================
log_section "ETAPA 7: Verificando chaves SSH"

USER_HOME=$(eval echo "~${SSH_USER}")
SSH_DIR="${USER_HOME}/.ssh"

if [ ! -f "${SSH_DIR}/id_rsa" ]; then
    mkdir -p "${SSH_DIR}"
    chmod 700 "${SSH_DIR}"
    sudo -u "${SSH_USER}" ssh-keygen -t rsa -b 4096 \
        -f "${SSH_DIR}/id_rsa" \
        -N "" \
        -C "${SSH_USER}@$(hostname)"
    log_ok "Par de chaves SSH gerado!"
else
    log_ok "Chave SSH já existe: ${SSH_DIR}/id_rsa"
fi

# ============================================================
# RESUMO FINAL
# ============================================================
log_section "RESUMO FINAL"

echo -e "${GREEN}✅ SSH Server:${NC} $(systemctl is-active ssh)"
echo -e "${GREEN}✅ Porta SSH:${NC} ${SSH_PORT}"
echo -e "${GREEN}✅ cloudflared:${NC} $(cloudflared --version 2>&1 | head -1)"

if systemctl is-active --quiet cloudflared 2>/dev/null; then
    echo -e "${GREEN}✅ Tunnel:${NC} Rodando"
else
    echo -e "${YELLOW}⚠️  Tunnel:${NC} Não configurado ainda"
fi

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}📌 Para conectar do seu PC local via tunnel:${NC}"
echo ""
echo -e "  1. Instale cloudflared no PC local"
echo -e "  2. Adicione ao ~/.ssh/config:"
echo ""
echo -e "${CYAN}Host ia1.equipelsquid.dev"
echo -e "    HostName ia1.equipelsquid.dev"
echo -e "    User ${SSH_USER}"
echo -e "    ProxyCommand cloudflared access ssh --hostname %h${NC}"
echo ""
echo -e "  3. Conecte:"
echo -e "${CYAN}     ssh ${SSH_USER}@ia1.equipelsquid.dev${NC}"
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✅ Script finalizado!${NC}"
