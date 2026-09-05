#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 equipelsquid
# Baseado em: https://github.com/NVIDIA/dgx-spark-playbooks/tree/main/nvidia/connect-two-sparks
#
# ============================================================
#  CONECTAR 2 NOTEBOOKS UBUNTU PARA RODAR IA EM CONJUNTO
#
#  Uso (em CADA notebook):
#     sudo bash cluster-ia-setup.sh 1     # no notebook 1 (primário)
#     sudo bash cluster-ia-setup.sh 2     # no notebook 2 (secundário)
#
#  Pode rodar de novo quantas vezes quiser (é idempotente).
# ============================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

log_ok()    { echo -e "${GREEN}[✓]${NC} $1"; }
log_info()  { echo -e "${CYAN}[→]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗] ERRO: $1${NC}"; exit 1; }
log_section() {
    echo ""
    echo -e "${MAGENTA}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║  $1${NC}"
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ============================================================
# Verificações iniciais
# ============================================================
[ "$EUID" -ne 0 ] && log_error "Execute com: sudo bash $0 1   (ou 2)"

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"
[ "$REAL_USER" = "root" ] && log_error "Rode com 'sudo' a partir do seu usuário normal, não logado como root."
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
[ -d "$REAL_HOME" ] || log_error "Pasta home de ${REAL_USER} não encontrada."

export DEBIAN_FRONTEND=noninteractive

clear
echo -e "${CYAN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║   🤖 Setup Cluster IA — 2 Notebooks Ubuntu       ║"
echo "  ║   Baseado em NVIDIA DGX Spark Playbooks          ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "${YELLOW}Este script deve ser executado em AMBAS as máquinas.${NC}"
echo -e "Usuário: ${GREEN}${REAL_USER}${NC}  (precisa ser o MESMO nome nos 2 notebooks)"
echo ""

# ============================================================
# Qual nó é este (argumento $1 ou pergunta)
# ============================================================
if [ -n "${1:-}" ]; then
    NODE_NUMBER="$1"
else
    echo "  Qual é este notebook?"
    echo -e "  ${CYAN}1${NC}) Notebook 1 (PRIMÁRIO   — IP: 10.0.0.1)"
    echo -e "  ${CYAN}2${NC}) Notebook 2 (SECUNDÁRIO — IP: 10.0.0.2)"
    echo ""
    read -r -p "  Digite 1 ou 2: " NODE_NUMBER < /dev/tty
fi

case "$NODE_NUMBER" in
    1) THIS_IP="10.0.0.1"; OTHER_IP="10.0.0.2"; THIS_HOSTNAME="node1"; OTHER_HOSTNAME="node2"
       log_ok "Configurando como Nó PRIMÁRIO (10.0.0.1)" ;;
    2) THIS_IP="10.0.0.2"; OTHER_IP="10.0.0.1"; THIS_HOSTNAME="node2"; OTHER_HOSTNAME="node1"
       log_ok "Configurando como Nó SECUNDÁRIO (10.0.0.2)" ;;
    *) log_error "Opção inválida. Use: sudo bash $0 1   (ou 2)" ;;
esac

# ============================================================
# ETAPA 1 — Dependências
# ============================================================
log_section "ETAPA 1: Instalando dependências"

apt-get update -qq
apt-get install -y -qq \
    openssh-server openssh-client \
    iproute2 net-tools ethtool iperf3 \
    openmpi-bin openmpi-common libopenmpi-dev \
    nfs-kernel-server nfs-common \
    python3 python3-pip python3-venv \
    htop curl wget git

systemctl enable --now ssh >/dev/null 2>&1 || true
log_ok "Dependências instaladas!"

# ============================================================
# ETAPA 2 — Detectar interface do cabo direto
# ============================================================
log_section "ETAPA 2: Detectando interface de rede do cabo"

# Cabo USB-C / Thunderbolt entre notebooks cria a interface "thunderbolt0"
modprobe thunderbolt-net 2>/dev/null || true
sleep 1

echo -e "${CYAN}Interfaces disponíveis (estado / link):${NC}"
echo ""
ip -br link show | awk '$1!="lo"{printf "   %-16s %s\n",$1,$2}'
echo ""

list_ifaces() { ip -o link show | awk -F': ' '{print $2}' | cut -d@ -f1; }
is_candidate() {
    case "$1" in
        lo|wl*|docker*|virbr*|veth*|br-*|tun*|tap*|vmnet*|wg*) return 1 ;;
    esac
    return 0
}
has_ipv4() { ip -4 -o addr show "$1" 2>/dev/null | grep -q 'inet '; }
has_carrier() { [ "$(cat "/sys/class/net/$1/carrier" 2>/dev/null)" = "1" ]; }

DIRECT_IFACE=""
# 1) Cabeada, com cabo conectado, sem IPv4
for iface in $(list_ifaces); do
    is_candidate "$iface" || continue
    if ! has_ipv4 "$iface" && has_carrier "$iface"; then DIRECT_IFACE="$iface"; break; fi
done
# 2) Cabeada sem IPv4 (mesmo sem carrier)
if [ -z "$DIRECT_IFACE" ]; then
    for iface in $(list_ifaces); do
        is_candidate "$iface" || continue
        if ! has_ipv4 "$iface"; then DIRECT_IFACE="$iface"; break; fi
    done
fi
# 3) Já configurada com o IP do cluster (re-execução)
if [ -z "$DIRECT_IFACE" ]; then
    DIRECT_IFACE=$(ip -4 -o addr show | awk -v ip="$THIS_IP/" 'index($4, ip)==1 {print $2; exit}')
fi

[ -n "$DIRECT_IFACE" ] && log_info "Provável interface do cabo: ${DIRECT_IFACE}"
echo ""
read -r -p "  Interface do cabo direto entre os notebooks [${DIRECT_IFACE}]: " INPUT_IFACE < /dev/tty
[ -n "$INPUT_IFACE" ] && DIRECT_IFACE="$INPUT_IFACE"
[ -z "$DIRECT_IFACE" ] && log_error "Nenhuma interface detectada. Conecte o cabo e rode de novo."
[ -d "/sys/class/net/${DIRECT_IFACE}" ] || log_error "Interface '${DIRECT_IFACE}' não existe."

log_ok "Usando interface: ${DIRECT_IFACE}"

# ============================================================
# ETAPA 3 — IP fixo na interface direta
# ============================================================
log_section "ETAPA 3: Configurando rede direta entre nós"

ip link set "$DIRECT_IFACE" up 2>/dev/null || true

if systemctl is-active --quiet NetworkManager && command -v nmcli >/dev/null; then
    # Ubuntu Desktop: NetworkManager gerencia a rede — configura via nmcli
    log_info "NetworkManager detectado — configurando via nmcli"
    nmcli device set "$DIRECT_IFACE" managed yes 2>/dev/null || true
    nmcli connection delete cluster-direct >/dev/null 2>&1 || true
    nmcli connection add type ethernet ifname "$DIRECT_IFACE" con-name cluster-direct \
        ipv4.method manual ipv4.addresses "${THIS_IP}/24" ipv4.never-default yes \
        ipv6.method disabled \
        connection.autoconnect yes connection.autoconnect-priority 100 >/dev/null
    nmcli connection up cluster-direct >/dev/null || log_warn "nmcli não conseguiu ativar a conexão"
    # Remove arquivo netplan de versão antiga deste script, se existir
    rm -f /etc/netplan/99-cluster-direct.yaml
else
    # Ubuntu Server: netplan + systemd-networkd
    log_info "Configurando via netplan (systemd-networkd)"
    NETPLAN_FILE="/etc/netplan/99-cluster-direct.yaml"
    cat > "$NETPLAN_FILE" <<EOF
# Rede direta entre os 2 notebooks (cluster IA)
network:
  version: 2
  renderer: networkd
  ethernets:
    ${DIRECT_IFACE}:
      dhcp4: false
      dhcp6: false
      addresses: [${THIS_IP}/24]
EOF
    chmod 600 "$NETPLAN_FILE"
    netplan apply
fi
sleep 3

if ip -4 addr show "$DIRECT_IFACE" | grep -q "inet ${THIS_IP}/"; then
    log_ok "IP ${THIS_IP} configurado em ${DIRECT_IFACE}!"
else
    log_warn "IP não apareceu em ${DIRECT_IFACE}. Verifique com: ip addr show ${DIRECT_IFACE}"
fi

# Firewall (se ativo) libera a rede do cluster
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow from 10.0.0.0/24 >/dev/null && log_ok "ufw: rede 10.0.0.0/24 liberada"
fi

# ============================================================
# ETAPA 4 — /etc/hosts e hostname
# ============================================================
log_section "ETAPA 4: Configurando hostname e /etc/hosts"

hostnamectl set-hostname "$THIS_HOSTNAME"

sed -i '/# CLUSTER-IA-START/,/# CLUSTER-IA-END/d' /etc/hosts
# Atualiza a linha 127.0.1.1 (evita "sudo: unable to resolve host")
if grep -q '^127\.0\.1\.1' /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${THIS_HOSTNAME}/" /etc/hosts
else
    printf '127.0.1.1\t%s\n' "$THIS_HOSTNAME" >> /etc/hosts
fi
cat >> /etc/hosts <<EOF
# CLUSTER-IA-START
${THIS_IP}    ${THIS_HOSTNAME}
${OTHER_IP}   ${OTHER_HOSTNAME}
# CLUSTER-IA-END
EOF
log_ok "Hostname: ${THIS_HOSTNAME} | hosts: node1=10.0.0.1 node2=10.0.0.2"

# ============================================================
# ETAPA 5 — SSH sem senha
# ============================================================
log_section "ETAPA 5: Configurando SSH"

SSH_DIR="${REAL_HOME}/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown "${REAL_USER}:${REAL_USER}" "$SSH_DIR"

# NÃO apaga chaves existentes — só cria se não houver
if [ ! -f "${SSH_DIR}/id_ed25519" ]; then
    log_info "Gerando chave SSH (ed25519)..."
    sudo -u "$REAL_USER" ssh-keygen -t ed25519 -f "${SSH_DIR}/id_ed25519" -N "" \
        -C "${REAL_USER}@${THIS_HOSTNAME}" -q
else
    log_info "Chave SSH já existe, mantendo."
fi
touch "${SSH_DIR}/authorized_keys" "${SSH_DIR}/config"
chmod 600 "${SSH_DIR}/authorized_keys" "${SSH_DIR}/config" "${SSH_DIR}/id_ed25519"

# Atalhos: "ssh node1" / "ssh node2" sem perguntar nada
sed -i '/# CLUSTER-IA-START/,/# CLUSTER-IA-END/d' "${SSH_DIR}/config"
cat >> "${SSH_DIR}/config" <<EOF
# CLUSTER-IA-START
Host node1 10.0.0.1
    HostName 10.0.0.1
    User ${REAL_USER}
    StrictHostKeyChecking accept-new
Host node2 10.0.0.2
    HostName 10.0.0.2
    User ${REAL_USER}
    StrictHostKeyChecking accept-new
# CLUSTER-IA-END
EOF
chown -R "${REAL_USER}:${REAL_USER}" "$SSH_DIR"

cat > /etc/ssh/sshd_config.d/cluster.conf <<EOF
# Cluster IA
ClientAliveInterval 60
ClientAliveCountMax 20
TCPKeepAlive yes
MaxSessions 50
MaxStartups 50:30:100
EOF
systemctl restart ssh
log_ok "SSH pronto. Chave: ${SSH_DIR}/id_ed25519.pub"

# ============================================================
# ETAPA 6 — Pasta compartilhada (NFS)
# ============================================================
log_section "ETAPA 6: Pasta compartilhada /srv/cluster (NFS)"

NFS_SHARE="/srv/cluster"
mkdir -p "$NFS_SHARE"

if [ "$NODE_NUMBER" -eq 1 ]; then
    chown "$REAL_USER:$REAL_USER" "$NFS_SHARE"
    EXPORT_LINE="${NFS_SHARE} 10.0.0.0/24(rw,sync,no_subtree_check,no_root_squash)"
    touch /etc/exports
    if grep -qF "${NFS_SHARE} " /etc/exports; then
        sed -i "s#^${NFS_SHARE} .*#${EXPORT_LINE}#" /etc/exports
    else
        echo "$EXPORT_LINE" >> /etc/exports
    fi
    exportfs -ra
    systemctl enable --now nfs-kernel-server >/dev/null 2>&1 || true
    systemctl restart nfs-kernel-server
    log_ok "Nó 1 é o servidor NFS: ${NFS_SHARE}"
else
    FSTAB_LINE="${OTHER_IP}:${NFS_SHARE} ${NFS_SHARE} nfs defaults,_netdev,nofail,x-systemd.automount,x-systemd.idle-timeout=600 0 0"
    if grep -qF "${OTHER_IP}:${NFS_SHARE}" /etc/fstab; then
        sed -i "s#^${OTHER_IP}:${NFS_SHARE} .*#${FSTAB_LINE}#" /etc/fstab
    else
        echo "$FSTAB_LINE" >> /etc/fstab
    fi
    systemctl daemon-reload
    if mount "$NFS_SHARE" 2>/dev/null; then
        log_ok "Pasta do Nó 1 montada em ${NFS_SHARE}"
    else
        log_warn "Não montou agora (Nó 1 ainda não configurado?). Monta sozinho quando acessar ${NFS_SHARE}."
    fi
fi

# ============================================================
# ETAPA 7 — Hostfile MPI + variáveis de ambiente do cluster
# ============================================================
log_section "ETAPA 7: Configuração MPI / PyTorch distribuído"

NPROC=$(nproc)
HOSTFILE="${REAL_HOME}/cluster_hostfile"
cat > "$HOSTFILE" <<EOF
# MPI Hostfile — Cluster IA 2 Nós
# Uso: mpirun -np 2 --hostfile ~/cluster_hostfile python3 script.py
node1 slots=${NPROC}
node2 slots=${NPROC}
EOF
chown "$REAL_USER:$REAL_USER" "$HOSTFILE"

# Variáveis que fazem PyTorch/NCCL/MPI usarem o cabo direto
CLUSTER_ENV="${REAL_HOME}/.cluster-env"
cat > "$CLUSTER_ENV" <<EOF
# Ambiente do cluster IA (gerado por cluster-ia-setup.sh)
export CLUSTER_IFACE="${DIRECT_IFACE}"
export CLUSTER_NODE="${NODE_NUMBER}"
export CLUSTER_MASTER="10.0.0.1"
export NCCL_SOCKET_IFNAME="${DIRECT_IFACE}"
export GLOO_SOCKET_IFNAME="${DIRECT_IFACE}"
export NCCL_IB_DISABLE=1
export OMPI_MCA_btl_tcp_if_include="${DIRECT_IFACE}"
export OMPI_MCA_oob_tcp_if_include="${DIRECT_IFACE}"
EOF
chown "$REAL_USER:$REAL_USER" "$CLUSTER_ENV"

BASHRC="${REAL_HOME}/.bashrc"
if ! grep -q "cluster-env" "$BASHRC" 2>/dev/null; then
    cat >> "$BASHRC" <<'EOF'

# Cluster IA
[ -f ~/.cluster-env ] && source ~/.cluster-env
alias ia='source ~/ia-venv/bin/activate'
EOF
fi
chown "$REAL_USER:$REAL_USER" "$BASHRC"
log_ok "Hostfile: ${HOSTFILE} | Ambiente: ${CLUSTER_ENV}"

# ============================================================
# ETAPA 8 — Stack Python de IA (venv)
# ============================================================
log_section "ETAPA 8: Instalando PyTorch e bibliotecas de IA (demora!)"

VENV_DIR="${REAL_HOME}/ia-venv"
if [ ! -d "$VENV_DIR" ]; then
    log_info "Criando ambiente virtual em ${VENV_DIR}..."
    sudo -u "$REAL_USER" python3 -m venv "$VENV_DIR"
fi

log_info "Baixando pacotes (torch tem ~2 GB, pode levar vários minutos)..."
sudo -u "$REAL_USER" "${VENV_DIR}/bin/pip" install -q --upgrade pip
if sudo -u "$REAL_USER" "${VENV_DIR}/bin/pip" install -q \
        torch torchvision torchaudio transformers accelerate datasets \
        mpi4py numpy huggingface_hub; then
    log_ok "Stack Python instalado em ${VENV_DIR}"
else
    log_warn "Alguns pacotes falharam. Depois rode: ia && pip install torch transformers accelerate mpi4py"
fi

# ============================================================
# ETAPA 9 — Scripts utilitários
# ============================================================
log_section "ETAPA 9: Criando scripts utilitários"

# --- distribuir chave SSH ---
cat > "${REAL_HOME}/setup-ssh-keys.sh" <<KEYSCRIPT
#!/bin/bash
# Copia sua chave SSH para o outro nó (digite a senha dele UMA vez)
echo "Copiando chave para ${REAL_USER}@${OTHER_IP} ..."
if ssh-copy-id -i ~/.ssh/id_ed25519.pub -o StrictHostKeyChecking=accept-new ${REAL_USER}@${OTHER_IP}; then
    echo "✓ Pronto! Teste com:  ssh ${OTHER_HOSTNAME}"
else
    echo "✗ Falhou. O outro notebook já rodou o cluster-ia-setup.sh? O usuário lá também é '${REAL_USER}'?"
fi
KEYSCRIPT

# --- teste do cluster ---
cat > "${REAL_HOME}/test-cluster.sh" <<TESTSCRIPT
#!/bin/bash
# Teste de conectividade do cluster
source ~/.cluster-env
G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'
ok(){ echo -e "\${G}✓ OK\${N} \$1"; }
fail(){ echo -e "\${R}✗ FALHOU\${N} \$1"; }

echo "=== Teste de Conectividade ==="
echo -n "Ping ${OTHER_HOSTNAME} (${OTHER_IP})... "
if ping -c 3 -W 2 ${OTHER_IP} >/dev/null 2>&1; then ok; else fail "(cabo conectado? outro nó configurado?)"; fi

echo -n "SSH sem senha para ${OTHER_HOSTNAME}... "
if ssh -o BatchMode=yes -o ConnectTimeout=5 ${OTHER_HOSTNAME} true 2>/dev/null; then ok; else fail "(rode: bash ~/setup-ssh-keys.sh)"; fi

echo -n "Pasta compartilhada /srv/cluster... "
if touch "/srv/cluster/.teste-\$(hostname)" 2>/dev/null; then ok; else fail; fi

echo ""
echo "=== Velocidade do cabo (iperf3) ==="
ssh -o BatchMode=yes ${OTHER_HOSTNAME} "pkill iperf3; nohup iperf3 -s -1 >/dev/null 2>&1 &" 2>/dev/null
sleep 1
iperf3 -c ${OTHER_IP} -t 5 2>/dev/null | grep -E "receiver|sender" || echo "iperf3 não rodou (precisa do SSH sem senha)"

echo ""
echo "=== Teste MPI (os 2 nós respondem?) ==="
mpirun -np 2 --hostfile ~/cluster_hostfile --map-by node hostname 2>/dev/null || echo "MPI falhou (SSH sem senha configurado nos DOIS lados?)"

echo ""
echo "=== GPU ==="
if command -v nvidia-smi >/dev/null; then
    nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
    ssh -o BatchMode=yes ${OTHER_HOSTNAME} nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null
else
    echo "nvidia-smi não encontrado (sem GPU NVIDIA ou driver não instalado)"
fi
TESTSCRIPT

# --- teste PyTorch distribuído (all-reduce entre os 2 nós) ---
cat > "${REAL_HOME}/test-torch-distributed.py" <<'PYSCRIPT'
import os, socket, torch, torch.distributed as dist

backend = "nccl" if torch.cuda.is_available() else "gloo"
dist.init_process_group(backend=backend)
rank, world = dist.get_rank(), dist.get_world_size()
if backend == "nccl":
    torch.cuda.set_device(int(os.environ.get("LOCAL_RANK", 0)))
    dev = torch.device("cuda")
else:
    dev = torch.device("cpu")

x = torch.full((1024, 1024), float(rank + 1), device=dev)
dist.all_reduce(x, op=dist.ReduceOp.SUM)
esperado = sum(range(1, world + 1))
print(f"[{socket.gethostname()}] rank {rank}/{world} backend={backend} "
      f"all_reduce={x[0,0].item():.0f} (esperado {esperado}) -> "
      f"{'OK' if x[0,0].item() == esperado else 'ERRO'}")
dist.barrier()
dist.destroy_process_group()
PYSCRIPT

# --- rodar IA nos 2 nós com um comando só ---
cat > "${REAL_HOME}/run-ia.sh" <<'RUNSCRIPT'
#!/bin/bash
# Roda um script Python nos 2 notebooks ao mesmo tempo (torchrun).
#   bash ~/run-ia.sh seu_script.py [args...]
# Rode SEMPRE a partir do node1. O script precisa existir no mesmo caminho nos 2 nós
# (dica: coloque em /srv/cluster, que é compartilhada).
source ~/.cluster-env
[ -z "$1" ] && { echo "Uso: bash ~/run-ia.sh script.py [args]"; exit 1; }
SCRIPT=$(readlink -f "$1"); shift
DIR=$(dirname "$SCRIPT")
PY=~/ia-venv/bin/python
NPROC=${NPROC_PER_NODE:-1}
COMMON="--nnodes=2 --nproc_per_node=$NPROC --master_addr=10.0.0.1 --master_port=29500"

echo "→ Iniciando node2..."
ssh -o BatchMode=yes node2 "source ~/.cluster-env; cd '$DIR'; nohup ~/ia-venv/bin/python -m torch.distributed.run $COMMON --node_rank=1 '$SCRIPT' $* > ~/run-ia-node2.log 2>&1 &" \
    || { echo "✗ Não conectou no node2"; exit 1; }
echo "→ Iniciando node1..."
cd "$DIR"
$PY -m torch.distributed.run $COMMON --node_rank=0 "$SCRIPT" "$@"
echo ""
echo "--- saída do node2 ---"
ssh node2 cat ~/run-ia-node2.log
RUNSCRIPT

chmod +x "${REAL_HOME}/setup-ssh-keys.sh" "${REAL_HOME}/test-cluster.sh" "${REAL_HOME}/run-ia.sh"
chown "$REAL_USER:$REAL_USER" "${REAL_HOME}/setup-ssh-keys.sh" "${REAL_HOME}/test-cluster.sh" \
    "${REAL_HOME}/run-ia.sh" "${REAL_HOME}/test-torch-distributed.py"
log_ok "Scripts criados na home de ${REAL_USER}"

# ============================================================
# RESUMO
# ============================================================
log_section "✅ INSTALAÇÃO CONCLUÍDA NESTE NÓ"

if [ "$NODE_NUMBER" -eq 1 ]; then OTHER_NUMBER=2; else OTHER_NUMBER=1; fi

echo -e "${GREEN}  Este nó:${NC}  ${THIS_HOSTNAME}  ${THIS_IP}  (${DIRECT_IFACE})  usuário: ${REAL_USER}"
echo -e "${CYAN}  Outro nó:${NC} ${OTHER_HOSTNAME}  ${OTHER_IP}"
echo ""
echo -e "${YELLOW}  PRÓXIMOS PASSOS (em ordem):${NC}"
echo ""
echo -e "  ${CYAN}1.${NC} Rode este script no ${GREEN}OUTRO notebook${NC} (se ainda não rodou):"
echo -e "     ${GREEN}sudo bash cluster-ia-setup.sh ${OTHER_NUMBER}${NC}"
echo ""
echo -e "  ${CYAN}2.${NC} Em CADA notebook (feche este terminal e abra outro antes), distribua a chave SSH:"
echo -e "     ${GREEN}bash ~/setup-ssh-keys.sh${NC}"
echo ""
echo -e "  ${CYAN}3.${NC} Teste tudo:"
echo -e "     ${GREEN}bash ~/test-cluster.sh${NC}"
echo ""
echo -e "  ${CYAN}4.${NC} Teste a IA rodando nos 2 ao mesmo tempo (no node1):"
echo -e "     ${GREEN}cp ~/test-torch-distributed.py /srv/cluster/ && bash ~/run-ia.sh /srv/cluster/test-torch-distributed.py${NC}"
echo ""
echo -e "${MAGENTA}  📁 Pasta compartilhada: /srv/cluster   🔑 ~/setup-ssh-keys.sh   🧪 ~/test-cluster.sh   🚀 ~/run-ia.sh${NC}"
echo ""
