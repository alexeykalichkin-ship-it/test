#!/bin/bash
# awg-routing.sh - каскадный сплит-роутинг на сервере AWG0 (вход).
# RU-трафик клиентов идёт напрямую через WAN, остальное - через туннель awg1 на сервер-выход AWG1.
# Скрипт идемпотентен: его можно запускать повторно (в т.ч. по расписанию для обновления RU-сетей).
set -euo pipefail

# ===== параметры (поправь под свою установку) =====
CLIENT_SUBNET="172.16.17.0/24"          # подсеть клиентов AWG0 (см. Address в /etc/amnezia/amneziawg/awg0.conf)
AWG1_IF="awg1"                           # имя интерфейса туннеля к серверу-выходу
AWG1_ENDPOINT="CHANGE_ME"               # внешний IP сервера AWG1 (Endpoint из awg1.conf, без порта)
TABLE_ID=100                            # номер таблицы маршрутизации для трафика "на выход"
FWMARK="0x1"                            # метка для трафика, уходящего через awg1
RULE_PRIO=10000                        # приоритет правила ip rule (нестандартный, чтобы не конфликтовать)
RU_ZONE_URL="https://www.ipdeny.com/ipblocks/data/aggregated/ru-aggregated.zone"
RU_ZONE_FALLBACK_URL="https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.37.0/cascade/ru.zone"
AWG_DIR="/root/awg"
EXTRA_RU_NETS=""                        # свои адреса/сети, которые вести через РФ (через пробел),
                                        # напр. "203.0.113.7 198.51.100.0/24". Нужно для .ru-сайтов
                                        # за зарубежным CDN: по адресу они выглядят как заграница
# ==================================================

RU_ZONE="$AWG_DIR/ru.zone"
mkdir -p "$AWG_DIR"

# Блокировка: два одновременных запуска мешают друг другу. Оба наперегонки подменяют один и тот же
# набор ru через ru_tmp, и проигравший падает с "The set with the given name does not exist"; вдобавок
# оба пишут в общий "$RU_ZONE.tmp", а trap первого удаляет файл второго. Типичный случай - юнит
# awg-routing стартует после перезагрузки, а вы тут же запускаете скрипт руками (issue #212).
# Здесь второй экземпляр ЖДЁТ, а не ломается.
exec 9>"$AWG_DIR/awg-routing.lock"
flock -w 300 9 || { echo "ERROR: другой экземпляр awg-routing.sh не завершился за 5 минут - прерываюсь" >&2; exit 1; }

trap 'rm -f "$RU_ZONE.tmp"' EXIT         # не оставлять временный файл списка при выходе/прерывании

[ "$AWG1_ENDPOINT" != "CHANGE_ME" ] || { echo "ERROR: впиши AWG1_ENDPOINT (внешний IP сервера AWG1)" >&2; exit 1; }

# Определяем выход к AWG1 по самому маршруту до endpoint (надёжнее парсинга default - работает и на
# on-link/point-to-point/multi-homed). На первом запуске это путь через WAN (туннель ещё не вмешивается).
EP_ROUTE="$(ip -4 route get "$AWG1_ENDPOINT" 2>/dev/null | head -1)"
WAN_IF="$(printf '%s' "$EP_ROUTE" | grep -oP '\bdev \K\S+' || true)"
WAN_GW="$(printf '%s' "$EP_ROUTE" | grep -oP '\bvia \K\S+' || true)"
{ [ -n "$WAN_IF" ] && [ "$WAN_IF" != "$AWG1_IF" ]; } \
    || { echo "ERROR: не удалось определить WAN-интерфейс к AWG1 (или он указывает в туннель)" >&2; exit 1; }

# Предупреждение про IPv6: схема только для IPv4, при включённом IPv6 он пойдёт мимо деления.
if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)" = "0" ] \
   && ip -6 route show default 2>/dev/null | grep -q .; then
    echo "WARN: на сервере включён IPv6 - IPv6-трафик пойдёт мимо каскада. Отключи IPv6 (установщик: --disallow-ipv6)." >&2
fi

# 1) Обновить список RU-сетей. Источники по порядку: ipdeny (актуальный) -> снимок в репозитории
#    (если ipdeny недоступен) -> уже лежащий локальный список. Рабочий файл заменяем только при
#    успешной непустой загрузке, поэтому сорванная закачка не обнулит прежний список.
fetch_ru_zone() {                                # $1 = URL; качает и ПРОВЕРЯЕТ содержимое, 0 при успехе
    # Таймауты обязательны: скрипт запускается юнитом при загрузке, а у юнита ограничено время.
    # Без них зависшая закачка съела бы весь бюджет, и systemd убил бы юнит до применения правил.
    # --retry-max-time ограничивает СУММУ попыток, иначе три повтора по 30 с дают 93 с на один URL.
    curl -fsS --retry 2 --retry-max-time 45 --connect-timeout 10 --max-time 30 \
        -o "$RU_ZONE.tmp" "$1" || return 1
    # 🔴 Проверять надо СОДЕРЖИМОЕ, а не только непустоту. curl -f отсекает только код >= 400,
    # поэтому заглушка провайдера, страница DPI или капча, отданные с кодом 200, прошли бы как
    # валидный список, затёрли рабочий файл и сломали деление до ручного вмешательства.
    local valid total
    valid=$(grep -cE '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' "$RU_ZONE.tmp" || true)
    # Считаем НЕПУСТЫЕ строки, а не все: иначе отсутствие завершающего перевода строки или
    # пустая строка в конце отвергали бы годный список, хотя загрузчик ниже их спокойно терпит.
    total=$(grep -c '[^[:space:]]' "$RU_ZONE.tmp" || true)
    if [ "$valid" -lt 1000 ] || [ "$valid" -ne "$total" ]; then
        echo "WARN: $1 отдал не список RU-сетей (валидных строк $valid из $total) - не беру" >&2
        return 1
    fi
}
if fetch_ru_zone "$RU_ZONE_URL"; then
    mv -f "$RU_ZONE.tmp" "$RU_ZONE"
elif fetch_ru_zone "$RU_ZONE_FALLBACK_URL"; then
    mv -f "$RU_ZONE.tmp" "$RU_ZONE"
    echo "WARN: ipdeny недоступен - взял снимок RU-сетей из репозитория (может немного отставать от актуального)" >&2
else
    echo "WARN: не удалось скачать список ни с ipdeny, ни из репозитория - использую прежний локальный" >&2
fi
# Без списка не продолжаем: пустой ipset отправит ВЕСЬ трафик за границу (деление молча сломается).
[ -s "$RU_ZONE" ] || { echo "ERROR: список RU-сетей пуст и нигде не найден - прерываюсь, чтобы не сломать деление" >&2; exit 1; }

# 2) Загрузить RU-сети в ipset через временный сет (атомарная замена, без "пустого окна").
ipset create ru hash:net -exist
ipset create ru_tmp hash:net -exist
ipset flush ru_tmp
while read -r net; do
    [ -n "$net" ] && ipset add ru_tmp "$net" -exist
done < "$RU_ZONE"
# Свои адреса добавляем в тот же временный набор ДО подмены - тогда они переживают запуск скрипта.
# Дописывать в готовый ru бесполезно: следующий запуск соберёт набор заново и затрёт добавленное.
# set -f отключает раскрытие шаблонов: без него звёздочка в переменной превратилась бы в имена файлов.
# Ошибочная запись НЕ роняет скрипт: при запуске из юнита это оставило бы сервер без деления вовсе,
# а так теряется только само исключение, и об этом сказано в предупреждении.
extra_total=0; extra_bad=0
set -f
for net in $EXTRA_RU_NETS; do
    extra_total=$((extra_total + 1))
    ipset add ru_tmp "$net" -exist || {
        echo "WARN: EXTRA_RU_NETS: не добавил '$net' - ожидается адрес или сеть в формате CIDR" >&2
        extra_bad=$((extra_bad + 1))
    }
done
set +f
ipset swap ru_tmp ru
ipset destroy ru_tmp

# 3) Таблица + правило: помеченный трафик уходит на выход через awg1 (по номеру таблицы, rt_tables не нужен).
ip route replace default dev "$AWG1_IF" table "$TABLE_ID"
ip rule del fwmark "$FWMARK" table "$TABLE_ID" 2>/dev/null || true
ip rule add fwmark "$FWMARK" table "$TABLE_ID" priority "$RULE_PRIO"

# 4) Маршрут к самому AWG1 держим вне туннеля (иначе пакеты к нему закольцуются в awg1). replace = идемпотентно.
if [ -n "$WAN_GW" ]; then
    # На VPS со шлюзом вне подсети сервера (напр. Hetzner, интерфейс /32) обычный replace падает
    # с "Nexthop has invalid gateway" - тогда повторяем с onlink (шлюз доступен прямо на интерфейсе).
    ip route replace "$AWG1_ENDPOINT" via "$WAN_GW" dev "$WAN_IF" 2>/dev/null \
        || ip route replace "$AWG1_ENDPOINT" via "$WAN_GW" dev "$WAN_IF" onlink
else
    ip route replace "$AWG1_ENDPOINT" dev "$WAN_IF"
fi

# Пересылку (FORWARD) и NAT прямого RU-трафика (-o WAN) уже настроил установщик в awg0.conf,
# обратный трафик пропускает UFW по RELATED,ESTABLISHED. Здесь добавляем только маркировку и NAT на awg1.

# 5) Маркировка трафика клиентской подсети, входящего через awg0: RU-сети напрямую (RETURN), остальное метим.
#    -s CLIENT_SUBNET - чтобы не задеть другой трафик, если позже добавишь ещё подсеть/пир.
#    RETURN должен стоять перед MARK; -I ... 1 держит его первым, -C делает шаг идемпотентным.
iptables -t mangle -C PREROUTING -i awg0 -s "$CLIENT_SUBNET" -m set --match-set ru dst -j RETURN 2>/dev/null \
    || iptables -t mangle -I PREROUTING 1 -i awg0 -s "$CLIENT_SUBNET" -m set --match-set ru dst -j RETURN
iptables -t mangle -C PREROUTING -i awg0 -s "$CLIENT_SUBNET" -j MARK --set-mark "$FWMARK" 2>/dev/null \
    || iptables -t mangle -A PREROUTING -i awg0 -s "$CLIENT_SUBNET" -j MARK --set-mark "$FWMARK"

# 6) NAT для трафика клиентов, уходящего на выход через awg1 (для прямого RU NAT -o WAN уже есть от установщика).
iptables -t nat -C POSTROUTING -s "$CLIENT_SUBNET" -o "$AWG1_IF" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s "$CLIENT_SUBNET" -o "$AWG1_IF" -j MASQUERADE

# Финальная строка не должна лгать: если часть своих адресов не добавилась, они пойдут
# в дальнее плечо, и молчаливое "OK" увело бы разбор не туда.
if [ "$extra_bad" -gt 0 ]; then
    echo "OK С ОГОВОРКОЙ: каскад применён, но из EXTRA_RU_NETS не добавлено $extra_bad из $extra_total - эти адреса пойдут через заграничное плечо" >&2
else
    echo "OK: каскадный роутинг применён (WAN=$WAN_IF, gw=${WAN_GW:-on-link}, выход=$AWG1_IF, table=$TABLE_ID)"
fi
