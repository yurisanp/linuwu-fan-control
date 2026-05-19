# CLAUDE.md — Contexto de desenvolvimento para Claude Code

Este arquivo descreve o projeto, decisões de design e áreas de desenvolvimento ativo para uso pelo Claude Code.

---

## O que é este projeto

`linuwu-fan-control` é um daemon Python que controla as ventoinhas de laptops **Acer Predator** no Linux, usando o driver de kernel [Linuwu-Sense](https://github.com/0x7375646F/Linuwu-Sense) como interface de hardware.

O controle é baseado em três fontes de dados simultâneas: temperatura do CPU, temperatura da GPU e consumo de watts (CPU via RAPL Intel, GPU via hwmon amdgpu). O daemon interpola curvas configuráveis e aplica um boost proporcional quando o consumo ultrapassa a meta de TDP definida pelo usuário.

---

## Hardware alvo

- **Laptop**: Acer Predator Triton PT316-51s
- **CPU**: Intel i7-12700H (Haswell, TDP oficial 88W)
- **GPU**: nvidia RTX 3060 (driver `amdgpu`)
- **OS**: CachyOS (base Arch Linux)
- **Kernel**: Linux zen 7.x
- **Driver de fan**: Linuwu-Sense (módulo de kernel customizado)

---

## Estrutura de arquivos

```
linuwu-fan-control          ← daemon principal, executável Python
linuwu-fan-control.conf     ← configuração INI instalada em /etc/
linuwu-fan-control.service  ← unit systemd
install.sh                  ← script de instalação (requer root)
README.md                   ← documentação do usuário
CLAUDE.md                   ← este arquivo
```

---

## Paths relevantes no sistema

| Recurso               | Path                                                                                              |
|-----------------------|---------------------------------------------------------------------------------------------------|
| Fan speed (sysfs)     | `/sys/module/linuwu_sense/drivers/platform:acer-wmi/acer-wmi/predator_sense/fan_speed`           |
| CPU temp              | `/sys/class/thermal/thermal_zone*/temp` (tipo `x86_pkg_temp`)                                    |
| GPU temp (amdgpu)     | `/sys/class/hwmon/hwmon*/temp2_input` ou `temp1_input`                                           |
| CPU watts (RAPL)      | `/sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj`                                          |
| GPU watts (amdgpu)    | `/sys/class/hwmon/hwmon*/power1_average`                                                          |
| Config instalada      | `/etc/linuwu-fan-control.conf`                                                                    |
| Log                   | `/var/log/linuwu-fan-control.log`                                                                 |
| Binário instalado     | `/usr/local/bin/linuwu-fan-control`                                                               |
| Serviço systemd       | `/etc/systemd/system/linuwu-fan-control.service`                                                  |

---

## Lógica principal do daemon (`linuwu-fan-control`)

### Classe `FanController`

- `__init__`: detecta paths de sensores via glob/hwmon, configura signal handlers
- `run()`: loop principal — lê config (com detecção de mudança via mtime), coleta sensores, calcula velocidade alvo, aplica histerese e rampa, escreve no sysfs
- `cpu_temp()` / `gpu_temp()`: retornam temperatura em °C (dividem por 1000)
- `cpu_watts()`: calcula potência via delta de `energy_uj` ao longo do tempo
- `gpu_watts()`: lê `power1_average` em µW e converte para W

### Funções utilitárias

- `parse_curve(raw)`: converte string `"45:20, 65:50"` em lista de tuplas ordenada
- `interpolate(curve, value)`: interpolação linear entre pontos da curva
- `ramp(current, target, step)`: limita variação máxima por ciclo
- `apply_hysteresis(current, desired, hyst)`: zona morta para redução de RPM
- `find_cpu_temp_path()`: descobre o sensor correto via `/sys/class/thermal/`
- `find_hwmon_path(name, *candidates)`: descobre paths hwmon pelo nome do driver

### Comportamento de `target_watts`

Quando `cpu_watts > target_watts`, o daemon aplica um boost extra nas ventoinhas proporcional ao excesso:
```python
excess_ratio = min((cw - target_w) / target_w, 1.0)
des_cpu = min(des_cpu + excess_ratio * (cpu_max - des_cpu), cpu_max)
des_gpu = min(des_gpu + excess_ratio * 0.7 * (gpu_max - des_gpu), gpu_max)
```
O fator 0.7 na GPU é intencional: a GPU é menos responsável pelo excesso de TDP do CPU.

---

## Decisões de design

- **Python puro sem dependências externas**: facilita instalação em qualquer distro Arch-based sem pip/venv
- **Reload sem restart**: o daemon detecta `mtime` do arquivo de config a cada ciclo e recarrega só quando muda — útil para tuning ao vivo
- **Máximo entre curvas**: em vez de média, usa `max()` entre todas as curvas ativas — garante que nenhuma fonte de calor seja ignorada
- **Rollover protection no RAPL**: contador de 32 bits pode fazer wrap-around; o daemon detecta e corrige
- **Fan=0 ao parar**: tanto via `ExecStop` no service quanto via signal handler, o daemon restaura controle automático do firmware

---

## Áreas de melhoria identificadas / TODO

### Alta prioridade

- [ ] **Suporte a Nitro**: o path do sysfs é diferente (`nitro_sense` vs `predator_sense`); detectar automaticamente qual está presente
- [ ] **Rollover do RAPL em 64 bits**: alguns kernels expõem `energy_uj` como 64 bits — verificar `max_energy_range_uj` para tratar corretamente
- [ ] **Sensor de GPU NVIDIA**: atualmente só detecta `amdgpu`; adicionar suporte via `nvidia-smi` ou `nvml`

### Média prioridade

- [ ] **CLI de diagnóstico**: script `linuwu-fan-status` que mostra temps, watts e velocidade atual em tempo real (sem precisar parsear journalctl)
- [ ] **Modo dry-run**: `--dry-run` para logar o que faria sem escrever no sysfs — útil para testar curvas
- [ ] **Múltiplos perfis de config**: ex: `[profile:gaming]`, `[profile:silent]`, alternáveis via CLI ou hotkey
- [ ] **Detecção de AC vs bateria**: aplicar curvas diferentes conforme fonte de energia (`/sys/class/power_supply/AC/online`)

### Baixa prioridade

- [ ] **Integração com `platform_profile`**: sincronizar com o perfil térmico do firmware ao trocar modo
- [ ] **Empacotamento AUR**: criar `PKGBUILD` para instalação via `yay`/`paru`
- [ ] **Testes automatizados**: mock dos paths sysfs para testar curvas e lógica sem hardware real

---

## Como rodar em desenvolvimento

```bash
# Testar o daemon diretamente (sem instalar):
sudo python3 linuwu-fan-control

# Verificar sensores disponíveis no sistema:
cat /sys/class/thermal/thermal_zone*/type
ls /sys/class/hwmon/
cat /sys/class/hwmon/hwmon*/name

# Ler potência RAPL manualmente:
cat /sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj

# Escrever fan speed manualmente para teste:
echo "50,40" | sudo tee /sys/module/linuwu_sense/drivers/platform:acer-wmi/acer-wmi/predator_sense/fan_speed

# Ver logs do serviço:
sudo journalctl -fu linuwu-fan-control
```

---

## Convenções de código

- Python 3.10+ (uso de `int | None` como type hint, match/case disponível se necessário)
- Sem dependências externas — stdlib apenas
- Logging via módulo `logging` padrão (não `print`)
- Paths de sysfs sempre via constantes ou variáveis de instância, nunca hardcoded dentro de métodos
- Erros de leitura de sensor retornam `None` (nunca levantam exceção para o caller) — o daemon deve degradar graciosamente quando um sensor não está disponível