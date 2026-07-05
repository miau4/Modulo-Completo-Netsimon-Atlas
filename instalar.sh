#!/bin/bash
# ============================================================================
#   MÓDULO COMPLETO NETSIMON ATLAS — Instalador Único (v2)
#   Repo: https://github.com/miau4/Modulo-Completo-Netsimon-Atlas
# ============================================================================
# CORREÇÕES NESTA VERSÃO (v2):
#   - REMOVIDO o lock interno (mkdir /tmp/atlas_sync.lock) que conflitava
#     com o flock (baseado em arquivo) já usado pelo /etc/cron.d/atlas_sync
#     e pelo boot_check.sh. Esse conflito travava a sincronização pra
#     sempre depois da primeira vez que o flock criava o arquivo.
#   - ADICIONADO auto-merge de usuários órfãos a cada ciclo: qualquer login
#     que já existe no Linux (useradd) mas não está em usuarios.db é
#     adicionado automaticamente. Isso cobre usuários criados por QUALQUER
#     processo (atlas_sync, modulo.py/atlas-modulo.service, manual, etc.),
#     não só os criados pelo fluxo normal do Atlas.
#
# O QUE ESTE SCRIPT FAZ:
#   1. Verifica se o Painel Netsimon 4.0 já está instalado
#   2. Faz backup do atlas_sync_cron.sh atual
#   3. Substitui esse MESMO arquivo pela versão corrigida (retry + log +
#      auto-merge de órfãos, SEM lock interno duplicado)
#   4. Instala/atualiza o diagnóstico em atlas_sync_diagnostic.sh
#   5. Garante que /etc/cron.d/atlas_sync existe (não duplica)
#   6. Roda um teste de sincronização na hora
#
# USO (na VPS, como root):
#   curl -fsSL https://raw.githubusercontent.com/miau4/Modulo-Completo-Netsimon-Atlas/main/instalar.sh -o /tmp/instalar.sh
#   bash /tmp/instalar.sh
# ============================================================================

set -u

BASE="/etc/painel"
ATLAS_SH="$BASE/atlas.sh"
CRON_SCRIPT="$BASE/atlas_sync_cron.sh"
DIAG_SCRIPT="$BASE/atlas_sync_diagnostic.sh"
SYNC_LOG="/var/log/atlas_sync.log"
CRON_D_FILE="/etc/cron.d/atlas_sync"

P=$'\033[1;35m'; G=$'\033[1;32m'; R=$'\033[1;31m'
Y=$'\033[1;33m'; W=$'\033[1;37m'; C=$'\033[1;36m'; NC=$'\033[0m'

echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${P}  Módulo Completo Netsimon Atlas — Instalador (v2)${NC}"
echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

# ────────────────────────────────────────────────────────────
# 0. VERIFICAÇÕES OBRIGATÓRIAS
# ────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${R}❌ Execute este script como root (sudo).${NC}"
    exit 1
fi

if [ ! -d "$BASE" ]; then
    echo -e "${R}❌ $BASE não encontrado.${NC}"
    echo -e "${Y}   Este módulo é um upgrade do Painel Netsimon 4.0. Instale o painel base primeiro.${NC}"
    exit 1
fi

if [ ! -f "$ATLAS_SH" ]; then
    echo -e "${R}❌ $ATLAS_SH não encontrado.${NC}"
    exit 1
fi

if ! grep -q "^atlas_sync_users()" "$ATLAS_SH" || ! grep -q "^atlas_listar_users()" "$ATLAS_SH"; then
    echo -e "${R}❌ $ATLAS_SH existe, mas não tem atlas_sync_users()/atlas_listar_users().${NC}"
    exit 1
fi

echo -e "${G}✓${NC} Painel Netsimon 4.0 detectado em $BASE"
echo -e "${G}✓${NC} atlas.sh com as funções necessárias\n"

# ────────────────────────────────────────────────────────────
# 0.1 DESTRAVA QUALQUER LOCK ANTIGO (do bug da v1)
# ────────────────────────────────────────────────────────────
if [ -d "/tmp/atlas_sync.lock" ]; then
    rmdir "/tmp/atlas_sync.lock" 2>/dev/null && \
        echo -e "${Y}⚠${NC} Removido um lock em formato de diretório deixado pela v1 (bug corrigido)\n"
fi

# ────────────────────────────────────────────────────────────
# 1. BACKUP DO SCRIPT ATUAL (se existir)
# ────────────────────────────────────────────────────────────
if [ -f "$CRON_SCRIPT" ]; then
    backup_name="${CRON_SCRIPT}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$CRON_SCRIPT" "$backup_name"
    echo -e "${G}✓${NC} Backup do script atual salvo em: ${C}$backup_name${NC}"
fi

# ────────────────────────────────────────────────────────────
# 2. INSTALA A VERSÃO CORRIGIDA DO atlas_sync_cron.sh
# ────────────────────────────────────────────────────────────
echo -e "${Y}[1/4] Instalando atlas_sync_cron.sh (retry + log + auto-merge de órfãos)...${NC}"

cat > "$CRON_SCRIPT" << 'CRON_SCRIPT_EOF'
#!/bin/bash
# ==========================================
# NETSIMON 4.0 - SINCRONIZAÇÃO ATLAS (CRON)
# ==========================================
# Chamado a cada minuto por /etc/cron.d/atlas_sync e uma vez no boot por
# boot_check.sh — AMBOS já usam "flock -n /tmp/atlas_sync.lock" (lock em
# ARQUIVO) para garantir execução única. Por isso este script NÃO TEM
# lock interno próprio: um segundo mecanismo de lock (ex.: mkdir no mesmo
# caminho) colidiria com o flock e travaria a sincronização para sempre.
#
# - Retry automático (até 3 tentativas) em falhas de rede
# - Logging detalhado em /var/log/atlas_sync.log
# - Auto-merge de órfãos: qualquer usuário que já existe no Linux (criado
#   pelo atlas_sync, pelo atlas-modulo.service/modulo.py, ou manualmente)
#   mas não está em usuarios.db é adicionado automaticamente a cada ciclo.
#   Isso NÃO altera a senha real do usuário — só cria a linha que faltava.

set -u
BASE="/etc/painel"
ATLAS_SH="$BASE/atlas.sh"
USERDB="$BASE/usuarios.db"
XRAY_CONF="/usr/local/etc/xray/config.json"
SYNC_LOG="/var/log/atlas_sync.log"
MAX_RETRIES=3
RETRY_DELAY=5
LOG_LEVEL_DEBUG=0  # Mude para 1 para verbose

log_msg() {
    local level="$1" msg="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $msg" | tee -a "$SYNC_LOG"
}
log_debug() { [ "$LOG_LEVEL_DEBUG" -eq 1 ] && log_msg "DEBUG" "$1" || true; }
log_info()  { log_msg "INFO" "$1"; }
log_warn()  { log_msg "WARN" "$1"; }
log_error() { log_msg "ERROR" "$1" >&2; }

pre_sync_checks() {
    if [ ! -f "$ATLAS_SH" ]; then
        log_error "atlas.sh não encontrado em $ATLAS_SH"
        return 1
    fi
    if [ ! -f "$BASE/atlas.key" ] || [ ! -s "$BASE/atlas.key" ]; then
        log_warn "API Key não configurada. Sincronização com Atlas abortada (auto-merge de órfãos continua rodando)."
        return 1
    fi
    if [ "$(id -u)" -ne 0 ]; then
        log_error "Este script deve ser executado como root"
        return 1
    fi
    return 0
}

do_sync_with_retry() {
    local attempt=1
    local resultado=""
    local xray_before xray_after

    xray_before=$(jq '[.inbounds[].settings.clients[]? | .email] | length' \
        "$XRAY_CONF" 2>/dev/null || echo "0")
    log_debug "Clientes Xray antes: $xray_before"

    while [ $attempt -le $MAX_RETRIES ]; do
        log_info "Tentativa $attempt/$MAX_RETRIES de sincronização..."

        source "$ATLAS_SH" 2>/dev/null || {
            log_error "Falha ao carregar atlas.sh"
            return 1
        }

        resultado=$(atlas_sync_users 2>&1)
        local sync_exit=$?

        if [ $sync_exit -eq 0 ]; then
            log_info "✅ Sincronização bem-sucedida: $resultado"

            xray_after=$(jq '[.inbounds[].settings.clients[]? | .email] | length' \
                "$XRAY_CONF" 2>/dev/null || echo "0")
            log_debug "Clientes Xray depois: $xray_after"

            if [ "$xray_before" -ne "$xray_after" ]; then
                log_info "Mudança detectada no Xray: $xray_before → $xray_after clientes"
            fi
            return 0
        fi

        if echo "$resultado" | grep -iq "sem resposta do Atlas\|timeout\|conexão\|rede"; then
            log_warn "Erro temporário de rede detectado: $resultado"
            if [ $attempt -lt $MAX_RETRIES ]; then
                log_info "Aguardando ${RETRY_DELAY}s antes de retry..."
                sleep "$RETRY_DELAY"
            fi
        else
            log_error "Erro crítico (não vai fazer retry): $resultado"
            return 1
        fi

        ((attempt++))
    done

    log_error "Sincronização falhou após $MAX_RETRIES tentativas: $resultado"
    return 1
}

# ---------------------------------------------------------------
# AUTO-MERGE DE ÓRFÃOS
# Roda todo ciclo, independente do resultado da sincronização com o
# Atlas. Cobre usuários criados por QUALQUER processo (modulo.py,
# atlas_sync, manual) que tenham ficado de fora do usuarios.db.
# Não mexe na senha real (/etc/shadow) — só grava a linha que faltava.
# ---------------------------------------------------------------
merge_orphans() {
    [ ! -f "$USERDB" ] && touch "$USERDB"

    local orfaos
    orfaos=$(comm -23 \
        <(awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' /etc/passwd | sort) \
        <(cut -d'|' -f1 "$USERDB" 2>/dev/null | sort))

    [ -z "$orfaos" ] && return 0

    local login uuid expira limite senha
    while IFS= read -r login; do
        [ -z "$login" ] && continue

        uuid=""
        if [ -f "$XRAY_CONF" ]; then
            uuid=$(jq -r --arg u "$login" \
                '[.inbounds[].settings.clients[]? | select(.email == $u) | .id][0] // empty' \
                "$XRAY_CONF" 2>/dev/null)
        fi
        [ -z "$uuid" ] && uuid=$(cat /proc/sys/kernel/random/uuid)

        expira=$(chage -l "$login" 2>/dev/null | grep "Account expires" | cut -d: -f2 | sed 's/^ *//')
        if [ -z "$expira" ] || [ "$expira" = "never" ]; then
            expira="$(date -d '+30 days' +'%Y-%m-%d 23:59:59')"
        else
            expira=$(date -d "$expira" +'%Y-%m-%d 23:59:59' 2>/dev/null || date -d '+30 days' +'%Y-%m-%d 23:59:59')
        fi

        limite=1
        senha="(sync-pendente)"

        echo "$login|$uuid|$expira|$senha|$limite" >> "$USERDB"
        log_info "AUTO-MERGE: '$login' existia no Linux/Xray mas não em usuarios.db — adicionado (senha real não foi alterada)."
    done <<< "$orfaos"
}

cleanup_old_logs() {
    find /var/log -maxdepth 1 -name "atlas_sync.log.*" -mtime +7 -delete 2>/dev/null || true
}

main() {
    log_debug "=== Iniciando ciclo de sincronização Atlas ==="

    merge_orphans

    if ! pre_sync_checks; then
        log_debug "Pré-checks da API não passaram (auto-merge já rodou de qualquer forma)."
        return 1
    fi

    if do_sync_with_retry; then
        log_debug "Ciclo concluído com sucesso"
        cleanup_old_logs
        return 0
    else
        log_error "Ciclo falhou"
        return 1
    fi
}

main "$@"
exit $?
CRON_SCRIPT_EOF

chmod 755 "$CRON_SCRIPT"
echo -e "${G}✓${NC} $CRON_SCRIPT atualizado (sem lock interno, com auto-merge)\n"

# ────────────────────────────────────────────────────────────
# 3. INSTALA O DIAGNÓSTICO
# ────────────────────────────────────────────────────────────
echo -e "${Y}[2/4] Instalando atlas_sync_diagnostic.sh...${NC}"

cat > "$DIAG_SCRIPT" << 'DIAG_SCRIPT_EOF'
#!/bin/bash
set -u
BASE="/etc/painel"
CRON_SCRIPT="$BASE/atlas_sync_cron.sh"
SYNC_LOG="/var/log/atlas_sync.log"
USERDB="/etc/painel/usuarios.db"
XRAY_CONF="/usr/local/etc/xray/config.json"
CRON_D_FILE="/etc/cron.d/atlas_sync"

P=$'\033[1;35m'; G=$'\033[1;32m'; R=$'\033[1;31m'
Y=$'\033[1;33m'; W=$'\033[1;37m'; C=$'\033[1;36m'; NC=$'\033[0m'

echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${P}  Diagnóstico: Sincronização Atlas${NC}"
echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

echo -e "${Y}[1] Arquivos de Configuração${NC}\n"
files=(
    "$BASE/atlas.sh:atlas.sh (principal)"
    "$BASE/atlas.key:API Key"
    "$CRON_SCRIPT:Script de Sincronização"
    "$SYNC_LOG:Log de Sincronização"
    "$USERDB:Banco de dados de usuários"
    "$XRAY_CONF:Configuração Xray"
)
for file_check in "${files[@]}"; do
    file="${file_check%:*}"; desc="${file_check#*:}"
    if [ -f "$file" ]; then
        if [ -s "$file" ]; then
            size=$(du -h "$file" | cut -f1)
            echo -e "   ${G}✓${NC} $desc (${Y}$size${NC})"
        else
            echo -e "   ${R}✗${NC} $desc (${R}vazio${NC})"
        fi
    else
        echo -e "   ${R}✗${NC} $desc (${R}não encontrado${NC})"
    fi
done
echo

echo -e "${Y}[2] Lock ATUAL (deve estar OK — arquivo, não diretório)${NC}\n"
if [ -d "/tmp/atlas_sync.lock" ]; then
    echo -e "   ${R}✗ /tmp/atlas_sync.lock é um DIRETÓRIO — isso é o bug antigo, remova com: rmdir /tmp/atlas_sync.lock${NC}"
elif [ -f "/tmp/atlas_sync.lock" ]; then
    echo -e "   ${G}✓${NC} /tmp/atlas_sync.lock existe como arquivo (normal, é o flock)"
else
    echo -e "   ${Y}⚠${NC} /tmp/atlas_sync.lock ainda não foi criado (cron não rodou ainda)"
fi
echo

echo -e "${Y}[3] Usuários órfãos (Linux sem entrada em usuarios.db)${NC}\n"
orfaos=$(comm -23 \
    <(awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' /etc/passwd | sort) \
    <(cut -d'|' -f1 "$USERDB" 2>/dev/null | sort))
if [ -z "$orfaos" ]; then
    echo -e "   ${G}✓ Nenhum órfão encontrado.${NC}"
else
    echo -e "   ${Y}⚠ Órfãos encontrados (serão auto-mesclados no próximo ciclo do cron):${NC}"
    echo "$orfaos" | sed 's/^/      /'
fi
echo

echo -e "${Y}[4] Configuração da API Atlas${NC}\n"
if [ -f "$BASE/atlas.key" ] && [ -s "$BASE/atlas.key" ]; then
    key=$(cat "$BASE/atlas.key")
    key_masked="${key:0:10}...${key: -10}"
    echo -e "   ${G}✓${NC} API Key configurada: ${C}$key_masked${NC}"
    source "$BASE/atlas.sh" 2>/dev/null || true
    if command -v atlas_listar_users >/dev/null 2>&1; then
        resp=$(atlas_listar_users 2>/dev/null)
        if echo "$resp" | python3 -c "import sys, json; json.loads(sys.stdin.read())" 2>/dev/null; then
            qtd=$(echo "$resp" | python3 -c "import sys, json; print(len(json.loads(sys.stdin.read())))" 2>/dev/null)
            echo -e "      ${G}✓${NC} Conexão OK (${C}$qtd${NC} usuários no Atlas)"
        else
            echo -e "      ${R}✗${NC} Resposta inválida do Atlas"
        fi
    fi
else
    echo -e "   ${R}✗${NC} API Key não configurada! Execute: nano $BASE/atlas.key"
fi
echo

echo -e "${Y}[5] Status do Cron (/etc/cron.d/atlas_sync)${NC}\n"
if [ -f "$CRON_D_FILE" ] && grep -q "atlas_sync_cron.sh" "$CRON_D_FILE" 2>/dev/null; then
    echo -e "   ${G}✓${NC} Cron instalado: ${C}$(cat "$CRON_D_FILE")${NC}"
    if [ -f "$SYNC_LOG" ]; then
        echo -e "   ${G}✓${NC} Última execução: ${Y}$(tail -1 "$SYNC_LOG")${NC}"
    fi
else
    echo -e "   ${R}✗${NC} Cron NÃO está instalado em $CRON_D_FILE"
fi
echo

echo -e "${Y}[6] Log recente${NC}\n"
if [ -f "$SYNC_LOG" ] && [ -s "$SYNC_LOG" ]; then
    error_count=$(grep -c "\[ERROR\]" "$SYNC_LOG" || true)
    warn_count=$(grep -c "\[WARN\]" "$SYNC_LOG" || true)
    echo -e "   WARN: ${Y}$warn_count${NC} | ERROR: ${R}$error_count${NC}\n"
    tail -8 "$SYNC_LOG" | sed 's/^/   /'
else
    echo -e "   ${Y}⚠${NC} Log vazio ou não existe ainda"
fi
echo

echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${C}💡 Comandos úteis:${NC}"
echo -e "   Monitorar log:        ${Y}tail -f $SYNC_LOG${NC}"
echo -e "   Forçar sincronização: ${Y}$CRON_SCRIPT${NC}"
echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
DIAG_SCRIPT_EOF

chmod 755 "$DIAG_SCRIPT"
echo -e "${G}✓${NC} $DIAG_SCRIPT instalado\n"

# ────────────────────────────────────────────────────────────
# 4. GARANTE O CRON.D (não duplica, só repara se estiver ausente)
# ────────────────────────────────────────────────────────────
echo -e "${Y}[3/4] Verificando /etc/cron.d/atlas_sync...${NC}"

if [ -f "$CRON_D_FILE" ] && grep -q "atlas_sync_cron.sh" "$CRON_D_FILE"; then
    echo -e "${G}✓${NC} Cron já estava instalado, nada a fazer\n"
else
    echo "* * * * * root flock -n /tmp/atlas_sync.lock $CRON_SCRIPT" > "$CRON_D_FILE"
    chmod 644 "$CRON_D_FILE"
    echo -e "${G}✓${NC} Cron recriado em $CRON_D_FILE\n"
fi

touch "$SYNC_LOG"
chmod 640 "$SYNC_LOG"

# ────────────────────────────────────────────────────────────
# 5. TESTE INICIAL (usando o MESMO flock do cron real, pra validar
#    que não há mais conflito de lock)
# ────────────────────────────────────────────────────────────
echo -e "${Y}[4/4] Executando teste inicial de sincronização...${NC}\n"

if flock -n /tmp/atlas_sync.lock "$CRON_SCRIPT"; then
    echo -e "${G}✓ Teste executado. Veja o resultado no log abaixo:${NC}"
else
    echo -e "${Y}⚠ Teste retornou com aviso/erro. Veja o log abaixo para detalhes:${NC}"
fi
echo
tail -8 "$SYNC_LOG" 2>/dev/null
echo

# ────────────────────────────────────────────────────────────
# RESUMO
# ────────────────────────────────────────────────────────────
echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${G}✅ Módulo Atlas (v2) instalado com sucesso!${NC}"
echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
echo -e "${C}📝 Arquivos:${NC}"
echo -e "   Script sync:   ${Y}$CRON_SCRIPT${NC}"
echo -e "   Diagnóstico:   ${Y}$DIAG_SCRIPT${NC}"
echo -e "   Log:           ${Y}$SYNC_LOG${NC}"
echo -e "   Cron:          ${Y}$CRON_D_FILE${NC}"
echo
echo -e "${C}🔍 Próximos passos:${NC}"
echo -e "   Verificar status:  ${Y}bash $DIAG_SCRIPT${NC}"
echo -e "   Monitorar em real: ${Y}tail -f $SYNC_LOG${NC}"
echo
