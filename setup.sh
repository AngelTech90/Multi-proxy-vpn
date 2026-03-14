#!/bin/bash

# ==============================================================================
# VPN Multi-Proxy Setup Script
# ==============================================================================
# Este script configura el sistema VPN desde cero o actualiza la instalación
# Detectando la distro, instalando dependencias, y configurando credenciales
# ==============================================================================

set -e

# Configuración
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VPN_DIR="/usr/local/bin/ovpn"
LOG_DIR="/var/log/protonvpn"
RUN_DIR="/var/run"
CONFIG_DIR="${PROJECT_DIR}/config"
OVPN_DIR="${PROJECT_DIR}/ovpn"
# Credentials están en el mismo directorio que los archivos OVPN
DEPLOYMENT_DIR="${PROJECT_DIR}/deployment"

# Colores
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ==============================================================================
# FUNCIONES DE UTILIDAD
# ==============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ==============================================================================
# DETECCIÓN DE DISTRO
# ==============================================================================

detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO="${ID}"
        DISTRO_VERSION="${VERSION_ID}"
    elif [ -f /etc/lsb-release ]; then
        . /etc/lsb-release
        DISTRO="${DISTRIB_ID}"
        DISTRO_VERSION="${DISTRIB_RELEASE}"
    else
        log_error "No se pudo detectar la distribución"
        exit 1
    fi
    
    log_info "Distribución detectada: ${DISTRO} ${DISTRO_VERSION}"
    
    # Determinar gestor de paquetes
    if command -v apt-get &> /dev/null; then
        PKG_MANAGER="apt"
    elif command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
    elif command -v pacman &> /dev/null; then
        PKG_MANAGER="pacman"
    elif command -v zypper &> /dev/null; then
        PKG_MANAGER="zypper"
    elif command -v apk &> /dev/null; then
        PKG_MANAGER="apk"
    else
        log_error "Gestor de paquetes no soportado"
        exit 1
    fi
    
    log_info "Gestor de paquetes: ${PKG_MANAGER}"
}

# ==============================================================================
# INSTALACIÓN DE DEPENDENCIAS
# ==============================================================================

install_dependencies() {
    log_info "Instalando dependencias..."
    
    case "${PKG_MANAGER}" in
        apt)
            sudo apt-get update
            sudo apt-get install -y openvpn curl iproute2 iptables net-tools
            ;;
        dnf)
            sudo dnf install -y openvpn curl iproute iptables net-tools
            ;;
        pacman)
            sudo pacman -S --noconfirm openvpn curl iproute2 iptables
            ;;
        zypper)
            sudo zypper install -y openvpn curl iproute2 iptables
            ;;
        apk)
            sudo apk add openvpn curl iproute2 iptables
            ;;
    esac
    
    # Instalar microsocks si no existe
    if ! command -v microsocks &> /dev/null; then
        log_info "Compilando microsocks..."
        
        # Instalar dependencias de compilación
        case "${PKG_MANAGER}" in
            apt)
                sudo apt-get install -y build-essential
                ;;
            dnf)
                sudo dnf install -y gcc gcc-c++ make
                ;;
            pacman)
                sudo pacman -S --noconfirm base-devel
                ;;
            zypper)
                sudo zypper install -y gcc gcc-c++ make
                ;;
            apk)
                sudo apk add build-base
                ;;
        esac
        
        # Descargar y compilar microsocks
        TEMP_DIR=$(mktemp -d)
        cd "${TEMP_DIR}"
        curl -sL https://github.com/rofl0r/microsocks/archive/refs/heads/master.zip -o microsocks.zip
        unzip -q microsocks.zip
        cd microsocks-*
        make
        sudo make install
        cd "${PROJECT_DIR}"
        rm -rf "${TEMP_DIR}"
        
        log_success "microsocks instalado"
    else
        log_success "microsocks ya instalado"
    fi
    
    log_success "Dependencias instaladas"
}

# ==============================================================================
# LIMPIEZA DEL SISTEMA
# ==============================================================================

cleanup_system() {
    log_info "Limpiando instalación anterior..."
    
    # Detener servicios
    sudo pkill -f openvpn 2>/dev/null || true
    sudo pkill -f microsocks 2>/dev/null || true
    
    # Limpiar usuarios vpnuser
    for i in $(seq 100 105); do
        sudo userdel "vpnuser${i}" 2>/dev/null || true
    done
    
    # Limpiar reglas de iptables
    sudo iptables -t mangle -F OUTPUT 2>/dev/null || true
    
    # Limpiar reglas de ip
    for i in $(seq 100 105); do
        sudo ip rule del uidrange ${i}300-${i}300 2>/dev/null || true
        sudo ip rule del fwmark ${i} 2>/dev/null || true
        sudo ip route flush table ${i} 2>/dev/null || true
    done
    
    # Limpiar archivos del sistema
    sudo rm -rf "${VPN_DIR}"/* 2>/dev/null || true
    sudo rm -rf "${LOG_DIR}"/* 2>/dev/null || true
    sudo rm -f "${RUN_DIR}"/openvpn-*.pid 2>/dev/null || true
    sudo rm -f "${RUN_DIR}"/microsocks-*.pid 2>/dev/null || true
    sudo rm -f /etc/protonvpn/vpn-config.conf 2>/dev/null || true
    
    log_success "Limpieza completada"
}

# ==============================================================================
# CREACIÓN DE ESTRUCTURA DE DIRECTORIOS
# ==============================================================================

setup_directories() {
    log_info "Creando estructura de directorios..."
    
    sudo mkdir -p "${VPN_DIR}"
    sudo mkdir -p "${LOG_DIR}"
    sudo mkdir -p /etc/iproute2
    
    # Asegurar rt_tables
    if ! grep -q "^100 usa" /etc/iproute2/rt_tables 2>/dev/null; then
        echo "100 usa" | sudo tee -a /etc/iproute2/rt_tables > /dev/null
    fi
    if ! grep -q "^101 netherlands" /etc/iproute2/rt_tables 2>/dev/null; then
        echo "101 netherlands" | sudo tee -a /etc/iproute2/rt_tables > /dev/null
    fi
    if ! grep -q "^102 norway" /etc/iproute2/rt_tables 2>/dev/null; then
        echo "102 norway" | sudo tee -a /etc/iproute2/rt_tables > /dev/null
    fi
    if ! grep -q "^103 mexico" /etc/iproute2/rt_tables 2>/dev/null; then
        echo "103 mexico" | sudo tee -a /etc/iproute2/rt_tables > /dev/null
    fi
    if ! grep -q "^104 japan" /etc/iproute2/rt_tables 2>/dev/null; then
        echo "104 japan" | sudo tee -a /etc/iproute2/rt_tables > /dev/null
    fi
    if ! grep -q "^105 canada" /etc/iproute2/rt_tables 2>/dev/null; then
        echo "105 canada" | sudo tee -a /etc/iproute2/rt_tables > /dev/null
    fi
    
    log_success "Directorios creados"
}

# ==============================================================================
# INTEGRACIÓN DE CREDENCIALES EN ARCHIVOS OVPN
# ==============================================================================

integrate_credentials() {
    log_info "Integrando credenciales en archivos OVPN..."
    
    # Buscar credenciales en el directorio ovpn
    CRED_COUNT=$(ls -1 "${OVPN_DIR}"/credentials*.txt 2>/dev/null | wc -l)
    OVPN_COUNT=$(ls -1 "${OVPN_DIR}"/*.ovpn 2>/dev/null | wc -l)
    
    if [ ${OVPN_COUNT} -eq 0 ]; then
        log_error "No se encontraron archivos .ovpn en ${OVPN_DIR}"
        exit 1
    fi
    
    if [ ${CRED_COUNT} -eq 0 ]; then
        log_error "No se encontraron archivos de credenciales en ${OVPN_DIR}"
        exit 1
    fi
    
    log_info "Archivos OVPN: ${OVPN_COUNT}, Archivos de credenciales: ${CRED_COUNT}"
    
    # Copiar archivos a /etc/protonvpn
    sudo mkdir -p "${VPN_DIR}"
    sudo cp "${OVPN_DIR}"/*.ovpn "${VPN_DIR}/"
    sudo cp "${OVPN_DIR}"/credentials*.txt "${VPN_DIR}/"
    
    # Hacer credenciales legibles solo por root
    sudo chmod 600 "${VPN_DIR}"/credentials*.txt
    
    # Asignar credenciales por PARES (orden alfabético)
    # 2 archivos por credencial
    OVPN_FILES=($(ls -1 "${VPN_DIR}"/*.ovpn))
    TOTAL=${#OVPN_FILES[@]}
    
    for i in "${!OVPN_FILES[@]}"; do
        OVPN_FILE="${OVPN_FILES[$i]}"
        
        # Calcular índice de credenciales (cada 2 archivos)
        CRED_INDEX=$(( (i / 2) + 1 ))
        
        if [ ${CRED_INDEX} -eq 1 ]; then
            CRED_FILE="credentials.txt"
        elif [ ${CRED_INDEX} -eq 2 ]; then
            CRED_FILE="credentials-2.txt"
        elif [ ${CRED_INDEX} -eq 3 ]; then
            CRED_FILE="credentials-3.txt"
        else
            CRED_FILE="credentials-${CRED_INDEX}.txt"
        fi
        
        # Verificar que existe
        if [ ! -f "${VPN_DIR}/${CRED_FILE}" ]; then
            CRED_FILE="credentials.txt"
        fi
        
        # Limpiar y poner ruta ABSOLUTA
        sudo sed -i '/^auth-user-pass/d' "${OVPN_FILE}"
        echo "auth-user-pass ${VPN_DIR}/${CRED_FILE}" | sudo tee -a "${OVPN_FILE}" > /dev/null
        
        log_info "  $(basename ${OVPN_FILE}) -> ${CRED_FILE}"
    done
    
    log_success "Credenciales integradas en ${VPN_DIR}"
}

# ==============================================================================
# CREACIÓN DE USUARIOS
# ==============================================================================

create_users() {
    log_info "Creando usuarios vpnuser..."
    
    for i in $(seq 100 111); do
        PROXY_UID=$((3000 + i))
        
        if ! id "vpnuser${i}" &>/dev/null; then
            sudo useradd -r -s /bin/false -u ${PROXY_UID} "vpnuser${i}" 2>/dev/null || true
            log_info "  Creado usuario vpnuser${i} (UID: ${PROXY_UID})"
        else
            log_info "  Usuario vpnuser${i} ya existe"
        fi
    done
    
    log_success "Usuarios creados"
}

# ==============================================================================
# DESPLIEGUE DE SCRIPTS
# ==============================================================================

deploy_scripts() {
    log_info "Desplegando scripts..."
    
    # Copiar scripts principales
    sudo cp "${PROJECT_DIR}/multi-vpn-proxy.sh" /usr/local/bin/
    sudo chmod +x /usr/local/bin/multi-vpn-proxy.sh
    
    # Copiar scripts de deployment
    sudo cp "${DEPLOYMENT_DIR}"/*.sh /usr/local/bin/
    sudo chmod +x /usr/local/bin/vpn-*.sh
    
    # Copiar script de debugging
    sudo cp "${PROJECT_DIR}/debugging/vpn-debug.sh" /usr/local/bin/
    sudo chmod +x /usr/local/bin/vpn-debug.sh
    
    log_success "Scripts desplegados"
}

# ==============================================================================
# MENÚ PRINCIPAL
# ==============================================================================

show_help() {
    echo "VPN Multi-Proxy Setup"
    echo ""
    echo "Uso: $0 {install|update|full|help}"
    echo ""
    echo "Comandos:"
    echo "  install  - Instalar dependencias y configurar (sin limpiar anterior)"
    echo "  update   - Actualizar archivos OVPN y credenciales"
    echo "  full     - Instalación completa (limpia anterior + configura)"
    echo "  help     - Mostrar esta ayuda"
}

# ==============================================================================
# MAIN
# ==============================================================================

case "${1}" in
    install)
        detect_distro
        install_dependencies
        setup_directories
        integrate_credentials
        create_users
        deploy_scripts
        log_success "Instalación completada!"
        ;;
        
    update)
        detect_distro
        integrate_credentials
        deploy_scripts
        log_success "Actualización completada!"
        ;;
        
    full)
        detect_distro
        cleanup_system
        install_dependencies
        setup_directories
        integrate_credentials
        create_users
        deploy_scripts
        log_success "Instalación completa finalizada!"
        ;;
        
    help|--help|-h|"")
        show_help
        ;;
        
    *)
        log_error "Comando desconocido: $1"
        show_help
        exit 1
        ;;
esac
