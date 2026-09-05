#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 equipelsquid
# Baseado em: https://github.com/NVIDIA/dgx-spark-playbooks/tree/main/nvidia/connect-two-sparks

# ============================================================
#  CONECTAR 2 NOTEBOOKS UBUNTU PARA RODAR IA EM CONJUNTO
#  Uso: sudo bash connect-two-nodes.sh
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

log_ok()      { echo -e "${GREEN}[✓]${NC} $1"; }
log_info()    { echo -e "${CYAN}[→]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
log_error()   { echo -e "${RED}[✗] ERRO: $1${NC}"; exit 1; }
log_section() {
    echo ""
    echo -e "${MAGENTA}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║  $1${NC}"
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ============================================================
# Verificar root
# ============================================================
[ "$EUID" -ne 0 ] && log_error "Execute com: sudo bash $0"

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo $USER)}"
REAL_HOME=$(eval echo "~${REAL_USER}")

clear
echo -e "${CYAN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║   🤖 Setup Cluster IA — 2 Notebooks Ubuntu       ║"
echo "  ║   Baseado em NVIDIA DGX Spark Playbooks          ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

# ============================================================
# ESCOLHER QUAL NÓ É ESTE (argumento $1 ou interativo)
# ============================================================
echo -e "${YELLOW}Este script deve ser executado em AMBAS as máquinas.${NC}"
echo ""

# Aceita argumento direto: sudo bash script.sh 1  OU  curl ... | sudo bash -s 1
if [ -n "${1:-}" ]; then
    NODE_NUMBER="$1"
else
    echo "  Qual é este notebook?"
    echo -e "  ${CYAN}1${NC}) Notebook 1 (PRIMÁRIO   — IP: 10.0.0.1)"
    echo -e "  ${CYAN}2${NC}) Notebook 2 (SECUNDÁRIO — IP: 10.0.0.2)"
    echo ""
    # Lê do terminal físico (funciona mesmo via pipe)
    exec < /dev/tty
    read -r -p "  Digite 1 ou 2: " NODE_NUMBER
fi

case "$NODE_NUMBER" in
    1)
        THIS_IP="10.0.0.1"
        OTHER_IP="10.0.0.2"
        THIS_HOSTNAME="node1"
        OTHER_HOSTNAME="node2"
        log_ok "Configurando como Nó PRIMÁRIO (10.0.0.1)"
        ;;
    2)
        THIS_IP="10.0.0.2"
        OTHER_IP="10.0.0.1"
        THIS_HOSTNAME="node2"
        OTHER_HOSTNAME="node1"
        log_ok "Configurando como Nó SECUNDÁRIO (10.0.0.2)"
        ;;
    *)
        log_error "Opção inválida. Use: sudo bash script.sh 1  (ou 2)"
        ;;
esac

# ============================================================
# ETAPA 1 — Instalar dependências
# ============================================================
log_section "ETAPA 1: Instalando dependências"

apt update -y -qq
apt install -y -qq \
    openssh-server \
    openssh-client \
    net-tools \
    iproute2 \
    avahi-daemon \
    avahi-utils \
    libnss-mdns \
    openmpi-bin \
    openmpi-common \
    libopenmpi-dev \
    nfs-kernel-server \
    nfs-common \
    htop \
    iotop \
    python3 \
    python3-pip \
    python3-venv \
    curl \
    wget \
    git

log_ok "Dependências instaladas!"

# ============================================================
# ETAPA 2 — Detectar interface de cabo direto
# ============================================================
log_section "ETAPA 2: Detectando interface de rede do cabo"

echo -e "${CYAN}Interfaces disponíveis:${NC}"
echo ""
ip -br link show | grep -v "lo" | awk '{print NR") "$1" — "$2" — "$3}'
echo ""

# Tentar detectar automaticamente (interface que não tem IP ainda)
DIRECT_IFACE=""

# Tentar ibdev2netdev primeiro (DGX/RDMA)
if command -v ibdev2netdev &>/dev/null; then
    log_info "Detectando via ibdev2netdev..."
    UP_IFACE=$(ibdev2netdev 2>/dev/null | awk '/Up\)/ {print $5}' | tr -d '()' | head -1)
    if [ -n "$UP_IFACE" ]; then
        DIRECT_IFACE="$UP_IFACE"
        log_ok "Interface RDMA detectada: ${DIRECT_IFACE}"
    fi
fi

# Fallback: interface sem IP atribuído (provavelmente o cabo direto)
if [ -z "$DIRECT_IFACE" ]; then
    for iface in $(ip -br link show | grep -v lo | awk '{print $1}'); do
        HAS_IP=$(ip addr show "$iface" 2>/dev/null | grep "inet " | wc -l)
        if [ "$HAS_IP" -eq 0 ]; then
            DIRECT_IFACE="$iface"
            log_info "Interface sem IP (provável cabo direto): ${DIRECT_IFACE}"
            break
        fi
    done
fi

# Pedir confirmação
echo ""
read -p "  Interface do cabo direto entre os notebooks [$DIRECT_IFACE]: " INPUT_IFACE < /dev/tty
[ -n "$INPUT_IFACE" ] && DIRECT_IFACE="$INPUT_IFACE"

[ -z "$DIRECT_IFACE" ] && log_error "Nenhuma interface detectada. Conecte o cabo e tente novamente."

log_ok "Usando interface: ${DIRECT_IFACE}"

# ============================================================
# ETAPA 3 — Configurar IP estático na interface direta
# ============================================================
log_section "ETAPA 3: Configurando rede direta entre nós"

NETPLAN_FILE="/etc/netplan/99-cluster-direct.yaml"

# Backup se houver conflito
[ -f "$NETPLAN_FILE" ] && cp "$NETPLAN_FILE" "${NETPLAN_FILE}.bak"

cat > "$NETPLAN_FILE" << EOF
# Configuração de rede direta entre os 2 notebooks para IA
network:
  version: 2
  ethernets:
    ${DIRECT_IFACE}:
      dhcp4: no
      addresses:
        - ${THIS_IP}/24
      mtu: 9000
EOF

chmod 600 "$NETPLAN_FILE"
netplan apply
sleep 3

# Verificar se IP foi aplicado
ip addr show "$DIRECT_IFACE" | grep -q "$THIS_IP" \
    && log_ok "IP ${THIS_IP} configurado em ${DIRECT_IFACE}!" \
    || log_warn "IP pode não ter sido aplicado. Verifique manualmente."

# ============================================================
# ETAPA 4 — Configurar /etc/hosts
# ============================================================
log_section "ETAPA 4: Configurando /etc/hosts"

# Remover entradas antigas de cluster
sed -i '/# CLUSTER-IA-START/,/# CLUSTER-IA-END/d' /etc/hosts

cat >> /etc/hosts << EOF
# CLUSTER-IA-START
${THIS_IP}    ${THIS_HOSTNAME}
${OTHER_IP}   ${OTHER_HOSTNAME}
# CLUSTER-IA-END
EOF

log_ok "/etc/hosts atualizado!"

# ============================================================
# ETAPA 5 — Configurar hostname
# ============================================================
log_section "ETAPA 5: Configurando hostname"

hostnamectl set-hostname "$THIS_HOSTNAME"
log_ok "Hostname definido como: ${THIS_HOSTNAME}"

# ============================================================
# ETAPA 6 — Configurar SSH sem senha
# ============================================================
log_section "ETAPA 6: Configurando SSH sem senha"

SSH_DIR="${REAL_HOME}/.ssh"

# Criar .ssh com dono correto (como root cria errado!)
mkdir -p "$SSH_DIR"
chown "${REAL_USER}:${REAL_USER}" "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Gerar chave SSH se não existir
if [ ! -f "${SSH_DIR}/id_rsa" ]; then
    # Garantir que o arquivo será do usuário correto
    sudo -u "$REAL_USER" ssh-keygen -t rsa -b 4096 \
        -f "${SSH_DIR}/id_rsa" \
        -N "" \
        -C "${REAL_USER}@${THIS_HOSTNAME}" \
        2>&1 || {
            # Fallback: gerar como root e corrigir permissões
            log_warn "Tentando gerar chave via root..."
            ssh-keygen -t rsa -b 4096 \
                -f "${SSH_DIR}/id_rsa" \
                -N "" \
                -C "${REAL_USER}@${THIS_HOSTNAME}"
            chown "${REAL_USER}:${REAL_USER}" "${SSH_DIR}/id_rsa" "${SSH_DIR}/id_rsa.pub"
        }
    chmod 600 "${SSH_DIR}/id_rsa"
    chmod 644 "${SSH_DIR}/id_rsa.pub"
    log_ok "Par de chaves SSH gerado!"
else
    log_info "Chave SSH já existe."
fi

# Adicionar chave ao authorized_keys do próprio nó
cat "${SSH_DIR}/id_rsa.pub" >> "${SSH_DIR}/authorized_keys" 2>/dev/null || true
chown "${REAL_USER}:${REAL_USER}" "${SSH_DIR}/authorized_keys" 2>/dev/null || true
chmod 600 "${SSH_DIR}/authorized_keys" 2>/dev/null || true

# Configurar SSH para cluster
cat > /etc/ssh/sshd_config.d/cluster.conf << EOF
# Configuração para cluster IA
ClientAliveInterval 60
ClientAliveCountMax 20
TCPKeepAlive yes
MaxSessions 50
EOF

systemctl restart ssh
log_ok "SSH configurado para cluster!"

# ============================================================
# ETAPA 7 — NFS para pasta compartilhada
# ============================================================
log_section "ETAPA 7: Configurando pasta compartilhada (NFS)"

NFS_SHARE="/srv/cluster"
mkdir -p "$NFS_SHARE"
chown "$REAL_USER:$REAL_USER" "$NFS_SHARE"

if [ "$NODE_NUMBER" -eq 1 ]; then
    # Nó 1 = servidor NFS
    log_info "Configurando Nó 1 como servidor NFS..."

    echo "${NFS_SHARE} ${OTHER_IP}(rw,sync,no_subtree_check,no_root_squash)" \
        >> /etc/exports

    exportfs -ra
    systemctl enable nfs-kernel-server --quiet
    systemctl restart nfs-kernel-server

    log_ok "Pasta compartilhada em: ${NFS_SHARE} (servidor NFS)"
else
    # Nó 2 = cliente NFS
    log_info "Configurando Nó 2 como cliente NFS..."

    MOUNT_POINT="/srv/cluster"
    mkdir -p "$MOUNT_POINT"

    # Adicionar ao fstab para montar automaticamente
    grep -q "cluster" /etc/fstab || \
        echo "${OTHER_IP}:${NFS_SHARE} ${MOUNT_POINT} nfs defaults,_netdev 0 0" \
            >> /etc/fstab

    log_ok "NFS configurado. Monte com: mount ${OTHER_IP}:${NFS_SHARE} ${MOUNT_POINT}"
fi

# ============================================================
# ETAPA 8 — Arquivo MPI hostfile
# ============================================================
log_section "ETAPA 8: Criando arquivo de hosts MPI"

HOSTFILE="${REAL_HOME}/cluster_hostfile"

cat > "$HOSTFILE" << EOF
# MPI Hostfile — Cluster IA 2 Nós
# Uso: mpirun -np 4 --hostfile ~/cluster_hostfile python3 script.py
node1 slots=8
node2 slots=8
EOF

chown "$REAL_USER:$REAL_USER" "$HOSTFILE"
log_ok "Hostfile MPI criado: ${HOSTFILE}"

# ============================================================
# ETAPA 9 — Instalar Python AI Stack
# ============================================================
log_section "ETAPA 9: Instalando stack Python para IA"

# Ubuntu 24 usa PEP 668 — precisa de venv ou --break-system-packages
VENV_DIR="${REAL_HOME}/ia-venv"

if [ ! -d "$VENV_DIR" ]; then
    log_info "Criando ambiente virtual Python em ${VENV_DIR}..."
    sudo -u "$REAL_USER" python3 -m venv "$VENV_DIR"
fi

log_info "Instalando pacotes IA no venv..."
sudo -u "$REAL_USER" "${VENV_DIR}/bin/pip" install --quiet --upgrade pip
sudo -u "$REAL_USER" "${VENV_DIR}/bin/pip" install --quiet \
    torch \
    torchvision \
    torchaudio \
    transformers \
    accelerate \
    datasets \
    mpi4py \
    numpy \
    huggingface_hub \
    2>/dev/null || log_warn "Alguns pacotes falharam. Instale manualmente: source ~/ia-venv/bin/activate && pip install torch transformers"

# Adicionar alias ao .bashrc do usuário
BASHRC="${REAL_HOME}/.bashrc"
grep -q "ia-venv" "$BASHRC" 2>/dev/null || \
    echo -e "\n# Cluster IA venv\nalias ia='source ~/ia-venv/bin/activate'" >> "$BASHRC"
chown "${REAL_USER}:${REAL_USER}" "$BASHRC"

log_ok "Stack Python para IA instalado em: ${VENV_DIR}"
log_info "Para ativar: source ~/ia-venv/bin/activate  (ou simplesmente: ia)"

# ============================================================
# ETAPA 10 — Script de teste de conectividade
# ============================================================
log_section "ETAPA 10: Criando scripts utilitários"

TEST_SCRIPT="${REAL_HOME}/test-cluster.sh"
cat > "$TEST_SCRIPT" << TESTSCRIPT
#!/bin/bash
# Teste de conectividade do cluster

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "=== Teste de Conectividade do Cluster ==="
echo ""

# Ping
echo -n "Ping para o outro nó... "
if ping -c 3 -W 2 ${OTHER_IP} &>/dev/null; then
    echo -e "\${GREEN}✓ OK\${NC} (${OTHER_IP})"
else
    echo -e "\${RED}✗ FALHOU\${NC}"
fi

# SSH
echo -n "SSH para o outro nó... "
if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    ${REAL_USER}@${OTHER_IP} echo "ok" &>/dev/null; then
    echo -e "\${GREEN}✓ OK\${NC}"
else
    echo -e "\${RED}✗ FALHOU\${NC} (distribua as chaves SSH primeiro!)"
fi

# Velocidade de rede
echo ""
echo "=== Teste de Velocidade ==="
if command -v iperf3 &>/dev/null; then
    echo "Rodando iperf3... (precisa do servidor no outro nó: iperf3 -s)"
    iperf3 -c ${OTHER_IP} -t 5 2>/dev/null || echo "Inicie iperf3 -s no outro nó primeiro"
else
    echo "Instale iperf3: sudo apt install iperf3"
fi

# MPI test
echo ""
echo "=== Teste MPI ==="
mpirun -np 2 --hostfile ~/cluster_hostfile \
    -mca btl_tcp_if_include ${DIRECT_IFACE} \
    hostname 2>/dev/null || echo "Configure SSH sem senha primeiro."

echo ""
echo "=== GPU Status ==="
if command -v nvidia-smi &>/dev/null; then
    nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
else
    echo "nvidia-smi não encontrado"
fi
TESTSCRIPT

chmod +x "$TEST_SCRIPT"
chown "$REAL_USER:$REAL_USER" "$TEST_SCRIPT"

# Script para distribuir chave SSH
KEY_SCRIPT="${REAL_HOME}/setup-ssh-keys.sh"
cat > "$KEY_SCRIPT" << KEYSCRIPT
#!/bin/bash
# Distribui sua chave SSH para o outro nó
echo "Copiando chave SSH para o outro nó (${OTHER_IP})..."
echo "Você precisará digitar a senha do ${OTHER_IP} uma única vez:"
ssh-copy-id -i ~/.ssh/id_rsa.pub ${REAL_USER}@${OTHER_IP}
echo ""
echo "✓ Pronto! Teste com: ssh ${REAL_USER}@${OTHER_IP}"
KEYSCRIPT

chmod +x "$KEY_SCRIPT"
chown "$REAL_USER:$REAL_USER" "$KEY_SCRIPT"

log_ok "Scripts utilitários criados!"

# ============================================================
# RESUMO FINAL
# ============================================================
log_section "✅ INSTALAÇÃO CONCLUÍDA!"

echo -e "${GREEN}  Este nó:${NC}"
echo -e "    Hostname : ${THIS_HOSTNAME}"
echo -e "    IP direto: ${THIS_IP} (${DIRECT_IFACE})"
echo -e "    Usuário  : ${REAL_USER}"
echo ""
echo -e "${CYAN}  Outro nó:${NC}"
echo -e "    Hostname : ${OTHER_HOSTNAME}"
echo -e "    IP direto: ${OTHER_IP}"
echo ""

echo -e "${YELLOW}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║  PRÓXIMOS PASSOS (em ordem):                         ║${NC}"
echo -e "${YELLOW}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}1.${NC} Rode este script no ${GREEN}OUTRO notebook${NC} também"
echo ""
echo -e "  ${CYAN}2.${NC} Em CADA notebook, distribua a chave SSH:"
echo -e "     ${GREEN}bash ~/setup-ssh-keys.sh${NC}"
echo ""
echo -e "  ${CYAN}3.${NC} Teste a conexão:"
echo -e "     ${GREEN}bash ~/test-cluster.sh${NC}"
echo ""
echo -e "  ${CYAN}4.${NC} Se Nó 2, monte a pasta compartilhada:"
echo -e "     ${GREEN}sudo mount ${OTHER_IP}:/srv/cluster /srv/cluster${NC}"
echo ""
echo -e "  ${CYAN}5.${NC} Rodar IA distribuída (exemplo):"
echo -e "     ${GREEN}mpirun -np 4 --hostfile ~/cluster_hostfile \\"
echo -e "       python3 seu_script_ia.py${NC}"
echo ""
echo -e "${MAGENTA}  📁 Pasta compartilhada: /srv/cluster${NC}"
echo -e "${MAGENTA}  🔑 Distribuir chaves:   ~/setup-ssh-keys.sh${NC}"
echo -e "${MAGENTA}  🧪 Testar cluster:      ~/test-cluster.sh${NC}"
echo ""
