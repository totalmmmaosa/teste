#!/bin/bash
# ============================================================
#  RESTAURAR SISTEMA — reinstala tudo que foi removido por engano
#  (desktop, rede, AnyDesk, bibliotecas) e conserta pacotes quebrados.
#
#  Uso:  sudo bash restaurar-sistema.sh
#
#  Não apaga nada. Só instala / reinstala. Pode rodar mais de uma vez.
#  Mostra tudo ao vivo e grava em /var/log/restaurar-sistema.log
#  Se não tiver terminal gráfico: Ctrl+Alt+F3, faça login e rode aqui.
# ============================================================

set -u
export DEBIAN_FRONTEND=noninteractive

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
TOTAL=8
etapa()    { echo ""; echo -e "${CYAN}════════ [$1/${TOTAL}] $2  ($(date +%H:%M:%S)) ════════${NC}"; }
log_ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
log_info() { echo -e "${CYAN}[→]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
die()      { echo -e "${RED}[✗] ERRO: $1${NC}"; exit 1; }

[ "$EUID" -ne 0 ] && die "Execute com: sudo bash $0"

LOG=/var/log/restaurar-sistema.log
exec > >(tee -a "$LOG") 2>&1

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  🛠  Restaurar sistema padrão (Ubuntu / DGX OS)   ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo -e "  Log: ${LOG}   Início: $(date)"

# ---------- 1. Rede ----------
etapa 1 "Internet"
if ping -c 2 -W 3 8.8.8.8; then
    log_ok "Internet OK"
else
    log_warn "Sem internet. Tentando levantar a rede..."
    systemctl start NetworkManager 2>/dev/null || true
    systemctl start systemd-networkd 2>/dev/null || true
    for i in /sys/class/net/en*; do
        [ -e "$i" ] || continue
        i=$(basename "$i")
        echo "  levantando $i"; ip link set "$i" up 2>/dev/null
        dhclient "$i" 2>/dev/null || dhcpcd "$i" 2>/dev/null || true
    done
    sleep 5
    ping -c 2 -W 3 8.8.8.8 || die "Ainda sem internet. Conecte o cabo do roteador (porta enP7s7) e rode de novo."
    log_ok "Rede levantada"
fi

# ---------- 2. apt/dpkg ----------
etapa 2 "Consertando apt/dpkg"
dpkg --configure -a || true
apt-get update || die "apt update falhou. Verifique a internet."
apt-get install -y --fix-broken || true
log_ok "apt OK"

# ---------- 3. O que foi removido ----------
etapa 3 "Lendo histórico do apt (o que foi removido)"
REMOVED=$( { cat /var/log/apt/history.log 2>/dev/null; zcat /var/log/apt/history.log.*.gz 2>/dev/null; } \
    | grep -E '^(Remove|Purge):' \
    | sed -E 's/^(Remove|Purge): //; s/\([^)]*\)//g; s/,/ /g; s/:[a-z0-9]+//g' \
    | tr ' ' '\n' | grep -v '^$' | sort -u)
COUNT=$(echo "$REMOVED" | grep -c . || true)
log_ok "${COUNT} pacotes já foram removidos alguma vez nesta máquina"
[ "$COUNT" -gt 0 ] && echo "$REMOVED" | head -30 | sed 's/^/     /' && [ "$COUNT" -gt 30 ] && echo "     ... (+$((COUNT-30)))"

# ---------- 4. Lista final ----------
etapa 4 "Montando lista de pacotes"
BASE_PKGS="
ubuntu-desktop-minimal ubuntu-desktop
gnome-shell gdm3 gnome-terminal gnome-control-center gnome-session nautilus
gnome-software gnome-text-editor gnome-system-monitor gnome-disk-utility
gnome-shell-extension-ubuntu-dock gnome-shell-extension-appindicator yaru-theme-gnome-shell
xdg-user-dirs xdg-utils fonts-ubuntu fonts-noto-color-emoji
network-manager network-manager-gnome avahi-daemon avahi-utils libnss-mdns
openssh-server openssh-client curl wget git vim nano htop
pulseaudio pipewire wireplumber
snapd firefox
"
ALL=$(echo "$REMOVED $BASE_PKGS" | tr ' ' '\n' | grep -v '^$' | sort -u)
log_info "Consultando o repositório sobre $(echo "$ALL" | wc -l) pacotes (uma consulta só)..."
# shellcheck disable=SC2086
TO_INSTALL=$(apt-cache policy $ALL 2>/dev/null | awk '
    /^[^ ].*:$/ { name=$1; sub(/:$/, "", name) }
    /^  Candidate:/ { if ($2 != "(none)") print name }
' | sort -u | tr '\n' ' ')
N=$(echo "$TO_INSTALL" | wc -w)
log_ok "${N} pacotes existem no repositório e serão instalados/reinstalados"

# ---------- 5. Instala ----------
etapa 5 "Instalando ${N} pacotes (acompanhe abaixo; pode levar vários minutos)"
# shellcheck disable=SC2086
if apt-get install -y $TO_INSTALL; then
    log_ok "Instalação em bloco concluída"
else
    log_warn "Instalação em bloco falhou. Instalando um por um (os que falharem são pulados)..."
    FAILED=""; i=0
    for p in $TO_INSTALL; do
        i=$((i+1)); echo -e "${CYAN}--- [$i/$N] $p${NC}"
        apt-get install -y "$p" || FAILED="$FAILED $p"
    done
    [ -n "$FAILED" ] && log_warn "Não instalaram:$FAILED"
fi

# ---------- 6. NVIDIA / DGX ----------
etapa 6 "Pacotes NVIDIA / DGX"
DGX_MISSING=""
for p in $(echo "$REMOVED" | grep -E '^(nvidia|dgx|cuda|libnv|mlnx|doca)'); do
    dpkg -s "$p" >/dev/null 2>&1 || DGX_MISSING="$DGX_MISSING $p"
done
if [ -n "$DGX_MISSING" ]; then
    log_info "Reinstalando:$DGX_MISSING"
    # shellcheck disable=SC2086
    apt-get install -y $DGX_MISSING || log_warn "Alguns pacotes NVIDIA falharam"
else
    log_ok "Nenhum pacote NVIDIA/DGX faltando"
fi

# ---------- 7. AnyDesk + serviços ----------
etapa 7 "AnyDesk e serviços essenciais"
if grep -rqi anydesk /etc/apt/sources.list.d/ 2>/dev/null; then
    apt-get install -y --reinstall anydesk && log_ok "AnyDesk OK" || log_warn "AnyDesk não reinstalou; baixe de novo em anydesk.com"
elif dpkg -s anydesk >/dev/null 2>&1; then
    apt-get install -y --fix-broken
    log_ok "AnyDesk presente; dependências conferidas"
else
    log_warn "AnyDesk não instalado. Se precisar: baixe o .deb em anydesk.com e rode: sudo apt install ./anydesk_*.deb"
fi
systemctl enable gdm3 2>/dev/null || systemctl enable gdm 2>/dev/null || true
systemctl set-default graphical.target || true
systemctl enable --now NetworkManager || true
systemctl enable --now ssh || true
systemctl enable --now avahi-daemon || true
log_ok "Serviços ativados"

# ---------- 8. Atualizações ----------
etapa 8 "Atualizações pendentes"
apt-get upgrade -y || true
apt-get clean
log_ok "Sistema atualizado"

echo ""
echo -e "${GREEN}✅ Restauração concluída às $(date +%H:%M:%S)!${NC}   Log completo: ${LOG}"
echo ""
echo -e "  Reinicie para voltar ao desktop normal:  ${GREEN}sudo reboot${NC}"
echo -e "  Se estiver na tela preta (Ctrl+Alt+F3), depois do reboot a tela gráfica volta sozinha."
echo ""
