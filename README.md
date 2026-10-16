# linuwu-fan-control

Daemon de controle de ventoinhas para laptops **Acer Predator** rodando Linux, usando o driver [Linuwu-Sense](https://github.com/0x7375646F/Linuwu-Sense) como backend de hardware.

O objetivo é manter um perfil térmico silencioso e estável, com ventoinhas controladas por curvas de temperatura e uma **meta de consumo em watts**, evitando saltos bruscos de RPM.

---

## Funcionalidades

- Controle independente das ventoinhas de CPU e GPU
- Curvas de fan speed configuráveis por **temperatura CPU**, **temperatura GPU** e **watts totais**
- **Meta de TDP**: boost automático proporcional quando o CPU ultrapassa o alvo de watts
- Rampa suave e histerese — sem variações abruptas de RPM
- Recarrega a configuração automaticamente ao detectar mudanças no arquivo (sem reiniciar o serviço)
- Persistência via **systemd** com enable/disable sem reboot
- **Início cedo no boot** — assume o controle logo após o módulo carregar, sem esperar a tela de login (evita ventoinhas a 100% durante todo o boot em modo turbo)
- **Applet de bandeja (KDE Plasma)** — monitor ao vivo, controles rápidos, perfis e troca automática para *gaming* via Feral GameMode
- Ao parar o serviço, devolve controle automático ao firmware (`fan=0`)

---

## Requisitos

- Kernel Linux com o módulo **Linuwu-Sense** carregado
- Python 3.10+
- powercap habilitado no kernel (para leitura de watts via RAPL)
- `amdgpu` como driver da GPU (para temperatura e potência da GPU)

---

## Instalação

```bash
git clone https://github.com/SEU_USUARIO/linuwu-fan-control.git
cd linuwu-fan-control
sudo bash install.sh
```

O script de instalação:
1. **Valida** os scripts antes de copiar (shebang na 1ª linha + sintaxe Python) — evita o erro `status=203/EXEC` no systemd
2. Copia o daemon e o CLI `linuwu-fan-ctl` para `/usr/local/bin/`
3. **Registra o módulo `linuwu_sense` no DKMS** para recompilação automática a cada atualização de kernel (veja abaixo)
4. Instala a configuração em `/etc/linuwu-fan-control.conf` (não sobrescreve se já existir)
5. Instala e habilita o serviço systemd, iniciando o controle **cedo no boot**
6. Faz um auto-teste pós-instalação (confirma que o serviço subiu)

---

## Recompilação automática do módulo (DKMS)

O módulo de kernel **Linuwu-Sense** precisa ser recompilado a cada atualização de kernel. Em vez de rodar `make install LLVM=1` manualmente toda vez, o `install.sh` registra o módulo no **DKMS**, que o recompila sozinho via hook do pacman sempre que o kernel muda.

- O source do módulo é **vendorizado** em [`linuwu-sense/`](linuwu-sense/) (autocontido no repositório), com seu próprio [`dkms.conf`](linuwu-sense/dkms.conf).
- A toolchain é detectada por kernel: `LLVM=1` só é usado se o `.config` do kernel alvo for Clang (`linux-cachyos`); `linux-cachyos-lts` e `linux` (Arch) são GCC e compilam sem `LLVM=1`.
- **Secure Boot**: o instalador detecta automaticamente (`mokutil --sb-state`) e, se ativo, configura o DKMS para assinar o módulo com a chave MOK em `~/module-signing/` (`MOK.priv` + `MOK.der`). Sem Secure Boot, nenhuma assinatura é necessária.

```bash
# Ver o estado do módulo no DKMS
dkms status -m linuwu_sense

# Forçar recompilação manual (normalmente desnecessário)
sudo dkms install -m linuwu_sense -v 1.0 --force
```

> **Setup único não gerenciado pelo DKMS:** blacklist do `acer_wmi`, grupo `linuwu_sense`, permissões via `tmpfiles.d` e o `linuwu_sense.service` são configurados pelo `Makefile` upstream na primeira instalação do driver. O DKMS cuida apenas da recompilação do `.ko`.

---

## Uso

```bash
# Ver status e últimos logs
sudo systemctl status linuwu-fan-control

# Acompanhar logs em tempo real
sudo journalctl -fu linuwu-fan-control

# Parar (ventoinhas voltam ao controle do firmware)
sudo systemctl stop linuwu-fan-control

# Iniciar
sudo systemctl start linuwu-fan-control

# Remover do boot
sudo systemctl disable linuwu-fan-control

# Adicionar ao boot
sudo systemctl enable linuwu-fan-control
```

Após editar `/etc/linuwu-fan-control.conf`, o daemon recarrega sozinho. Para forçar reload imediato:

```bash
sudo systemctl restart linuwu-fan-control
```

---

## Configuração

Arquivo: `/etc/linuwu-fan-control.conf`

```ini
[general]
enabled       = true   # false → firmware assume controle
poll_interval = 2      # segundos entre leituras
ramp_step     = 5      # % máximo de variação por ciclo
hysteresis    = 4      # zona morta antes de reduzir RPM

[power]
target_watts = 50      # meta de TDP para CPU em carga alta
curve = 15:15, 25:28, 35:40, 50:58, 70:75, 90:90, 110:100

[cpu_temp]
curve = 45:20, 55:35, 65:50, 75:68, 85:88, 95:100

[gpu_temp]
curve = 45:20, 55:33, 65:48, 75:65, 85:85, 95:100

[limits]
cpu_fan_min = 0
cpu_fan_max = 100
gpu_fan_min = 0
gpu_fan_max = 100
```

### Formato das curvas

`temp_ou_watts:fan_speed, ...` — o daemon interpola linearmente entre os pontos e usa o **máximo** entre todas as curvas ativas no momento.

---

## Applet de bandeja (KDE Plasma)

O `linuwu-fan-tray` adiciona um ícone na bandeja do sistema (system tray) com
monitor ao vivo e controles gráficos. Requer **PyQt6** (`sudo pacman -S python-pyqt6`)
e inicia sozinho no login (autostart instalado em `/etc/xdg/autostart/`).

- **Tooltip/ícone:** temperatura, watts e % das ventoinhas, atualizados a cada 2s.
- **Painel (clique):** liga/desliga o controle, slider de `target_watts` e de teto das
  ventoinhas (aplicados ao soltar o slider).
- **Menu (botão direito):** perfis, auto-perfil no GameMode, janela de configurações.
- **Janela de configurações:** edita todos os parâmetros (`general.*`, `power.target_watts`,
  `limits.*` e curvas).

Iniciar manualmente sem relogar: `linuwu-fan-tray &`.

### Perfis

Perfis são predefinições em `/etc/linuwu-fan-control.profiles.conf` (seções
`[profile:NOME]`). Os padrões são **default**, **gaming** (resfriamento agressivo) e
**silent** (mais silencioso). Aplicar um perfil copia seus valores para a config ativa
e recarrega o daemon.

```bash
linuwu-fan-ctl list-profiles
linuwu-fan-profile gaming         # aplica (sem senha — ver abaixo)
```

### Troca automática no GameMode

Com o **Feral GameMode** instalado, ao iniciar um jogo via `gamemoderun` a tray aplica
automaticamente o perfil **gaming** e, ao encerrar, volta ao perfil anterior. Pode ser
ligado/desligado no menu ("Auto-perfil no GameMode").

### Permissões (polkit)

A leitura é feita direto dos arquivos (sem root). A escrita usa **pkexec** com duas
políticas polkit (`org.linuwu.fancontrol.policy`):

| Ação | Senha |
|------|-------|
| Aplicar perfil predefinido (`linuwu-fan-profile`) — manual ou via GameMode | **Não** (conjunto fechado e seguro) |
| Escrita arbitrária — sliders, configurações, enable/disable (`linuwu-fan-ctl`) | **Sim**, em cache por alguns minutos (`auth_admin_keep`) |

Para exigir senha também nos perfis, troque `yes`→`auth_admin_keep` na ação
`org.linuwu.fancontrol.apply-profile` do arquivo de política.

---

## Arquitetura

```
linuwu-fan-control            ← daemon principal (Python)
linuwu-fan-ctl                ← CLI de controle/diagnóstico (+ perfis)
linuwu-fan-tray               ← applet de bandeja KDE Plasma (PyQt6)
linuwu-fan-profile            ← wrapper root p/ aplicar perfil (polkit sem senha)
linuwu-fan-control.conf       ← configuração ativa
linuwu-fan-control.profiles.conf ← perfis (default/gaming/silent)
linuwu-fan-control.service    ← unit systemd (início cedo no boot)
org.linuwu.fancontrol.policy  ← política polkit (pkexec)
linuwu-fan-tray.desktop       ← autostart + entrada de menu
install.sh                    ← script de instalação (valida + registra DKMS)
linuwu-sense/                 ← source vendorizado do módulo (DKMS)
```

### Fluxo do daemon

```
Leitura de sensores
  ├── CPU temp   (/sys/class/thermal/…/temp)
  ├── GPU temp   (/sys/class/hwmon/…/temp*_input)
  ├── CPU watts  (/sys/class/powercap/intel-rapl:0/energy_uj via delta)
  └── GPU watts  (/sys/class/hwmon/…/power1_average)
        │
        ▼
Interpolação nas curvas (cpu_temp, gpu_temp, power)
        │
        ▼
max(todas as curvas) + boost proporcional ao excesso de target_watts
        │
        ▼
Histerese → Rampa suave (ramp_step)
        │
        ▼
echo "CPU,GPU" → fan_speed (sysfs Linuwu-Sense)
```

---

## Hardware testado

| Componente | Modelo                   |
|------------|--------------------------|
| Laptop     | Acer Predator            |
| CPU        | Intel i7-4790 (Haswell)  |
| GPU        | AMD RX 5500 XT           |
| OS         | CachyOS (Arch-based)     |
| Kernel     | Linux 6.x zen            |

---

## Licença

MIT