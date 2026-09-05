#!/bin/bash
# ============================================================
#  CORRIGIR USUÁRIO DO NOTEBOOK 2
#
#  Situação: no PC 2 você CRIOU um usuário novo (com o nome do
#  PC 1) em vez de RENOMEAR o seu usuário original.
#
#  Este script:
#    1. APAGA o usuário criado por engano (e a home dele)
#    2. RENOMEIA o seu usuário original para o nome do PC 1
#       (mantém todos os seus arquivos, senha, sudo, etc.)
#
#  Como um usuário não pode ser renomeado enquanto está logado,
#  a troca é agendada para o PRÓXIMO BOOT (antes da tela de login).
#
#  Uso:  sudo bash corrigir-usuario-node2.sh
# ============================================================

set -u

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
log_info() { echo -e "${CYAN}[→]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
die()      { echo -e "${RED}[✗] ERRO: $1${NC}"; exit 1; }

[ "$EUID" -ne 0 ] && die "Execute com: sudo bash $0"
CUR_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"

RENAME_SCRIPT=/usr/local/sbin/cluster-rename-user.sh
RENAME_UNIT=/etc/systemd/system/cluster-rename-user.service
LOG=/var/log/cluster-rename-user.log

# Se já existe um agendamento pendente, mostra e sai
if [ -f "$RENAME_SCRIPT" ]; then
    log_warn "Já existe uma troca de usuário agendada para o próximo boot:"
    grep -E '^(OLD|EXTRA|NEW)=' "$RENAME_SCRIPT" | sed 's/^/     /'
    echo ""
    read -r -p "  Cancelar o agendamento? [s/N]: " R < /dev/tty
    if [[ "$R" =~ ^[sSyY] ]]; then
        systemctl disable cluster-rename-user.service >/dev/null 2>&1
        rm -f "$RENAME_SCRIPT" "$RENAME_UNIT"; systemctl daemon-reload
        log_ok "Agendamento cancelado."
    fi
    exit 0
fi

clear
echo -e "${CYAN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║   👤 Corrigir usuário do Notebook 2              ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${NC}"
echo "  Usuários normais neste notebook:"
awk -F: '$3>=1000 && $3<60000 {printf "     %-20s (uid %s, home %s)\n",$1,$3,$6}' /etc/passwd
echo ""

# ---------- Perguntas ----------
read -r -p "  Seu usuário ORIGINAL (o que tem seus arquivos) [${CUR_USER}]: " OLD < /dev/tty
OLD="${OLD:-$CUR_USER}"

read -r -p "  Usuário criado POR ENGANO (será APAGADO com a home dele): " EXTRA < /dev/tty

read -r -p "  Nome FINAL (igual ao usuário do Notebook 1) [${EXTRA}]: " NEW < /dev/tty
NEW="${NEW:-$EXTRA}"

# ---------- Validações ----------
getent passwd "$OLD"   >/dev/null || die "Usuário '$OLD' não existe."
getent passwd "$EXTRA" >/dev/null || die "Usuário '$EXTRA' não existe."
[ "$OLD" = "$EXTRA" ] && die "Usuário original e usuário a apagar não podem ser o mesmo."
[ "$OLD" = root ] || [ "$EXTRA" = root ] && die "Não mexo no root."
[[ "$NEW" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Nome '$NEW' inválido (use só letras minúsculas, números, _ e -)."
OLD_UID=$(id -u "$OLD"); EXTRA_UID=$(id -u "$EXTRA")
[ "$OLD_UID" -ge 1000 ]   || die "'$OLD' é usuário de sistema."
[ "$EXTRA_UID" -ge 1000 ] || die "'$EXTRA' é usuário de sistema."
if [ "$NEW" != "$EXTRA" ] && getent passwd "$NEW" >/dev/null; then
    die "Já existe um usuário '$NEW' e ele não é o que será apagado."
fi
if [ "$NEW" != "$EXTRA" ] && [ -e "/home/$NEW" ]; then
    die "Já existe a pasta /home/$NEW."
fi
id -nG "$OLD" | tr ' ' '\n' | grep -qx sudo || log_warn "'$OLD' NÃO está no grupo sudo. Após a troca você não terá sudo!"

OLD_HOME=$(getent passwd "$OLD" | cut -d: -f6)
EXTRA_HOME=$(getent passwd "$EXTRA" | cut -d: -f6)

echo ""
echo -e "${YELLOW}  RESUMO DO QUE VAI ACONTECER NO PRÓXIMO BOOT:${NC}"
echo -e "    ${RED}APAGAR${NC}   usuário '${EXTRA}' e a pasta ${EXTRA_HOME}"
echo -e "    ${GREEN}RENOMEAR${NC} usuário '${OLD}' → '${NEW}'   (home: ${OLD_HOME} → /home/${NEW})"
echo -e "    Sua senha, arquivos, sudo e configurações continuam os mesmos."
echo ""
read -r -p "  Confirma? Digite SIM para continuar: " CONF < /dev/tty
[ "$CONF" = "SIM" ] || { echo "Cancelado."; exit 0; }

# ---------- Script que roda no boot ----------
cat > "$RENAME_SCRIPT" <<EOF
#!/bin/bash
# Gerado por corrigir-usuario-node2.sh — roda UMA vez no boot e se apaga.
OLD="${OLD}"
EXTRA="${EXTRA}"
NEW="${NEW}"
OLD_HOME="${OLD_HOME}"
EOF
cat >> "$RENAME_SCRIPT" <<'EOF'
LOG=/var/log/cluster-rename-user.log
exec >>"$LOG" 2>&1
echo "===== $(date) — início ====="
set -x

cleanup_self() {
    systemctl disable cluster-rename-user.service >/dev/null 2>&1
    rm -f /etc/systemd/system/cluster-rename-user.service /usr/local/sbin/cluster-rename-user.sh
    systemctl daemon-reload
}

# Garante que ninguém está logado
pkill -KILL -u "$EXTRA" 2>/dev/null; pkill -KILL -u "$OLD" 2>/dev/null; sleep 1
loginctl terminate-user "$EXTRA" 2>/dev/null; loginctl terminate-user "$OLD" 2>/dev/null

# 1) Apaga o usuário criado por engano
if getent passwd "$EXTRA" >/dev/null; then
    EXTRA_HOME=$(getent passwd "$EXTRA" | cut -d: -f6)
    userdel -r "$EXTRA" || userdel "$EXTRA"
    [ -n "$EXTRA_HOME" ] && [ "$EXTRA_HOME" != "/" ] && rm -rf "$EXTRA_HOME"
    getent group "$EXTRA" >/dev/null && groupdel "$EXTRA"
    rm -f "/var/lib/AccountsService/users/$EXTRA" "/var/mail/$EXTRA"
    if getent passwd "$EXTRA" >/dev/null; then
        echo "FALHA: não consegui apagar $EXTRA. Nada foi renomeado."; cleanup_self; exit 1
    fi
fi

# 2) Renomeia o usuário original
if [ "$OLD" != "$NEW" ]; then
    usermod -l "$NEW" "$OLD" || { echo "FALHA no usermod -l. Nada mudou."; cleanup_self; exit 1; }
    getent group "$OLD" >/dev/null && groupmod -n "$NEW" "$OLD"
    usermod -d "/home/$NEW" -m "$NEW" || echo "AVISO: falha ao mover a home; verifique /home"
    usermod -c "$NEW" "$NEW" 2>/dev/null

    # subuid/subgid (docker, snap, lxd)
    sed -i "s/^${OLD}:/${NEW}:/" /etc/subuid /etc/subgid 2>/dev/null

    # Autologin dos gerenciadores de login
    for f in /etc/gdm3/custom.conf /etc/gdm/custom.conf; do
        [ -f "$f" ] && sed -i -E "s/^(\s*AutomaticLogin\s*=\s*)${OLD}\s*$/\1${NEW}/" "$f"
    done
    for f in /etc/lightdm/lightdm.conf /etc/lightdm/lightdm.conf.d/*.conf; do
        [ -f "$f" ] && sed -i -E "s/^(\s*autologin-user\s*=\s*)${OLD}\s*$/\1${NEW}/" "$f"
    done
    [ -f /etc/sddm.conf ] && sed -i -E "s/^(\s*User\s*=\s*)${OLD}\s*$/\1${NEW}/" /etc/sddm.conf

    # AccountsService (foto/idioma do usuário na tela de login)
    [ -f "/var/lib/AccountsService/users/$OLD" ] && mv "/var/lib/AccountsService/users/$OLD" "/var/lib/AccountsService/users/$NEW"
    [ -d "/var/lib/AccountsService/icons" ] && [ -e "/var/lib/AccountsService/icons/$OLD" ] && mv "/var/lib/AccountsService/icons/$OLD" "/var/lib/AccountsService/icons/$NEW"

    # sudoers com o nome antigo
    grep -rl "^${OLD}\b" /etc/sudoers.d/ 2>/dev/null | xargs -r sed -i "s/^${OLD}\b/${NEW}/"

    # Caminhos /home/OLD gravados em configs de texto do usuário
    if [ -d "/home/$NEW" ]; then
        grep -rlI --exclude-dir=.cache "/home/${OLD}\b" "/home/$NEW/.config" "/home/$NEW/.bashrc" "/home/$NEW/.profile" 2>/dev/null \
            | xargs -r sed -i "s#/home/${OLD}\b#/home/${NEW}#g"
    fi
fi

echo "===== $(date) — concluído: $OLD -> $NEW, $EXTRA apagado ====="
id "$NEW"
cleanup_self
exit 0
EOF
chmod 700 "$RENAME_SCRIPT"

cat > "$RENAME_UNIT" <<'EOF'
[Unit]
Description=Cluster IA: renomeia usuário (execução única no boot)
After=local-fs.target
Before=systemd-user-sessions.service display-manager.service gdm.service lightdm.service sddm.service getty.target
ConditionPathExists=/usr/local/sbin/cluster-rename-user.sh

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cluster-rename-user.sh
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cluster-rename-user.service >/dev/null 2>&1 || die "Não consegui ativar o serviço de boot."

echo ""
log_ok "Agendado! No próximo boot o usuário '${OLD}' vira '${NEW}' e '${EXTRA}' é apagado."
echo -e "  Log ficará em: ${LOG}"
echo -e "  Para cancelar antes de reiniciar: ${GREEN}sudo bash $0${NC}"
echo ""
echo -e "${YELLOW}  Depois de reiniciar:${NC} entre com o usuário '${NEW}' e a sua senha de sempre,"
echo -e "  e aí rode:  ${GREEN}sudo bash cluster-ia-setup.sh 2${NC}"
echo ""
read -r -p "  Reiniciar AGORA? [s/N]: " RB < /dev/tty
if [[ "$RB" =~ ^[sSyY] ]]; then
    log_info "Reiniciando em 5 segundos... (feche os programas abertos)"
    sleep 5
    systemctl reboot
fi
