#!/bin/bash

# =============================================================================
#  Script de Instalação Automática: Apache2 + PHP 7.4
#  Uso: curl -sSL <url_do_script> | sudo bash
# =============================================================================

set -e

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
echo "   Instalação Automática: Apache2 + PHP 7.4"
echo "============================================================"
echo ""

# =============================================================================
# PASSO 1 — Atualizar o sistema
# =============================================================================
log_info "Atualizando o sistema..."
apt-get update -y
apt-get upgrade -y
log_success "Sistema atualizado!"

# =============================================================================
# PASSO 2 — Instalar Apache2
# =============================================================================
log_info "Instalando Apache2..."
apt-get install apache2 -y
service apache2 restart
systemctl restart apache2
log_success "Apache2 instalado e iniciado!"

# =============================================================================
# PASSO 3 — Adicionar repositório PHP 7.4 (Ondrej)
# =============================================================================
log_info "Adicionando repositório PHP 7.4..."
apt -y install software-properties-common
add-apt-repository ppa:ondrej/php -y
apt-get update -y
log_success "Repositório adicionado!"

# =============================================================================
# PASSO 4 — Instalar PHP 7.4 base
# =============================================================================
log_info "Instalando PHP 7.4..."
apt -y install php7.4
log_success "PHP 7.4 instalado!"

# =============================================================================
# PASSO 5 — Instalar zip, unzip e utilitários base
# =============================================================================
log_info "Instalando zip/unzip e ferramentas de build..."
apt-get install -y zip unzip php-zip
apt-get install -y build-essential php-dev php-xml
log_success "Utilitários instalados!"

# =============================================================================
# PASSO 6 — Instalar todas as extensões PHP 7.4
# (pacotes com nome errado foram corrigidos abaixo)
#   php7.4-mysqlnd  → php7.4-mysql   (nome correto)
#   php7.4-dom      → já incluso em php7.4-xml
#   php7.4-pear     → php-pear       (sem versão)
#   php7.4-memcache → opcional, pode não existir
# =============================================================================
log_info "Instalando extensões PHP 7.4..."
apt install -y \
    php7.4-cli \
    php7.4-curl \
    php7.4-mysql \
    php7.4-gd \
    php7.4-opcache \
    php7.4-zip \
    php7.4-intl \
    php7.4-common \
    php7.4-bcmath \
    php7.4-imap \
    php7.4-imagick \
    php7.4-xmlrpc \
    php7.4-readline \
    php7.4-memcached \
    php7.4-redis \
    php7.4-mbstring \
    php7.4-apcu \
    php7.4-xml \
    php7.4-dev

# php-pear não tem versão (php7.4-pear não existe)
apt-get install -y php-pear

# php7.4-memcache é opcional — pode não existir em alguns sistemas
log_info "Tentando instalar php7.4-memcache (opcional)..."
apt install -y php7.4-memcache 2>/dev/null || log_warn "php7.4-memcache não disponível — pulando."

log_success "Todas as extensões PHP instaladas!"

# Verificar versão
php -v

# =============================================================================
# PASSO 7 — Instalar pacotes extras (segundo bloco do script original)
# =============================================================================
log_info "Instalando pacotes extras da segunda lista..."
apt -y install \
    php7.4-cli \
    php7.4-mbstring \
    php7.4-dev \
    php7.4-gd \
    php7.4-zip \
    php7.4-xml

apt-get install -y php-pear
log_success "Pacotes extras instalados!"

# =============================================================================
# PASSO 8 — Configurar php.ini (max_execution_time = 0)
# =============================================================================
log_info "Configurando php.ini..."
PHP_INI="/etc/php/7.4/apache2/php.ini"

if [ -f "$PHP_INI" ]; then
    cp "$PHP_INI" "${PHP_INI}.bak"
    sed -i 's/^max_execution_time\s*=.*/max_execution_time = 0/' "$PHP_INI"
    log_success "php.ini configurado! (backup: ${PHP_INI}.bak)"
else
    log_warn "php.ini não encontrado em $PHP_INI — pulando."
fi

# =============================================================================
# PASSO 9 — Configurar permissões /var/www
# =============================================================================
log_info "Configurando permissões de /var/www..."
chmod 777 /var/www
chmod 777 /var/www/html
chown -R www-data:www-data /var/www/
log_success "Permissões configuradas!"

# =============================================================================
# PASSO 10 — Reiniciar Apache2 (3 formas como no original)
# =============================================================================
log_info "Reiniciando Apache2..."
/etc/init.d/apache2 restart
service apache2 restart
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
