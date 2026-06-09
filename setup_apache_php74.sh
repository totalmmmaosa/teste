#!/bin/bash

# =============================================================================
#  Script de Instalação Automática: Apache2 + PHP 7.4
#  Autor: Script gerado automaticamente
#  Uso: sudo bash setup_apache_php74.sh
# =============================================================================

set -e  # Para o script se houver algum erro

# ---- Cores para output ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # Sem cor

# ---- Funções de log ----
log_info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[AVISO]${NC} $1"; }
log_error()   { echo -e "${RED}[ERRO]${NC}  $1"; exit 1; }

# ---- Verificar se está rodando como root ----
if [ "$EUID" -ne 0 ]; then
    log_error "Este script precisa ser executado como root. Use: sudo bash $0"
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
apt-get update -y && apt-get upgrade -y
log_success "Sistema atualizado!"

# =============================================================================
# PASSO 2 — Instalar Apache2
# =============================================================================
log_info "Instalando Apache2..."
apt-get install apache2 -y
log_success "Apache2 instalado!"

# =============================================================================
# PASSO 3 — Adicionar repositório do PHP 7.4 (Ondrej)
# =============================================================================
log_info "Instalando dependências e adicionando repositório PHP 7.4..."
apt -y install software-properties-common
add-apt-repository ppa:ondrej/php -y
apt-get update -y
log_success "Repositório PHP 7.4 adicionado!"

# =============================================================================
# PASSO 4 — Instalar PHP 7.4 e extensões
# =============================================================================
log_info "Instalando PHP 7.4 e todas as extensões necessárias..."
apt -y install php7.4 php7.4-cli php7.4-curl php7.4-mysqlnd php7.4-gd \
    php7.4-opcache php7.4-zip php7.4-intl php7.4-common php7.4-bcmath \
    php7.4-imap php7.4-imagick php7.4-xmlrpc php7.4-readline \
    php7.4-memcached php7.4-redis php7.4-mbstring php7.4-apcu \
    php7.4-xml php7.4-dom php7.4-dev php7.4-pear

apt-get install -y zip unzip php-zip build-essential php-dev php-xml \
    php-pear
log_success "PHP 7.4 e extensões instalados!"

# Exibir versão instalada
php -v

# =============================================================================
# PASSO 5 — Configurar php.ini (max_execution_time = 0)
# =============================================================================
log_info "Configurando php.ini (max_execution_time = 0)..."
PHP_INI="/etc/php/7.4/apache2/php.ini"

if [ -f "$PHP_INI" ]; then
    # Faz backup antes de modificar
    cp "$PHP_INI" "${PHP_INI}.bak"
    # Substitui o valor de max_execution_time
    sed -i 's/^max_execution_time\s*=.*/max_execution_time = 0/' "$PHP_INI"
    log_success "php.ini configurado! (backup salvo em ${PHP_INI}.bak)"
else
    log_warn "Arquivo php.ini não encontrado em $PHP_INI — pulando configuração."
fi

# =============================================================================
# PASSO 6 — Configurar permissões do /var/www
# =============================================================================
log_info "Configurando permissões de /var/www e /var/www/html..."
chmod 777 /var/www
chmod 777 /var/www/html
chown -R www-data:www-data /var/www/
log_success "Permissões configuradas!"

# =============================================================================
# PASSO 7 — Reiniciar Apache2
# =============================================================================
log_info "Reiniciando Apache2..."
systemctl restart apache2
/etc/init.d/apache2 restart
log_success "Apache2 reiniciado com sucesso!"

# =============================================================================
# PASSO 8 — Verificar status final
# =============================================================================
echo ""
echo "============================================================"
log_success "Instalação concluída com sucesso!"
echo "============================================================"
echo ""
log_info "Status do Apache2:"
systemctl status apache2 --no-pager -l

echo ""
log_info "Versão do PHP instalada:"
php -v

echo ""
log_info "Módulos PHP carregados:"
php -m

echo ""
echo "============================================================"
echo "  Acesse seu servidor: http://$(hostname -I | awk '{print $1}')"
echo "============================================================"
echo ""
