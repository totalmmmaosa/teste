#!/bin/bash
# ============================================================
#  RESTAURAR SISTEMA — reinstala tudo que foi removido por engano
#  (desktop, rede, AnyDesk, bibliotecas) e conserta pacotes quebrados.
#
#  Uso:  sudo bash restaurar-sistema.sh
#
#  Não apaga nada. Só instala / reinstala. Pode rodar mais de uma vez.
#  Se não tiver terminal gráfico: Ctrl+Alt+F3, faça login e rode aqui.
# ============================================================

set -u
export DEBIAN_FRONTEND=noninteractive

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
log_ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
log_info() { echo -e "${CYAN}[→]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
die()      { echo -e "${RED}[✗] ERRO: $1${NC}"; exit 1; }

[ "$EUID" -ne 0 ] && die "Execute com: sudo bash $0"

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  🛠  Restaurar sistema padrão (Ubuntu / DGX OS)   ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""

# ---------- 0. Rede funcionando? ----------
log_info "Testando internet..."
if ! ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1; then
    log_warn "Sem internet. Tentando levantar a rede..."
    systemctl start NetworkManager 2>/dev/null || true
    systemctl start systemd-networkd 2>/dev/null || true
    for i in /sys/class/net/en*; do
        [ -e "$i" ] || continue
        i=$(basename "$i"); ip link set "$i" up 2>/dev/null
        dhclient "$i" >/dev/null 2>&1 || dhcpcd "$i" >/dev/null 2>&1 || true
    done
    sleep 5
    ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1 || die "Ainda sem internet. Conecte o cabo de rede no roteador (porta enP7s7) e rode de novo."
fi
log_ok "Internet OK"

# ---------- 1. Conserta o apt/dpkg ----------
log_info "Consertando pacotes pendentes/quebrados..."
dpkg --configure -a >/dev/null 2>&1 || true
apt-get update -qq || die "apt update falhou. Verifique a internet."
apt-get install -y -qq --fix-broken >/dev/null 2>&1 || true
log_ok "apt OK"

# ---------- 2. Descobre o que foi removido (log do apt) ----------
log_info "Lendo o histórico do apt para achar o que foi removido..."
REMOVED=$( { cat /var/log/apt/history.log 2>/dev/null; zcat /var/log/apt/history.log.*.gz 2>/dev/null; } \
    | grep -E '^(Remove|Purge):' \
    | sed -E 's/^(Remove|Purge): //; s/\([^)]*\)//g; s/,/ /g; s/:[a-z0-9]+//g' \
    | tr ' ' '\n' | grep -v '^$' | sort -u)
COUNT=$(echo "$REMOVED" | grep -c . || true)
log_ok "${COUNT} pacotes já foram removidos alguma vez nesta máquina"

# ---------- 3. Lista base do sistema padrão ----------
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

# ---------- 4. Monta a lista final: só pacotes que existem no repositório ----------
log_info "Verificando quais pacotes existem no repositório..."
TO_INSTALL=""
for p in $REMOVED $BASE_PKGS; do
    if apt-cache policy "$p" 2>/dev/null | grep -q 'Candidate: [^(]'; then
        TO_INSTALL="$TO_INSTALL $p"
    fi
done
TO_INSTALL=$(echo "$TO_INSTALL" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')
log_ok "$(echo "$TO_INSTALL" | wc -w) pacotes para instalar/reinstalar"

# ---------- 5. Instala ----------
log_info "Instalando (pode demorar vários minutos)..."
# shellcheck disable=SC2086
if ! apt-get install -y -qq $TO_INSTALL; then
    log_warn "Instalação em bloco falhou; instalando um por um (os que falharem são pulados)..."
    FAILED=""
    for p in $TO_INSTALL; do
        apt-get install -y -qq "$p" >/dev/null 2>&1 || FAILED="$FAILED $p"
    done
    [ -n "$FAILED" ] && log_warn "Não instalaram: $FAILED"
fi

# ---------- 6. Pacotes NVIDIA / DGX (se o repositório existir) ----------
log_info "Verificando pacotes NVIDIA/DGX..."
DGX_PKGS=$(apt-cache search --names-only '^(nvidia-dgx|dgx-|nvidia-driver-|cuda-toolkit)' 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
DGX_MISSING=""
for p in $DGX_PKGS; do
    # reinstala só o que estava instalado antes (aparece no log de remoção)
    if echo "$REMOVED" | grep -qx "$p" && ! dpkg -s "$p" >/dev/null 2>&1; then
        DGX_MISSING="$DGX_MISSING $p"
    fi
done
if [ -n "$DGX_MISSING" ]; then
    # shellcheck disable=SC2086
    apt-get install -y -qq $DGX_MISSING || log_warn "Alguns pacotes NVIDIA falharam: $DGX_MISSING"
    log_ok "Pacotes NVIDIA/DGX reinstalados:$DGX_MISSING"
else
    log_ok "Pacotes NVIDIA/DGX intactos"
fi

# ---------- 7. AnyDesk ----------
if ls /etc/apt/sources.list.d/ 2>/dev/null | grep -qi anydesk; then
    log_info "Reinstalando AnyDesk..."
    apt-get install -y -qq --reinstall anydesk >/dev/null 2>&1 && log_ok "AnyDesk OK" || log_warn "AnyDesk não reinstalou; baixe de novo em anydesk.com"
elif dpkg -s anydesk >/dev/null 2>&1; then
    apt-get install -y -qq --fix-broken >/dev/null 2>&1
    log_ok "AnyDesk presente; dependências conferidas"
else
    log_warn "AnyDesk não está instalado. Se precisar: baixe o .deb em anydesk.com e rode: sudo apt install ./anydesk_*.deb"
fi

# ---------- 8. Serviços essenciais ----------
log_info "Ativando serviços essenciais..."
systemctl enable gdm3 >/dev/null 2>&1 || systemctl enable gdm >/dev/null 2>&1 || true
systemctl set-default graphical.target >/dev/null 2>&1 || true
systemctl enable --now NetworkManager >/dev/null 2>&1 || true
systemctl enable --now ssh >/dev/null 2>&1 || true
systemctl enable --now avahi-daemon >/dev/null 2>&1 || true
log_ok "Serviços ativados"

# ---------- 9. Atualiza tudo e limpa ----------
log_info "Aplicando atualizações pendentes..."
apt-get upgrade -y -qq >/dev/null 2>&1 || true
apt-get clean
log_ok "Sistema atualizado"

echo ""
echo -e "${GREEN}✅ Restauração concluída!${NC}"
echo ""
echo -e "  Reinicie para voltar ao desktop normal:  ${GREEN}sudo reboot${NC}"
echo -e "  Se estiver na tela preta (Ctrl+Alt+F3), depois do reboot a tela gráfica volta sozinha."
echo ""
