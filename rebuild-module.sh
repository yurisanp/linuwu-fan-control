#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# rebuild-module.sh — Recompila e recarrega o módulo de kernel linuwu_sense
# Execute com: sudo bash rebuild-module.sh
#
# Use quando alterar o source vendorizado em linuwu-sense/ (ex.: adicionar um
# quirk DMI para um modelo novo). Atualiza a árvore DKMS a partir do source do
# repo, recompila, recarrega o módulo e valida que a interface predator_sense /
# nitro_sense apareceu no sysfs.
# ══════════════════════════════════════════════════════════════════════════════
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
die()     { echo -e "${RED}[✗]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && die "Execute como root: sudo bash rebuild-module.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/linuwu-sense"
MOD="linuwu_sense"

command -v dkms >/dev/null || die "dkms não instalado (sudo pacman -S dkms)."
[[ -f "$SRC/dkms.conf" ]] || die "Source vendorizado ausente em $SRC."

VER="$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$SRC/dkms.conf")"
[[ -n "$VER" ]] || VER="1.0"
DEST="/usr/src/${MOD}-${VER}"
ACER_DIR="/sys/module/${MOD}/drivers/platform:acer-wmi/acer-wmi"

# ── 1. Para o serviço e atualiza o source do DKMS ──────────────────────────────
info "Parando serviço e atualizando source do DKMS ($DEST)..."
systemctl stop linuwu-fan-control 2>/dev/null || true
rm -rf "$DEST"
cp -a "$SRC" "$DEST"

# ── 2. Recompila via DKMS ──────────────────────────────────────────────────────
# Compila para o kernel atual (obrigatório) E para todos os outros kernels
# instalados que tenham headers (best-effort). Isso evita que as ventoinhas fiquem
# em turbo após bootar num kernel para o qual o módulo nunca foi compilado — o DKMS
# só rebuilda sozinho para kernels instalados DEPOIS do módulo ser registrado.
RUNNING="$(uname -r)"
info "Recompilando $MOD/$VER via DKMS para o kernel atual ($RUNNING)..."
dkms remove -m "$MOD" -v "$VER" --all >/dev/null 2>&1 || true
dkms add -m "$MOD" -v "$VER" >/dev/null 2>&1 || true
if ! dkms install -m "$MOD" -v "$VER" -k "$RUNNING" --force; then
    die "Falha ao compilar para $RUNNING. Log: /var/lib/dkms/$MOD/$VER/$RUNNING/build/make.log"
fi

for kdir in /lib/modules/*/; do
    k="$(basename "$kdir")"
    [[ "$k" == "$RUNNING" ]] && continue
    [[ -e "$kdir/build" ]] || continue   # sem headers → não dá para compilar
    if dkms install -m "$MOD" -v "$VER" -k "$k" --force >/dev/null 2>&1; then
        info "  também compilado para $k"
    else
        warn "  pulado $k (sem headers ou falha de build)"
    fi
done
depmod -a

# ── 3. Recarrega o módulo ──────────────────────────────────────────────────────
info "Recarregando o módulo..."
modprobe -r "$MOD" 2>/dev/null || true
modprobe "$MOD"

# ── 4. Valida que a interface apareceu no sysfs ────────────────────────────────
if [[ -e "$ACER_DIR/predator_sense/fan_speed" ]]; then
    info "Interface predator_sense ativa. fan_speed = $(cat "$ACER_DIR/predator_sense/fan_speed" 2>/dev/null)"
elif [[ -e "$ACER_DIR/nitro_sense/fan_speed" ]]; then
    info "Interface nitro_sense ativa. fan_speed = $(cat "$ACER_DIR/nitro_sense/fan_speed" 2>/dev/null)"
else
    warn "Módulo carregado, mas nenhuma interface predator_sense/nitro_sense apareceu."
    warn "Modelo provavelmente não reconhecido pelo DMI. Confira:"
    warn "  cat /sys/class/dmi/id/product_name   (e adicione um quirk em linuwu-sense/src/linuwu_sense.c)"
    die "Interface de controle de fan não disponível."
fi

# ── 5. Religa o serviço ────────────────────────────────────────────────────────
info "Religando o serviço..."
systemctl start linuwu-fan-control 2>/dev/null || true
info "Serviço: $(systemctl is-active linuwu-fan-control 2>/dev/null)"
info "Concluído."
