#!/usr/bin/env lua

############################################################################
#                                                                          #
#                        Mikrotik MultiWAN PBX Script                      #
#                                Version 1.0                               #
#                                                                          #
############################################################################
#                                                                          #
#  Вне зависимости от количества шлюзов, существует один основной          #
#  канал, все остальные являются резервными. При падении основного канала  #
#  осуществляется поиск первого рабочего и переход на него. Переход на     #
#  новый канал выполняется путем удаления текущего маршута по-умолчанию    #
#  и добавления нового с указанием адреса шлюза резервного канала.         #
#  Перед переключением выжидается пауза для сброса сессии голосового       #
#  шлюза по таймауту, а также удаление всех соединений с голосовым шлюзом  #
#  в таблице conntrack.                                                    #
#                                                                          #
############################################################################


##############################################
## Инициализация
##############################################

# Массив из адресов шлюзов каждого  из каналов
# В начале массива следует расположить адрес
# более стабильно работающего канала
:local gwList [:toarray "192.168.66.1, 192.168.77.1"]
# Продолжительность паузы между переключениями
:local connDelay 200s
# Продолжительность паузы перед повторной проверкой связи
:local inetDelay 5s
# Массив из внешних адресов
# Внешние адреса должны располагаться в том же порядке,
# что и адреса шлюзов
:local realIpList [:toarray "172.10.32.144, 173.12.145.222"]
# Массив из номеров портов, подлежащих пробросу
:global portsList [:toarray "80, 1050, 2222, 5555"]
# Адрес, используемый для проверки связи
:global pingTarget 208.67.222.222
# Количество пингов при проверке
:global pingCount 5
# Адрес голосового шлюза
:global ipPbx "192.168.88.2"
# Комментарий для маршрута по-умолчанию
:global routeComment "ROUTE"
# Комментарий для правила блокировки
:global pbxComment "BLOCK"
# Комментарий для правил проброса портов
:global dstnatComment "DSTNAT"


##############################################
## Функции
##############################################

# Функция проверят, есть ли связь
# Формат вызова :put [$IsINetUp]
:local IsINetUp do={
    :global pingCount
    :global pingTarget
    :if ([ping $pingTarget count=$pingCount]=0) do={
        :return false
    } else={
        :return true
    }
}

# Функция возвращает шлюз маршрута по-умолчанию
# Формат вызова :put [$GetDefaultRoute]
:local GetDefaultRoute do={
    :global routeComment
    :return [/ip route get [find comment=$routeComment] gateway]
}

# Функция добавляет маршрут по-умолчанию с указанным шлюзом
# Формат вызова $AddDefaultRoute "192.168.66.1"
:local AddDefaultRoute do={
    :global routeComment
    /ip route add dst-address="0.0.0.0/0" gateway=$1 comment=$routeComment
}

# Функция удаляет маршрут по-умолчанию
# Формат вызова $RemDefaultRoute
:local RemDefaultRoute do={
    :global routeComment
    /ip route remove [find comment=$routeComment]
}

# Функция удаляет все соединения голосового шлюза
# Формат вызова $RemPbxConns
:local RemPbxConns do={
    :global ipPbx
    /ip firewall connection remove [find src-address=$ipPbx]
}

# Функция блокирует соединения голосового шлюза
# Формат вызова $BlockPbxConns
:local BlockPbxConns do={
    :global ipPbx
    :global pbxComment
    /ip firewall filter add chain=forward src-address=$ipPbx action=drop comment=$pbxComment
}

# Функция разблокирует соединения голосового шлюза
# Формат вызова $UnBlockPbxConns
:local UnBlockPbxConns do={
    :global pbxComment
    /ip firewall filter remove [find comment=$pbxComment]
}

# Функция добавляет правило проброса портов
# Формат вызова $AddDstNatRules "172.10.32.144"
:local AddDstNatRules do={
    :global dstnatComment
    :global ipPbx
    :global portsList
    foreach i in=$portsList do={
        /ip firewall nat add chain=dstnat protocol=tcp action=dst-nat dst-address=$1 dst-port=[:tonum $i] to-addresses=$ipPbx to-ports=[:tonum $i] comment=$dstnatComment
        /ip firewall nat add chain=dstnat protocol=udp action=dst-nat dst-address=$1 dst-port=[:tonum $i] to-addresses=$ipPbx to-ports=[:tonum $i] comment=$dstnatComment
    }
}

# Функция удаляет правило проброса портов
# Формат вызова $RemDstNatRules
:local RemDstNatRules do={
    :global dstnatComment
    /ip firewall nat remove [find comment=$dstnatComment]
}

# Функция проверяет наличие нат правил
# Формат вызова :put [$NatRulesExist]
:local NatRulesExist do={
    :global dstnatComment
    :local natRulesCount [:len [/ip firewall nat find comment=$dstnatComment]]
    if ($natRulesCount>0) do={
        :return true
    } else={
        :return false
    }
}


##############################################
## Основной код
##############################################

# Получив адрес шлюза мы поймем какой
# из каналов в данный момент активен
:local currentGW
:do {
    :set currentGW [$GetDefaultRoute]
} on-error={ :set currentGW [:tostr [:pick $gwList 0]] }
# Максимальное количество итераций цикла
# должно быть равно количеству шлюзов
:local loopCount [:len $gwList]
# Счеткик цикла
:local counter 0
# Проверку имеет смысл делать только, если
# на активном канале нет связи
:if ([$IsINetUp]=false) do={
    :while ($counter<$loopCount) do={
        # Получаем адрес шлюза из массива
        :local gwAddress [:tostr [:pick $gwList $counter]]
        :local realIP [:tostr [:pick $realIpList $counter]]
        # Проверять будем только шлюз,
        # отличный от активного
        if ($gwAddress!=$currentGW) do={
            # Если соединение голосового шлюза активно и
            # при этом осуществляется попытка соединения
            # с другого адреса, учетная запись отправляется
            # в бан на 40 минут. Чтобы избежать этого, мы
            # блокируем соединение на файрволе, а позже 
            # выставляем паузу в 3 минуты для предварительного
            # отключения соединения по таймауту
            $BlockPbxConns
            $RemPbxConns
            $RemDstNatRules
            $RemDefaultRoute
            $AddDefaultRoute $gwAddress
            # Канал может заработать не мгновенно,
            # поэтому стоит выдержать небольшую
            # паузу перед его проверкой
            :delay $inetDelay
            # Генерировать паузу стоит лишь в случае
            # наличия связи на проверяемом канале
            :if ([$IsINetUp]=true) do={
                :delay $connDelay
                # Работающий резервный канал найден,
                # поэтому нет смысла перебирать остальные
                :set counter $loopCount
            }
            $UnBlockPbxConns
            $AddDstNatRules $realIP
        }
        # Нумерация начинается с 0
        :set counter ($counter + 1)
    }
} else={
    # На случай, если правила нат отсутствуют
    # их необходимо добавить
    :if ([$NatRulesExist]=false) do={
        # Добавлять будем правила для адреса,
        # соответствующего текущему каналу
        :local pos [:find $gwList $currentGW]
        $AddDstNatRules [:tostr [:pick $realIpList $pos]]
    }
}
