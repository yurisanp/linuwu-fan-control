#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# install.sh — Instalador do linuwu-fan-control
# Execute com: sudo bash install.sh
# ══════════════════════════════════════════════════════════════════════════════
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
die()     { echo -e "${RED}[✗]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && die "Execute como root: sudo bash install.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 1. Verifica dependências ───────────────────────────────────────────────────
info "Verificando dependências..."
command -v python3 >/dev/null || die "python3 não encontrado. Instale com: sudo pacman -S python"

# ── 2. Verifica driver ────────────────────────────────────────────────────────
FAN_PATH="/sys/module/linuwu_sense/drivers/platform:acer-wmi/acer-wmi/predator_sense/fan_speed"
if [[ ! -e "$FAN_PATH" ]]; then
    warn "Driver Linuwu-Sense não detectado em $FAN_PATH"
    warn "Certifique-se que o módulo está carregado: lsmod | grep linuwu_sense"
    warn "Continuando instalação mesmo assim..."
fi

# ── 3. Instala o daemon ───────────────────────────────────────────────────────
info "Instalando daemon em /usr/local/bin/linuwu-fan-control..."
install -m 755 "$SCRIPT_DIR/linuwu-fan-control" /usr/local/bin/linuwu-fan-control

# ── 4. Instala configuração (não sobrescreve se já existir) ───────────────────
if [[ -f /etc/linuwu-fan-control.conf ]]; then
    warn "Configuração já existe em /etc/linuwu-fan-control.conf — mantendo a existente."
    warn "Nova config de exemplo salva em /etc/linuwu-fan-control.conf.new"
    install -m 644 "$SCRIPT_DIR/linuwu-fan-control.conf" /etc/linuwu-fan-control.conf.new
else
    info "Instalando configuração em /etc/linuwu-fan-control.conf..."
    install -m 644 "$SCRIPT_DIR/linuwu-fan-control.conf" /etc/linuwu-fan-control.conf
fi

# ── 5. Instala serviço systemd ────────────────────────────────────────────────
info "Instalando serviço systemd..."
install -m 644 "$SCRIPT_DIR/linuwu-fan-control.service" /etc/systemd/system/linuwu-fan-control.service
systemctl daemon-reload

# ── 6. Habilita e inicia ──────────────────────────────────────────────────────
info "Habilitando serviço para iniciar no boot..."
systemctl enable linuwu-fan-control

info "Iniciando serviço..."
systemctl start linuwu-fan-control

# ── Resultado ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo -e "${GREEN}  Instalação concluída com sucesso!${NC}"
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo ""
echo "  Comandos úteis:"
echo ""
echo "  Verificar status      :  sudo systemctl status linuwu-fan-control"
echo "  Ver logs em tempo real:  sudo journalctl -fu linuwu-fan-control"
echo "  Parar (ventoinhas=auto):  sudo systemctl stop linuwu-fan-control"
echo "  Desligar do boot      :  sudo systemctl disable linuwu-fan-control"
echo "  Reiniciar após editar config:  sudo systemctl restart linuwu-fan-control"
echo ""
echo "  Configuração          :  /etc/linuwu-fan-control.conf"
echo "  Log                   :  /var/log/linuwu-fan-control.log"
echo ""
