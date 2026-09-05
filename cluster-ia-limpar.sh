#!/bin/bash
# ============================================================
#  LIMPAR TUDO que o connect-two-nodes.sh (antigo) ou o
#  cluster-ia-setup.sh (novo) configuraram neste notebook.
#
#  Uso:  sudo bash cluster-ia-limpar.sh
#
#  Depois de limpar, rode:  sudo bash cluster-ia-setup.sh 1  (ou 2)
# ============================================================

set -u

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
log_info() { echo -e "${CYAN}[→]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
die()      { echo -e "${RED}[✗] ERRO: $1${NC}"; exit 1; }
ask() {  # ask "pergunta" "s|n"  -> retorna 0 se sim
    local resp default="$2"
    read -r -p "  $1 [$( [ "$default" = s ] && echo S/n || echo s/N )]: " resp < /dev/tty
    resp="${resp:-$default}"
    [[ "$resp" =~ ^[sSyY] ]]
}

[ "$EUID" -ne 0 ] && die "Execute com: sudo bash $0"
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"
[ "$REAL_USER" = "root" ] && die "Rode com 'sudo' a partir do seu usuário normal."
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

echo ""
echo -e "${YELLOW}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║  🧹 Limpeza do Cluster IA — usuário: ${REAL_USER}${NC}"
echo -e "${YELLOW}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Isso desfaz: rede 10.0.0.x, hostname node1/node2, /etc/hosts,"
echo "  config SSH do cluster, NFS (/srv/cluster), hostfile MPI, scripts na home."
echo ""
ask "Continuar?" n || { echo "Cancelado."; exit 0; }
echo ""

# ---------- 1. Rede ----------
log_info "Rede direta (10.0.0.x)"
if command -v nmcli >/dev/null && systemctl is-active --quiet NetworkManager; then
    nmcli connection delete cluster-direct >/dev/null 2>&1 && log_ok "Conexão nmcli 'cluster-direct' removida"
fi
if ls /etc/netplan/99-cluster-direct.yaml* >/dev/null 2>&1; then
    rm -f /etc/netplan/99-cluster-direct.yaml /etc/netplan/99-cluster-direct.yaml.bak
    netplan apply 2>/dev/null || true
    log_ok "Netplan do cluster removido"
fi
# Tira o IP na mão, caso ainda esteja na interface
for ip in 10.0.0.1 10.0.0.2; do
    IF=$(ip -4 -o addr show | awk -v ip="$ip/" 'index($4, ip)==1 {print $2; exit}')
    if [ -n "$IF" ]; then
        ip addr del "$ip/24" dev "$IF" 2>/dev/null && log_ok "IP $ip removido de $IF"
        ip link set "$IF" mtu 1500 2>/dev/null || true
    fi
done
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw --force delete allow from 10.0.0.0/24 >/dev/null 2>&1 && log_ok "Regra ufw removida"
fi

# ---------- 2. Hostname e /etc/hosts ----------
log_info "Hostname e /etc/hosts"
sed -i '/# CLUSTER-IA-START/,/# CLUSTER-IA-END/d' /etc/hosts
CUR_HOST=$(hostname)
if [[ "$CUR_HOST" == node1 || "$CUR_HOST" == node2 ]]; then
    read -r -p "  Hostname atual é '$CUR_HOST'. Novo hostname (Enter = manter): " NEW_HOST < /dev/tty
    if [ -n "$NEW_HOST" ]; then
        hostnamectl set-hostname "$NEW_HOST"
        sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${NEW_HOST}/" /etc/hosts
        log_ok "Hostname alterado para $NEW_HOST"
    fi
fi
log_ok "/etc/hosts limpo"

# ---------- 3. SSH ----------
log_info "SSH"
rm -f /etc/ssh/sshd_config.d/cluster.conf
systemctl restart ssh 2>/dev/null || true
SSH_DIR="${REAL_HOME}/.ssh"
if [ -d "$SSH_DIR" ]; then
    [ -f "$SSH_DIR/config" ] && sed -i '/# CLUSTER-IA-START/,/# CLUSTER-IA-END/d' "$SSH_DIR/config"
    for h in node1 node2 10.0.0.1 10.0.0.2; do
        sudo -u "$REAL_USER" ssh-keygen -R "$h" -f "$SSH_DIR/known_hosts" >/dev/null 2>&1 || true
    done
    rm -f "$SSH_DIR"/known_hosts.old
    # Remove SÓ as chaves geradas pelos scripts do cluster (comentário usuario@node1 / @node2)
    for key in "$SSH_DIR/id_rsa" "$SSH_DIR/id_ed25519"; do
        if [ -f "$key.pub" ] && grep -qE "${REAL_USER}@node[12]$" "$key.pub"; then
            if ask "Apagar chave SSH gerada pelo cluster ($(basename "$key"))?" s; then
                PUB=$(cut -d' ' -f2 "$key.pub")
                [ -f "$SSH_DIR/authorized_keys" ] && sed -i "\#${PUB}#d" "$SSH_DIR/authorized_keys"
                rm -f "$key" "$key.pub"
                log_ok "$(basename "$key") apagada"
            fi
        fi
    done
    # Remove do authorized_keys chaves vindas do OUTRO nó
    [ -f "$SSH_DIR/authorized_keys" ] && sed -i "/${REAL_USER}@node[12]$/d" "$SSH_DIR/authorized_keys"
fi
log_ok "SSH limpo (chaves pessoais preservadas)"

# ---------- 4. NFS ----------
log_info "NFS (/srv/cluster)"
systemctl stop srv-cluster.automount 2>/dev/null || true
umount -l /srv/cluster 2>/dev/null || true
sed -i '\#/srv/cluster#d' /etc/fstab
if [ -f /etc/exports ]; then
    sed -i '\#^/srv/cluster #d' /etc/exports
    exportfs -ra 2>/dev/null || true
fi
systemctl daemon-reload
if [ -d /srv/cluster ]; then
    if [ -z "$(ls -A /srv/cluster 2>/dev/null)" ]; then
        rmdir /srv/cluster && log_ok "/srv/cluster (vazia) removida"
    elif ask "/srv/cluster tem arquivos. Apagar a pasta e TUDO dentro?" n; then
        rm -rf /srv/cluster && log_ok "/srv/cluster apagada"
    else
        log_warn "/srv/cluster mantida"
    fi
fi

# ---------- 5. Arquivos na home ----------
log_info "Arquivos na home de ${REAL_USER}"
for f in cluster_hostfile .cluster-env setup-ssh-keys.sh test-cluster.sh run-ia.sh \
         test-torch-distributed.py run-ia-node2.log; do
    rm -f "${REAL_HOME}/$f"
done
BASHRC="${REAL_HOME}/.bashrc"
if [ -f "$BASHRC" ]; then
    sed -i '/^# Cluster IA venv$/d; /^# Cluster IA$/d; /cluster-env/d; /alias ia=.*ia-venv/d' "$BASHRC"
fi
log_ok "Scripts, hostfile e alias removidos"

if [ -d "${REAL_HOME}/ia-venv" ]; then
    if ask "Apagar o ambiente Python ~/ia-venv (torch ~2 GB, o setup baixa de novo)?" n; then
        rm -rf "${REAL_HOME}/ia-venv" && log_ok "~/ia-venv apagado"
    else
        log_warn "~/ia-venv mantido (o setup reaproveita)"
    fi
fi

# ---------- 6. Pacotes apt ----------
# NUNCA remover pacotes aqui: avahi/libnss-mdns fazem parte do ubuntu-desktop e um
# "apt remove" + "autoremove" derruba o desktop inteiro. Os pacotes extras (openmpi,
# nfs, iperf3) sao pequenos e inofensivos; ficam instalados.

echo ""
log_ok "Limpeza concluída!"
echo ""
echo -e "  Agora rode o setup novo:  ${GREEN}sudo bash cluster-ia-setup.sh 1${NC}  (ou 2)"
echo -e "  Recomendado reiniciar antes: ${GREEN}sudo reboot${NC}"
echo ""
