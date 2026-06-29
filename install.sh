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

# ── Comandos auxiliares de verificação ─────────────────────────────────────────

# Valida um script Python ANTES de instalar:
#   1. shebang deve ser os 2 primeiros bytes do arquivo (#!) — senão execve()
#      falha com ENOEXEC e o systemd reporta status=203/EXEC.
#   2. sintaxe Python válida (py_compile).
validate_script() {
    local file="$1"
    [[ -f "$file" ]] || die "Arquivo não encontrado: $file"

    local first2
    first2="$(head -c 2 "$file")"
    if [[ "$first2" != "#!" ]]; then
        die "Shebang inválido em $(basename "$file"): os 2 primeiros bytes não são '#!' (encontrado: $(head -c 20 "$file" | od -An -c | head -1)). Isso causaria 'status=203/EXEC' no systemd."
    fi

    if ! python3 -m py_compile "$file" 2>/dev/null; then
        die "Erro de sintaxe Python em $(basename "$file"). Corrija antes de instalar."
    fi
    info "Verificado: $(basename "$file") (shebang + sintaxe OK)"
}

# Confirma que um arquivo instalado está executável e com shebang correto.
verify_installed() {
    local file="$1"
    [[ -x "$file" ]] || die "Instalado mas não executável: $file"
    [[ "$(head -c 2 "$file")" == "#!" ]] || die "Cópia instalada corrompida (sem shebang na 1ª linha): $file"
}

# Detecta Secure Boot e, se ativo, configura o DKMS para assinar o módulo com a
# chave MOK do usuário. Sem Secure Boot, não faz nada (módulo não precisa assinar).
configure_dkms_signing() {
    local sb="disabled"
    if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
        sb="enabled"
    elif [[ -d /sys/firmware/efi/efivars ]]; then
        # Fallback sem mokutil: último byte da efivar SecureBoot == 1 → ativo
        local sbvar
        sbvar=$(find /sys/firmware/efi/efivars -name 'SecureBoot-*' 2>/dev/null | head -1)
        if [[ -n "$sbvar" ]] && [[ "$(od -An -t u1 "$sbvar" 2>/dev/null | tr -s ' ' | awk '{print $NF}')" == "1" ]]; then
            sb="enabled"
        fi
    fi

    if [[ "$sb" != "enabled" ]]; then
        info "Secure Boot desligado/ausente — módulo não precisa de assinatura."
        return 0
    fi

    # Secure Boot ATIVO → o módulo precisa ser assinado a cada build.
    local key="" cert="" base
    for base in "${SUDO_USER:+/home/$SUDO_USER/module-signing}" /root/module-signing /var/lib/dkms/mok; do
        [[ -n "$base" ]] || continue
        if [[ -f "$base/MOK.priv" && -f "$base/MOK.der" ]]; then
            key="$base/MOK.priv"; cert="$base/MOK.der"; break
        fi
    done

    if [[ -z "$key" ]]; then
        warn "Secure Boot ATIVO, mas não encontrei chaves MOK (MOK.priv + MOK.der)."
        warn "O módulo compila, mas pode NÃO carregar até ser assinado e a chave inscrita."
        warn "Gere/importe as chaves (veja linuwu-sense/module_signing_readme) e rode o install.sh de novo."
        return 0
    fi

    info "Secure Boot ativo — DKMS vai assinar o módulo com $key"
    local fw=/etc/dkms/framework.conf
    touch "$fw"
    sed -i -E '/^[[:space:]]*(mok_signing_key|mok_certificate)=/d' "$fw"
    printf 'mok_signing_key="%s"\nmok_certificate="%s"\n' "$key" "$cert" >> "$fw"
}

# Registra o módulo linuwu_sense no DKMS para recompilar automaticamente a cada
# atualização de kernel (substitui o "make install LLVM=1" manual). Idempotente.
setup_dkms_module() {
    local SRC="$SCRIPT_DIR/linuwu-sense"
    local MOD="linuwu_sense"

    if ! command -v dkms >/dev/null; then
        warn "dkms não instalado — o módulo NÃO recompilará sozinho em updates de kernel."
        warn "Instale com: sudo pacman -S dkms   e rode este install.sh novamente."
        return 0
    fi
    if [[ ! -f "$SRC/dkms.conf" ]]; then
        warn "Source vendorizado do Linuwu-Sense ausente em $SRC — pulando setup do DKMS."
        return 0
    fi

    local VER
    VER="$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$SRC/dkms.conf")"
    [[ -n "$VER" ]] || VER="1.0"
    local DEST="/usr/src/${MOD}-${VER}"

    info "Registrando $MOD no DKMS (auto-rebuild a cada kernel)..."

    # Remove registros DKMS anteriores (qualquer versão) para idempotência
    local oldv
    while read -r oldv; do
        [[ -n "$oldv" ]] && dkms remove -m "$MOD" -v "$oldv" --all >/dev/null 2>&1 || true
    done < <(dkms status -m "$MOD" 2>/dev/null | sed -nE "s#^${MOD}/([^,]+),.*#\\1#p" | sort -u)

    # Copia o source vendorizado para /usr/src/<mod>-<ver>
    rm -rf "$DEST"
    install -d "$DEST"
    cp -a "$SRC/." "$DEST/"

    configure_dkms_signing

    dkms add -m "$MOD" -v "$VER" >/dev/null 2>&1 || true
    if dkms install -m "$MOD" -v "$VER" --force; then
        depmod -a
        info "Módulo $MOD compilado e instalado via DKMS para o kernel $(uname -r)."
        info "Próximos updates de kernel recompilam o módulo automaticamente."
    else
        warn "Falha ao compilar o módulo via DKMS. Log: /var/lib/dkms/$MOD/$VER/build/make.log"
    fi
}

# ── 1. Verifica dependências ───────────────────────────────────────────────────
info "Verificando dependências..."
command -v python3 >/dev/null || die "python3 não encontrado. Instale com: sudo pacman -S python"

# ── 1b. Registra o módulo de kernel no DKMS (auto-rebuild em updates) ──────────
setup_dkms_module

# ── 2. Verifica driver ────────────────────────────────────────────────────────
FAN_PATH="/sys/module/linuwu_sense/drivers/platform:acer-wmi/acer-wmi/predator_sense/fan_speed"
if [[ ! -e "$FAN_PATH" ]]; then
    warn "Driver Linuwu-Sense não detectado em $FAN_PATH"
    warn "Certifique-se que o módulo está carregado: lsmod | grep linuwu_sense"
    warn "Continuando instalação mesmo assim..."
fi

# ── 3. Instala o daemon ───────────────────────────────────────────────────────
info "Instalando daemon em /usr/local/bin/linuwu-fan-control..."
validate_script "$SCRIPT_DIR/linuwu-fan-control"
install -m 755 "$SCRIPT_DIR/linuwu-fan-control" /usr/local/bin/linuwu-fan-control
verify_installed /usr/local/bin/linuwu-fan-control

# ── 3b. Instala o CLI de controle ─────────────────────────────────────────────
info "Instalando CLI em /usr/local/bin/linuwu-fan-ctl..."
validate_script "$SCRIPT_DIR/linuwu-fan-ctl"
install -m 755 "$SCRIPT_DIR/linuwu-fan-ctl" /usr/local/bin/linuwu-fan-ctl
verify_installed /usr/local/bin/linuwu-fan-ctl

# ── 3c. Instala o wrapper de perfil (alvo da política polkit sem senha) ───────
info "Instalando linuwu-fan-profile em /usr/local/bin/..."
validate_script "$SCRIPT_DIR/linuwu-fan-profile"
install -m 755 "$SCRIPT_DIR/linuwu-fan-profile" /usr/local/bin/linuwu-fan-profile
verify_installed /usr/local/bin/linuwu-fan-profile

# ── 3d. Instala o applet de bandeja (KDE Plasma / system tray) ────────────────
info "Instalando applet de bandeja em /usr/local/bin/linuwu-fan-tray..."
validate_script "$SCRIPT_DIR/linuwu-fan-tray"
install -m 755 "$SCRIPT_DIR/linuwu-fan-tray" /usr/local/bin/linuwu-fan-tray
verify_installed /usr/local/bin/linuwu-fan-tray
if ! python3 -c "import PyQt6" 2>/dev/null; then
    warn "PyQt6 não encontrado — o applet de bandeja precisa dele para rodar."
    warn "Instale com: sudo pacman -S python-pyqt6   (o daemon e o CLI funcionam sem ele)"
fi

# ── 4. Instala configuração (não sobrescreve se já existir) ───────────────────
if [[ -f /etc/linuwu-fan-control.conf ]]; then
    warn "Configuração já existe em /etc/linuwu-fan-control.conf — mantendo a existente."
    warn "Nova config de exemplo salva em /etc/linuwu-fan-control.conf.new"
    install -m 644 "$SCRIPT_DIR/linuwu-fan-control.conf" /etc/linuwu-fan-control.conf.new
else
    info "Instalando configuração em /etc/linuwu-fan-control.conf..."
    install -m 644 "$SCRIPT_DIR/linuwu-fan-control.conf" /etc/linuwu-fan-control.conf
fi

# ── 4b. Instala perfis (não sobrescreve se já existir) ────────────────────────
if [[ -f /etc/linuwu-fan-control.profiles.conf ]]; then
    warn "Perfis já existem em /etc/linuwu-fan-control.profiles.conf — mantendo os existentes."
    install -m 644 "$SCRIPT_DIR/linuwu-fan-control.profiles.conf" /etc/linuwu-fan-control.profiles.conf.new
else
    info "Instalando perfis em /etc/linuwu-fan-control.profiles.conf..."
    install -m 644 "$SCRIPT_DIR/linuwu-fan-control.profiles.conf" /etc/linuwu-fan-control.profiles.conf
fi

# ── 4c. Instala política polkit (escrita via pkexec) ──────────────────────────
info "Instalando política polkit..."
install -m 644 "$SCRIPT_DIR/org.linuwu.fancontrol.policy" \
    /usr/share/polkit-1/actions/org.linuwu.fancontrol.policy

# ── 4d. Instala autostart + entrada de menu do applet ─────────────────────────
info "Instalando autostart e entrada de menu do applet..."
install -d /etc/xdg/autostart /usr/share/applications
install -m 644 "$SCRIPT_DIR/linuwu-fan-tray.desktop" /etc/xdg/autostart/linuwu-fan-tray.desktop
install -m 644 "$SCRIPT_DIR/linuwu-fan-tray.desktop" /usr/share/applications/linuwu-fan-tray.desktop

# ── 5. Instala serviço systemd ────────────────────────────────────────────────
info "Instalando serviço systemd..."
install -m 644 "$SCRIPT_DIR/linuwu-fan-control.service" /etc/systemd/system/linuwu-fan-control.service
systemctl daemon-reload

# ── 6. Habilita e inicia ──────────────────────────────────────────────────────
info "Habilitando serviço para iniciar no boot..."
systemctl enable linuwu-fan-control

info "Iniciando serviço..."
systemctl restart linuwu-fan-control || true

# ── 7. Auto-teste pós-instalação ──────────────────────────────────────────────
info "Verificando se o serviço subiu corretamente..."
sleep 1
if systemctl is-active --quiet linuwu-fan-control; then
    info "Serviço ativo (running)."
else
    warn "O serviço NÃO está ativo. Diagnóstico:"
    systemctl --no-pager --full status linuwu-fan-control 2>&1 | sed 's/^/    /' | head -20 || true
    die "Falha ao iniciar o serviço. Veja o diagnóstico acima e: journalctl -u linuwu-fan-control -n 50"
fi

# ── Resultado ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo -e "${GREEN}  Instalação concluída com sucesso!${NC}"
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo ""
echo "  Comandos úteis:"
echo ""
echo "  Interface interativa  :  linuwu-fan-ctl"
echo "  Status rápido         :  linuwu-fan-ctl status"
echo "  Status ao vivo        :  linuwu-fan-ctl status --watch"
echo "  Recarregar config     :  sudo linuwu-fan-ctl reload"
echo "  Ver configuração      :  linuwu-fan-ctl get"
echo "  Ajustar parâmetro     :  sudo linuwu-fan-ctl set power.target_watts 60"
echo "  Desativar controle    :  sudo linuwu-fan-ctl disable"
echo "  Reativar controle     :  sudo linuwu-fan-ctl enable"
echo ""
echo "  Applet de bandeja     :  linuwu-fan-tray &   (inicia sozinho no próximo login)"
echo "  Listar perfis         :  linuwu-fan-ctl list-profiles"
echo "  Aplicar perfil        :  linuwu-fan-profile gaming"
echo ""
echo "  Logs do serviço       :  sudo journalctl -fu linuwu-fan-control"
echo "  Parar (fan=auto)      :  sudo systemctl stop linuwu-fan-control"
echo "  Desligar do boot      :  sudo systemctl disable linuwu-fan-control"
echo ""
echo "  Configuração          :  /etc/linuwu-fan-control.conf"
echo "  Log                   :  /var/log/linuwu-fan-control.log"
echo ""
echo "  Módulo (DKMS)         :  dkms status -m linuwu_sense"
echo "  Recompila no kernel   :  automático (DKMS) — nada de 'make install' manual"
echo ""
