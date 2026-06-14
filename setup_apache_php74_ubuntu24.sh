#!/bin/bash

# =============================================================================
#  Script de Instalação Automática: Apache2 + PHP 7.4 (Ubuntu 24.04 LTS)
#  Uso: curl -sSL <url_do_script> | sudo bash
#
#  ATENÇÃO: PHP 7.4 está EOL (sem atualizações de segurança). Use apenas se
#  uma aplicação legada exigir 7.4. No Ubuntu 24.04 (Noble) o 7.4 NÃO está
#  nos repos oficiais — instalamos via PPA do Ondrej. Algumas extensões
#  (ex.: imagick, memcached) não compilam para 7.4 no 24.04 e por isso são
#  tratadas como OPCIONAIS (não derrubam o script).
#
#  Recomendado: prefira o script setup_apache_php83_ubuntu24.sh (PHP 8.3).
# =============================================================================

set -e

# ---- Versão do PHP ----
PHP_VERSION="7.4"

# ---- Cores ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[AVISO]${NC} $1"; }
log_error()   { echo -e "${RED}[ERRO]${NC}  $1"; exit 1; }

# ---- Instala um pacote OPCIONAL (não derruba o script se faltar) ----
try_install() {
    log_info "Tentando instalar $1 (opcional)..."
    apt-get install -y "$1" 2>/dev/null \
        && log_success "$1 instalado." \
        || log_warn "$1 não disponível — pulando."
}

# ---- Verificar root ----
if [ "$EUID" -ne 0 ]; then
    log_error "Execute como root: sudo bash $0"
fi

echo ""
echo "============================================================"
echo "   Instalação Automática: Apache2 + PHP ${PHP_VERSION}"
echo "   (Ubuntu 24.04 LTS - Noble) [LEGADO]"
echo "============================================================"
echo ""

# =============================================================================
# PASSO 1 — Atualizar o sistema
# =============================================================================
log_info "Atualizando o sistema..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
log_success "Sistema atualizado!"

# =============================================================================
# PASSO 2 — Instalar Apache2
# =============================================================================
log_info "Instalando Apache2..."
apt-get install apache2 -y
systemctl enable apache2
systemctl restart apache2
log_success "Apache2 instalado e iniciado!"

# =============================================================================
# PASSO 3 — Adicionar repositório PHP 7.4 (Ondrej)
#  Obrigatório no 24.04, pois o 7.4 não vem nos repos oficiais.
#
#  IMPORTANTE: a PPA do Ondrej só publica pacotes para releases LTS/suportadas.
#  Se o sistema for uma versão de desenvolvimento (ex.: 'resolute'), o
#  add-apt-repository tentaria usar esse codinome e daria 404. Por isso
#  detectamos o codinome e caímos para 'noble' (24.04) quando necessário.
#  Você pode forçar manualmente com:  PPA_CODENAME=noble sudo -E bash script.sh
# =============================================================================
log_info "Adicionando repositório PHP ${PHP_VERSION} (ppa:ondrej/php)..."
apt-get -y install software-properties-common ca-certificates lsb-release apt-transport-https gnupg curl

# Codinomes que a PPA do Ondrej realmente suporta
SUPPORTED_CODENAMES="bionic focal jammy noble"
PPA_CODENAME="${PPA_CODENAME:-$(lsb_release -cs)}"

if ! echo " ${SUPPORTED_CODENAMES} " | grep -q " ${PPA_CODENAME} "; then
    log_warn "Release '${PPA_CODENAME}' não é suportada pela PPA do Ondrej."
    log_warn "Usando os pacotes do 'noble' (Ubuntu 24.04 LTS)."
    PPA_CODENAME="noble"
fi
log_info "Usando codinome da PPA: ${PPA_CODENAME}"

# Adiciona a PPA manualmente (não usamos add-apt-repository para poder
# fixar o codinome e não depender da auto-detecção do sistema).
install -d -m 0755 /etc/apt/keyrings
curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x14AA40EC0831756756D7F66C4F4EA0AAE5267A6C" \
    | gpg --dearmor -o /etc/apt/keyrings/ondrej-php.gpg

# Remove qualquer entrada antiga/quebrada da PPA antes de recriar
rm -f /etc/apt/sources.list.d/ondrej-ubuntu-php-*.sources \
      /etc/apt/sources.list.d/ondrej-ubuntu-php-*.list \
      /etc/apt/sources.list.d/ondrej-php.list

echo "deb [signed-by=/etc/apt/keyrings/ondrej-php.gpg] https://ppa.launchpadcontent.net/ondrej/php/ubuntu ${PPA_CODENAME} main" \
    > /etc/apt/sources.list.d/ondrej-php.list

apt-get update -y
log_success "Repositório adicionado!"

# =============================================================================
# PASSO 4 — Instalar PHP 7.4 base + módulo do Apache
# =============================================================================
log_info "Instalando PHP ${PHP_VERSION}..."
apt-get -y install php${PHP_VERSION} libapache2-mod-php${PHP_VERSION}
log_success "PHP ${PHP_VERSION} instalado!"

# =============================================================================
# PASSO 5 — Instalar zip, unzip e utilitários base
# =============================================================================
log_info "Instalando zip/unzip e ferramentas de build..."
apt-get install -y zip unzip
apt-get install -y build-essential
log_success "Utilitários instalados!"

# =============================================================================
# PASSO 6 — Instalar extensões PHP 7.4 (essenciais)
# =============================================================================
log_info "Instalando extensões PHP ${PHP_VERSION}..."
apt-get install -y \
    php${PHP_VERSION}-cli \
    php${PHP_VERSION}-curl \
    php${PHP_VERSION}-mysql \
    php${PHP_VERSION}-gd \
    php${PHP_VERSION}-opcache \
    php${PHP_VERSION}-zip \
    php${PHP_VERSION}-intl \
    php${PHP_VERSION}-common \
    php${PHP_VERSION}-bcmath \
    php${PHP_VERSION}-imap \
    php${PHP_VERSION}-readline \
    php${PHP_VERSION}-redis \
    php${PHP_VERSION}-mbstring \
    php${PHP_VERSION}-xml \
    php${PHP_VERSION}-soap \
    php${PHP_VERSION}-dev

# php-pear sem número de versão
apt-get install -y php-pear

# Extensões opcionais (podem não compilar para 7.4 no 24.04)
for OPT in \
    php${PHP_VERSION}-imagick \
    php${PHP_VERSION}-apcu \
    php${PHP_VERSION}-memcached \
    php${PHP_VERSION}-xmlrpc \
    php${PHP_VERSION}-memcache; do
    try_install "${OPT}"
done

log_success "Extensões PHP instaladas!"

# Verificar versão
php -v

# =============================================================================
# PASSO 7 — Definir o PHP 7.4 como padrão e habilitar no Apache
#  Importante: se houver outra versão do PHP instalada, forçamos a 7.4.
# =============================================================================
log_info "Definindo PHP ${PHP_VERSION} como padrão..."
if command -v update-alternatives >/dev/null 2>&1; then
    update-alternatives --set php /usr/bin/php${PHP_VERSION} 2>/dev/null || true
fi

log_info "Habilitando módulo PHP ${PHP_VERSION} no Apache..."
# Desabilita qualquer outro módulo php que esteja ativo
for m in /etc/apache2/mods-enabled/php*.load; do
    [ -e "$m" ] || continue
    base="$(basename "$m" .load)"
    if [ "$base" != "php${PHP_VERSION}" ]; then
        a2dismod "$base" 2>/dev/null || true
    fi
done
a2enmod "php${PHP_VERSION}" 2>/dev/null || log_warn "a2enmod php${PHP_VERSION} já habilitado ou indisponível."
log_success "Módulo do PHP habilitado!"

# =============================================================================
# PASSO 8 — Configurar php.ini (max_execution_time = 0)
# =============================================================================
log_info "Configurando php.ini..."
for SAPI in apache2 cli; do
    PHP_INI="/etc/php/${PHP_VERSION}/${SAPI}/php.ini"
    if [ -f "$PHP_INI" ]; then
        cp "$PHP_INI" "${PHP_INI}.bak"
        sed -i 's/^max_execution_time\s*=.*/max_execution_time = 0/' "$PHP_INI"
        log_success "php.ini (${SAPI}) configurado! (backup: ${PHP_INI}.bak)"
    else
        log_warn "php.ini não encontrado em $PHP_INI — pulando."
    fi
done

# =============================================================================
# PASSO 9 — Configurar permissões /var/www
# =============================================================================
log_info "Configurando permissões de /var/www..."
chmod 777 /var/www
chmod 777 /var/www/html
chown -R www-data:www-data /var/www/
log_success "Permissões configuradas!"

# =============================================================================
# PASSO 10 — Reiniciar Apache2
# =============================================================================
log_info "Reiniciando Apache2..."
systemctl restart apache2
log_success "Apache2 reiniciado!"

# =============================================================================
# RESUMO FINAL
# =============================================================================
echo ""
echo "============================================================"
log_success "✅ Instalação concluída com sucesso!"
echo "============================================================"
echo ""
log_info "Status do Apache2:"
systemctl status apache2 --no-pager -l

echo ""
log_info "Versão do PHP:"
php -v

echo ""
echo "============================================================"
echo "  Acesse: http://$(hostname -I | awk '{print $1}')"
echo "============================================================"
echo ""
