#!/bin/bash

# =============================================================================
#  Script de Instalação Automática: Apache2 + PHP 8.3 (Ubuntu 24.04 LTS)
#  Uso: curl -sSL <url_do_script> | sudo bash
#
#  Obs.: Ubuntu 24.04 (Noble) traz PHP 8.3 como padrão. O PHP 7.4 está EOL
#        e várias extensões (imagick, etc.) não compilam mais no 24.04, por
#        isso esta versão usa PHP 8.3.
# =============================================================================

set -e

# ---- Versão do PHP (altere aqui se quiser 8.2, 8.4, etc.) ----
PHP_VERSION="8.3"

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

# ---- Verificar root ----
if [ "$EUID" -ne 0 ]; then
    log_error "Execute como root: sudo bash $0"
fi

echo ""
echo "============================================================"
echo "   Instalação Automática: Apache2 + PHP ${PHP_VERSION}"
echo "   (Ubuntu 24.04 LTS - Noble)"
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
# PASSO 3 — Adicionar repositório PHP (Ondrej)
#  No Ubuntu 24.04 o PHP 8.3 já existe nos repos oficiais, mas a PPA do
#  Ondrej garante a disponibilidade de TODAS as extensões e atualizações.
# =============================================================================
log_info "Adicionando repositório PHP (ppa:ondrej/php)..."
apt-get -y install software-properties-common ca-certificates lsb-release apt-transport-https
add-apt-repository ppa:ondrej/php -y
apt-get update -y
log_success "Repositório adicionado!"

# =============================================================================
# PASSO 4 — Instalar PHP base + módulo do Apache
# =============================================================================
log_info "Instalando PHP ${PHP_VERSION}..."
apt-get -y install php${PHP_VERSION} libapache2-mod-php${PHP_VERSION}
log_success "PHP ${PHP_VERSION} instalado!"

# =============================================================================
# PASSO 5 — Instalar zip, unzip e utilitários base
# =============================================================================
log_info "Instalando zip/unzip e ferramentas de build..."
apt-get install -y zip unzip php-zip
apt-get install -y build-essential php-dev php-xml
log_success "Utilitários instalados!"

# =============================================================================
# PASSO 6 — Instalar extensões PHP 8.3
#  Observações de mudança em relação ao PHP 7.4:
#   - json/pdo já fazem parte do core no PHP 8.x (não há pacote separado)
#   - php-mysqlnd  → php8.3-mysql
#   - php-pear     → sem número de versão
#   - php8.3-xmlrpc e php8.3-memcache vêm via PECL/Ondrej e podem faltar:
#       por isso são tratados como OPCIONAIS (não derrubam o script)
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
    php${PHP_VERSION}-imagick \
    php${PHP_VERSION}-readline \
    php${PHP_VERSION}-redis \
    php${PHP_VERSION}-mbstring \
    php${PHP_VERSION}-apcu \
    php${PHP_VERSION}-xml \
    php${PHP_VERSION}-soap \
    php${PHP_VERSION}-dev

# php-pear não tem número de versão
apt-get install -y php-pear

# Extensões opcionais — não existem em todos os repositórios.
# Se falharem, apenas avisamos e seguimos em frente.
for OPT in php${PHP_VERSION}-memcached php${PHP_VERSION}-xmlrpc php${PHP_VERSION}-memcache; do
    log_info "Tentando instalar ${OPT} (opcional)..."
    apt-get install -y "${OPT}" 2>/dev/null \
        && log_success "${OPT} instalado." \
        || log_warn "${OPT} não disponível — pulando."
done

log_success "Extensões PHP instaladas!"

# Verificar versão
php -v

# =============================================================================
# PASSO 7 — Garantir que o Apache use o módulo do PHP 8.3
# =============================================================================
log_info "Habilitando módulo PHP ${PHP_VERSION} no Apache..."
a2enmod "php${PHP_VERSION}" 2>/dev/null || log_warn "a2enmod php${PHP_VERSION} já habilitado ou indisponível."
log_success "Módulo do PHP habilitado!"

# =============================================================================
# PASSO 8 — Configurar php.ini (max_execution_time = 0)
#  No PHP 8.3 o caminho passa a ser /etc/php/8.3/...
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
