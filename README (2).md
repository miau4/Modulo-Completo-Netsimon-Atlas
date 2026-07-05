# Módulo Completo Netsimon Atlas

Upgrade da sincronização Atlas → Local do **Painel Netsimon 4.0**: retry automático, log detalhado e diagnóstico, sem duplicar o cron que o painel já tem.

## 🚀 Instalação (1 comando)

Na sua VPS, como root:

```bash
curl -fsSL https://raw.githubusercontent.com/miau4/Modulo-Completo-Netsimon-Atlas/main/instalar.sh -o /tmp/instalar.sh && bash /tmp/instalar.sh
```

---

## 📋 Pré-requisito

Este módulo é um **upgrade**, não uma instalação do zero. Ele espera encontrar:

- `/etc/painel/` já existente
- `/etc/painel/atlas.sh` com as funções `atlas_sync_users` e `atlas_listar_users`

Ou seja: o **Painel Netsimon 4.0 já precisa estar instalado e rodando** na VPS antes de rodar este script.

---

## 🔍 O que o `instalar.sh` faz

1. Confere se o painel base já está instalado (aborta com mensagem clara se não estiver)
2. Faz backup do `atlas_sync_cron.sh` atual (`atlas_sync_cron.sh.bak.AAAAMMDDHHMMSS`)
3. Substitui esse **mesmo arquivo** por uma versão robusta:
   - Retry automático (até 3 tentativas, 5s de intervalo) em falhas de rede
   - Log detalhado em `/var/log/atlas_sync.log`
   - Lock file próprio (evita execução paralela)
4. Instala o diagnóstico em `/etc/painel/atlas_sync_diagnostic.sh`
5. Confirma que `/etc/cron.d/atlas_sync` existe e aponta pro script certo — repara se estiver faltando, mas **nunca cria um segundo cron** (o painel já roda esse mesmo arquivo a cada minuto e no boot via `boot_check.sh`)
6. Roda uma sincronização de teste na hora e mostra o resultado

## Por que não cria um cron novo?

Porque duplicaria a sincronização. O `install.sh` original do painel já registra `/etc/painel/atlas_sync_cron.sh` em `/etc/cron.d/atlas_sync` (a cada minuto) e no `boot_check.sh` (no boot), sempre usando o mesmo lock (`/tmp/atlas_sync.lock`). Este módulo só melhora o **conteúdo** desse arquivo — o mecanismo que já dispara ele continua o mesmo.

---

## 🛠️ Comandos do dia a dia

| O que você quer | Comando |
|---|---|
| Ver status completo | `bash /etc/painel/atlas_sync_diagnostic.sh` |
| Monitorar em tempo real | `tail -f /var/log/atlas_sync.log` |
| Forçar sincronização agora | `/etc/painel/atlas_sync_cron.sh` |
| Ver cron instalado | `cat /etc/cron.d/atlas_sync` |
| Ver últimos erros | `grep "\[ERROR\]" /var/log/atlas_sync.log \| tail -10` |
| Configurar API Key | `nano /etc/painel/atlas.key` |

---

## 🔧 Troubleshooting rápido

**"API Key não configurada"**
```bash
nano /etc/painel/atlas.key
chmod 600 /etc/painel/atlas.key
/etc/painel/atlas_sync_cron.sh
```

**Log sem atualizar há mais de 1h**
```bash
cat /etc/cron.d/atlas_sync      # confirma se o cron existe
systemctl status cron           # confirma se o serviço de cron está ativo
```

**Lock travado**
```bash
rm -rf /tmp/atlas_sync.lock
/etc/painel/atlas_sync_cron.sh
```

**Reinstalar/atualizar o módulo**
```bash
curl -fsSL https://raw.githubusercontent.com/miau4/Modulo-Completo-Netsimon-Atlas/main/instalar.sh -o /tmp/instalar.sh && bash /tmp/instalar.sh
```
Rodar de novo é seguro — ele faz backup do script atual antes de sobrescrever.

---

## 📁 Arquivos deste repositório

- `instalar.sh` — instalador único (contém o script de sync e o de diagnóstico embutidos)
- `README.md` — este arquivo

---

**Compatível com:** Painel Netsimon 4.0+
