#!/bin/bash
# ============================================================================
#   MÓDULO COMPLETO NETSIMON ATLAS — Instalador Único
#   Repo: https://github.com/miau4/Modulo-Completo-Netsimon-Atlas
# ============================================================================
# O QUE ESTE SCRIPT FAZ:
#   1. Verifica se o Painel Netsimon 4.0 já está instalado (/etc/painel +
#      /etc/painel/atlas.sh com as funções atlas_sync_users/atlas_listar_users)
#   2. Faz backup do atlas_sync_cron.sh atual (a versão simples criada pelo
#      install.sh original do painel)
#   3. Substitui esse MESMO arquivo por uma versão robusta: retry automático,
#      log detalhado em /var/log/atlas_sync.log, lock file próprio
#   4. Instala o script de diagnóstico em /etc/painel/atlas_sync_diagnostic.sh
#   5. Garante que o /etc/cron.d/atlas_sync existe e aponta pro caminho certo
#      (não cria um segundo cron — usa o mesmo mecanismo que o painel já tem)
#   6. Roda um teste de sincronização na hora
#
# IMPORTANTE: este script NÃO instala o Netsimon 4.0 do zero. Ele é um
# MÓDULO/UPGRADE para um painel que já está rodando na VPS.
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
echo -e "${P}  Módulo Completo Netsimon Atlas — Instalador${NC}"
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
    echo -e "${Y}   Este módulo é um upgrade do Painel Netsimon 4.0.${NC}"
    echo -e "${Y}   Instale o painel base primeiro, depois rode este script.${NC}"
    exit 1
fi

if [ ! -f "$ATLAS_SH" ]; then
    echo -e "${R}❌ $ATLAS_SH não encontrado.${NC}"
    echo -e "${Y}   Sem o atlas.sh do painel, este módulo não tem o que sincronizar.${NC}"
    exit 1
fi

# Confirma que as funções essenciais existem dentro do atlas.sh
if ! grep -q "^atlas_sync_users()" "$ATLAS_SH" || ! grep -q "^atlas_listar_users()" "$ATLAS_SH"; then
    echo -e "${R}❌ $ATLAS_SH existe, mas não tem atlas_sync_users()/atlas_listar_users().${NC}"
    echo -e "${Y}   Verifique se é a versão correta do painel antes de continuar.${NC}"
    exit 1
fi

echo -e "${G}✓${NC} Painel Netsimon 4.0 detectado em $BASE"
echo -e "${G}✓${NC} atlas.sh com as funções necessárias\n"

# ────────────────────────────────────────────────────────────
# 1. BACKUP DO SCRIPT ATUAL (se existir)
# ────────────────────────────────────────────────────────────
if [ -f "$CRON_SCRIPT" ]; then
    backup_name="${CRON_SCRIPT}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$CRON_SCRIPT" "$backup_name"
    echo -e "${G}✓${NC} Backup do script atual salvo em: ${C}$backup_name${NC}"
fi

# ────────────────────────────────────────────────────────────
# 2. INSTALA A VERSÃO ROBUSTA DO atlas_sync_cron.sh
#    (mesmo caminho já usado pelo /etc/cron.d/atlas_sync e pelo
#    boot_check.sh do painel — não precisamos criar cron novo)
# ────────────────────────────────────────────────────────────
echo -e "${Y}[1/4] Instalando atlas_sync_cron.sh (versão com retry + log)...${NC}"

cat > "$CRON_SCRIPT" << 'CRON_SCRIPT_EOF'
#!/bin/bash
# ==========================================
# NETSIMON 4.0 - SINCRONIZAÇÃO ATLAS (CRON)
# ==========================================
# Chamado a cada minuto por /etc/cron.d/atlas_sync e também
# uma vez no boot por boot_check.sh (mesmo flock, mesmo arquivo).
#
# - Retry automático (até 3 tentativas) em falhas de rede
# - Logging detalhado em /var/log/atlas_sync.log
# - Lock file próprio para evitar execução paralela
# - Diferencia falha temporária (retry) de falha crítica (aborta)

set -u
BASE="/etc/painel"
ATLAS_SH="$BASE/atlas.sh"
SYNC_LOCK="/tmp/atlas_sync.lock"
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
        log_warn "API Key não configurada. Sincronização abortada."
        return 1
    fi
    if [ "$(id -u)" -ne 0 ]; then
        log_error "Este script deve ser executado como root"
        return 1
    fi
    return 0
}

acquire_lock() {
    local timeout=60
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if mkdir "$SYNC_LOCK" 2>/dev/null; then
            trap 'rmdir "$SYNC_LOCK" 2>/dev/null' EXIT
            log_debug "Lock adquirido"
            return 0
        fi
        sleep 1
        ((elapsed++))
    done
    log_warn "Não conseguiu adquirir lock após ${timeout}s. Abortando."
    return 1
}

do_sync_with_retry() {
    local attempt=1
    local resultado=""
    local xray_before xray_after

    xray_before=$(jq '[.inbounds[].settings.clients[]? | .email] | length' \
        /usr/local/etc/xray/config.json 2>/dev/null || echo "0")
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
                /usr/local/etc/xray/config.json 2>/dev/null || echo "0")
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

cleanup_old_logs() {
    find /var/log -maxdepth 1 -name "atlas_sync.log.*" -mtime +7 -delete 2>/dev/null || true
}

main() {
    log_debug "=== Iniciando ciclo de sincronização Atlas ==="

    if ! pre_sync_checks; then
        log_error "Pré-checks falharam. Abortando."
        return 1
    fi

    if ! acquire_lock; then
        log_debug "Outra sincronização em andamento. Pulando esta rodada."
        return 0
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
echo -e "${G}✓${NC} $CRON_SCRIPT atualizado\n"

# ────────────────────────────────────────────────────────────
# 3. INSTALA O DIAGNÓSTICO
# ────────────────────────────────────────────────────────────
echo -e "${Y}[2/4] Instalando atlas_sync_diagnostic.sh...${NC}"

cat > "$DIAG_SCRIPT" << 'DIAG_SCRIPT_EOF'
#!/bin/bash
# ==========================================
# DIAGNÓSTICO: Sincronização Atlas (Netsimon 4.0)
# ==========================================
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

echo -e "${Y}[2] Configuração da API Atlas${NC}\n"
if [ -f "$BASE/atlas.key" ] && [ -s "$BASE/atlas.key" ]; then
    key=$(cat "$BASE/atlas.key")
    key_masked="${key:0:10}...${key: -10}"
    echo -e "   ${G}✓${NC} API Key configurada: ${C}$key_masked${NC}"
    echo -e "   ${Y}→${NC} Testando conexão com Atlas..."
    source "$BASE/atlas.sh" 2>/dev/null || true
    if command -v atlas_listar_users >/dev/null 2>&1; then
        resp=$(atlas_listar_users 2>/dev/null)
        if echo "$resp" | python3 -c "import sys, json; json.loads(sys.stdin.read())" 2>/dev/null; then
            qtd=$(echo "$resp" | python3 -c "import sys, json; print(len(json.loads(sys.stdin.read())))" 2>/dev/null)
            echo -e "      ${G}✓${NC} Conexão OK (${C}$qtd${NC} usuários no Atlas)"
        else
            echo -e "      ${R}✗${NC} Resposta inválida do Atlas"
            echo -e "      ${Y}Resposta:${NC} ${resp:0:100}..."
        fi
    fi
else
    echo -e "   ${R}✗${NC} API Key não configurada!"
    echo -e "      ${Y}Execute:${NC} nano $BASE/atlas.key"
fi
echo

echo -e "${Y}[3] Status do Cron (/etc/cron.d/atlas_sync)${NC}\n"
if [ -f "$CRON_D_FILE" ] && grep -q "atlas_sync_cron.sh" "$CRON_D_FILE" 2>/dev/null; then
    echo -e "   ${G}✓${NC} Cron instalado em $CRON_D_FILE"
    echo -e "      ${C}$(cat "$CRON_D_FILE")${NC}"
    if [ -f "$SYNC_LOG" ]; then
        last_run=$(tail -1 "$SYNC_LOG")
        echo -e "   ${G}✓${NC} Última execução: ${Y}$last_run${NC}"
    else
        echo -e "   ${Y}⚠${NC} Log ainda não criado (primeira execução?)"
    fi
else
    echo -e "   ${R}✗${NC} Cron ${R}NÃO está instalado${NC} em $CRON_D_FILE"
    echo -e "      ${Y}Execute novamente:${NC} bash instalar.sh (do Módulo Atlas)"
fi
echo

echo -e "${Y}[4] Análise do Log${NC}\n"
if [ -f "$SYNC_LOG" ] && [ -s "$SYNC_LOG" ]; then
    lines=$(wc -l < "$SYNC_LOG")
    echo -e "   ${G}✓${NC} Log existe (${C}$lines${NC} linhas)"
    info_count=$(grep -c "\[INFO\]" "$SYNC_LOG" || true)
    warn_count=$(grep -c "\[WARN\]" "$SYNC_LOG" || true)
    error_count=$(grep -c "\[ERROR\]" "$SYNC_LOG" || true)
    echo -e "   📊 INFO: ${C}$info_count${NC} | WARN: ${Y}$warn_count${NC} | ERROR: ${R}$error_count${NC}\n"
    echo -e "   📝 Últimas execuções:"
    tail -5 "$SYNC_LOG" | while read -r line; do
        if echo "$line" | grep -q "\[INFO\].*bem-sucedida"; then
            echo -e "      ${G}$line${NC}"
        elif echo "$line" | grep -q "\[ERROR\]"; then
            echo -e "      ${R}$line${NC}"
        elif echo "$line" | grep -q "\[WARN\]"; then
            echo -e "      ${Y}$line${NC}"
        else
            echo -e "      $line"
        fi
    done
else
    echo -e "   ${Y}⚠${NC} Log não existe ainda (será criado na primeira execução do cron)"
fi
echo

echo -e "${Y}[5] Sincronização: Atlas vs Local${NC}\n"
if [ -f "$USERDB" ] && [ -s "$USERDB" ]; then
    local_users=$(cut -d'|' -f1 "$USERDB" | wc -l)
    echo -e "   ${G}✓${NC} Banco local: ${C}$local_users${NC} usuários"
    if command -v atlas_listar_users >/dev/null 2>&1; then
        resp=$(atlas_listar_users 2>/dev/null)
        if echo "$resp" | python3 -c "import sys, json; json.loads(sys.stdin.read())" 2>/dev/null; then
            atlas_users=$(echo "$resp" | python3 -c "import sys, json; print(len(json.loads(sys.stdin.read())))" 2>/dev/null)
            echo -e "   ${G}✓${NC} Atlas:      ${C}$atlas_users${NC} usuários"
            if [ "$local_users" -eq "$atlas_users" ]; then
                echo -e "   ${G}✓${NC} Status: ${G}SINCRONIZADO${NC}"
            else
                diff=$((atlas_users - local_users))
                if [ $diff -gt 0 ]; then
                    echo -e "   ${R}✗${NC} Status: ${R}DESSINCRONIZADO${NC} (faltam ${R}$diff${NC} localmente)"
                else
                    echo -e "   ${Y}⚠${NC} Status: usuários locais > Atlas"
                fi
            fi
        fi
    fi
else
    echo -e "   ${Y}⚠${NC} Banco local vazio ou não existe"
fi
echo

echo -e "${Y}[6] Integração com Xray${NC}\n"
if [ -f "$XRAY_CONF" ]; then
    xray_clients=$(jq '[.inbounds[].settings.clients[]? | .email] | length' "$XRAY_CONF" 2>/dev/null || echo "0")
    echo -e "   ${G}✓${NC} Xray config OK: ${C}$xray_clients${NC} clientes configurados"
    if systemctl is-active --quiet xray 2>/dev/null; then
        echo -e "   ${G}✓${NC} Serviço Xray: ${G}ATIVO${NC}"
    else
        echo -e "   ${R}✗${NC} Serviço Xray: ${R}INATIVO${NC}"
    fi
else
    echo -e "   ${R}✗${NC} Xray config não encontrada"
fi
echo

echo -e "${Y}[7] Recomendações${NC}\n"
should_warn=0
if [ ! -f "$BASE/atlas.key" ] || [ ! -s "$BASE/atlas.key" ]; then
    echo -e "   ${R}1.${NC} API Key não configurada → ${Y}nano $BASE/atlas.key${NC}"
    should_warn=1
fi
if [ ! -f "$CRON_D_FILE" ]; then
    echo -e "   ${R}2.${NC} Cron não instalado → rode o instalador do módulo novamente"
    should_warn=1
fi
if [ -f "$SYNC_LOG" ]; then
    log_age=$(( $(date +%s) - $(stat -c %Y "$SYNC_LOG" 2>/dev/null || echo 0) ))
    if [ $log_age -gt 3600 ]; then
        echo -e "   ${Y}3.${NC} Log sem atualização há mais de 1h → verifique se o cron está rodando"
        should_warn=1
    fi
fi
if [ $should_warn -eq 0 ]; then
    echo -e "   ${G}✓ Nenhum problema detectado!${NC}"
fi
echo

echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${C}💡 Comandos úteis:${NC}"
echo -e "   Monitorar log:        ${Y}tail -f $SYNC_LOG${NC}"
echo -e "   Forçar sincronização: ${Y}$CRON_SCRIPT${NC}"
echo -e "   Ver cron:             ${Y}cat $CRON_D_FILE${NC}"
echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
DIAG_SCRIPT_EOF

chmod 755 "$DIAG_SCRIPT"
echo -e "${G}✓${NC} $DIAG_SCRIPT instalado\n"

# ────────────────────────────────────────────────────────────
# 4. GARANTE O CRON.D (não duplica, só repara se estiver ausente)
# ────────────────────────────────────────────────────────────
echo -e "${Y}[3/4] Verificando /etc/cron.d/atlas_sync...${NC}"

if [ -f "$CRON_D_FILE" ] && grep -q "atlas_sync_cron.sh" "$CRON_D_FILE"; then
    echo -e "${G}✓${NC} Cron já estava instalado (mesmo mecanismo do painel), nada a fazer\n"
else
    echo "* * * * * root flock -n /tmp/atlas_sync.lock $CRON_SCRIPT" > "$CRON_D_FILE"
    chmod 644 "$CRON_D_FILE"
    echo -e "${G}✓${NC} Cron recriado em $CRON_D_FILE (rodando a cada minuto)\n"
fi

touch "$SYNC_LOG"
chmod 640 "$SYNC_LOG"

# ────────────────────────────────────────────────────────────
# 5. TESTE INICIAL
# ────────────────────────────────────────────────────────────
echo -e "${Y}[4/4] Executando teste inicial de sincronização...${NC}\n"

if flock -n /tmp/atlas_sync.lock "$CRON_SCRIPT"; then
    echo -e "${G}✓ Teste executado. Veja o resultado no log abaixo:${NC}"
else
    echo -e "${Y}⚠ Teste retornou com aviso/erro. Veja o log abaixo para detalhes:${NC}"
fi
echo
tail -5 "$SYNC_LOG" 2>/dev/null
echo

# ────────────────────────────────────────────────────────────
# RESUMO
# ────────────────────────────────────────────────────────────
echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${G}✅ Módulo Atlas instalado/atualizado com sucesso!${NC}"
echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
echo -e "${C}📝 Arquivos:${NC}"
echo -e "   Script sync:   ${Y}$CRON_SCRIPT${NC}"
echo -e "   Diagnóstico:   ${Y}$DIAG_SCRIPT${NC}"
echo -e "   Log:           ${Y}$SYNC_LOG${NC}"
echo -e "   Cron:          ${Y}$CRON_D_FILE${NC} (a cada minuto)"
echo
echo -e "${C}🔍 Próximos passos:${NC}"
echo -e "   Verificar status:  ${Y}bash $DIAG_SCRIPT${NC}"
echo -e "   Monitorar em real: ${Y}tail -f $SYNC_LOG${NC}"
echo -e "   Forçar sync agora: ${Y}$CRON_SCRIPT${NC}"
echo
