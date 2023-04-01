## Описание 
В статье описан способ конфигурации PgPOOL-II в качестве балансировщика "читающей" (SELECT) нагрузки PostgreSQL в режиме "Master-Master" используя принципы [IP Anycast](https://en.wikipedia.org/wiki/Anycast) и [ECMP](https://en.wikipedia.org/wiki/Equal-cost_multi-path_routing). 

### Ограничения
* Все настройки, файлы конфигураций и рекомендации приведены для дистрибутива Debian Linux, и именно для пакетов входящих в стандартную поставку Debian 11. В случае если Вы работаете с другим Linux или пакетами, то Вам будет необходимо внести изменения самостоятельно.
* Мы будем работать с PostgreSQL 13 и PgPOOL-II 4.1, проблем с другими версиями скорее всего не будет, но это не точно.
* У Вас уже должен быть настроенный кластер потоковой репликации для PostgreSQL, или Вы знаете как его сделать, в рамках статьи мы немного затронем эту тему, но абсолютно ее не раскроем. Если Вам нужны более глубокие знания, обязательно советую попасть на курс [DBA3](https://postgrespro.ru/education/courses/DBA3).
* Вам потребуются минимальные знания сетевого стэка Linux и протокола динамической маршрутизации, в частности в нашем примере мы будем использовать OSPF, но можно использовать любой другой протокол, который Вам больше нравится.

### Существующие решения для балансировки в PostgreSQL
1. PgPool-II- https://pgpool.net
2. PgCAT - https://github.com/levkk/pgcat 
3. Percona - https://www.percona.com/ha-for-postgresql 
4. Коннекторы ODBC / JDBC 
5. Стандартная библиотека от PostgreSQL libpq, а у компании [PostgresPRO](https://postgrespro.ru) есть качественный [перевод](https://postgrespro.ru/docs/postgrespro/13/libpq)

Варианты 4 и 5 нам не подходят ввиду малой автоматизации из коробки, и требуют написания дополнительных обёрток, чтобы с ними работать. Другие решения нам подходят, но до конца соответствуют требованиям, которые предъявляет наша компания. 

#### Недостатки решений
  * Независимо от количества нод для балансировки, весь трафик будет при любом сценарии идти только через одну ноду, на которой в данный момент будет находится виртуальный адрес. Все остальные ноды будут простаивать в ожидании назначения IP адреса, эти ресурсы у нас будут постоянно выделены но не будут использоваться. [схема](support/drawio/ntwrk_02.drawio.svg)
   * Если у нас несколько Дата-Центров (например: Санкт-Петербург, Москва, Екатеринбург), и по одной ноде балансировки расположено в каждом из них, то в этом случае трафик может "бегать" между городами впустую, занимая дорогостоящую полосу пропускания, в добавок к этому увеличивая время отклика самого приложения. [схема](support/drawio/ntwrk_03.drawio.svg)
  * Время переключения ("переноса") адреса в случае сценария выхода из строя одной ноды, заметное для приложения и составляет до 2-10 секунд (это зависит от конкретной конфигурации сети).

### Основа
Во всех современных сетях, нередко применяют технологию IP Anycast для распределения нагрузки. С прошлого века самым известным сервисом, который использовал anycast была служба DNS. Сегодня в современных сетях в общих случаях применяя anycast и протоколы ECMP мы можем организовать балансировку "без самого балансировщика", используя только протоколы динамической маршрутизации. Одним из таких примеров может быть сервис nginx (работающий как прокси или веб сервер), который будет принимать запросы на anycast адрес и обрабатывать их. Я оставлю [файл конфигурации](configs/etc/nginx/sites-available/nginx_ping.conf) для nginx, на случай если будет необходимо  отладить схему с балансировкой трафика. С точки зрения IP Anycast и ECMP, не должно возникнуть каких либо проблем для работы механизмов балансировки, однако транспортный протокол по которому работает PostgreSQL - TCP, и при балансировке TCP есть определенные тонкости, о которых я расскажу чуть позже. 

<details> 
<summary>Схема сети с использование IP Anycast</summary>

![IP Anycast diagram](support/drawio/ntwrk_04.drawio.svg)
</details>

### Начальная настройка (общий случай)
Для начала определимся с конфигурацией нашей сети, и адресным пространством, которое мы будем использовать для нашего тестового стенда кластера базы данных.
|Host|IP base|IP routed|IP loopback|IP Anycast|Description|
|--:|--:|--:|--:|--:|--:|
|FRR | 198.18.0.90/24 |198.18.1.90/24|198.18.2.90/32|NA|Routing Daemon|
|PgSQL1|198.18.0.91/24|198.18.1.91/24|198.18.2.91/32|198.18.2.0/32|PostgreSQL Master|
|PgSQL2|198.18.0.92/24|198.18.1.92/24|198.18.2.92/32|NA|PostgreSQL Replica|
|PgSQL3|198.18.0.93/24|198.18.1.93/24|198.18.2.93/32|NA|PostgreSQL Replica|
|PgBAL1|198.18.0.94/24|198.18.1.94/24|198.18.2.94/32|198.18.2.0/32|PgPOOL-II Instance 1|
|PgBAL2|198.18.0.95/24|198.18.1.95/24|198.18.2.95/32|198.18.2.0/32|PgPOOL-II Instance 2|
|PgBAL3|198.18.0.96/24|198.18.1.96/24|198.18.2.96/32|198.18.2.0/32|PgPOOL-II Instance 3|

### Настройка серверов (виртуальных машин) для стенда
Для нашего тестового стенда мы создадим 7 виртуальных машин на базе Debian 11, при этом исключительно для упрощения создания тестовой среды предлагаю сделать по дополнительному сетевому интерфейсу, в ходящему в общую сеть, для  виртуальных машин, которые будут принимать участие в динамической маршрутизации (PgSQL1, PgBAL1, PgBAL2, PgBAL3 и FRR). Например, если собираете стенд в VirtualBox, то подключите второй сетевой интерфейс к Internal Network (название Internal Network в виртуальных машинах должно совпадать). 

### Установка и конфигурация пакетов для всех виртуальных машин
1. `apt update && apt upgrade` - (Все VM) - обновляем  все пакеты (если вдруг у нас не свежая установка).
2. `apt install ipupdown2 ` - (все VM) - обновленная служба конфигурации сети, необходима для корректной работы вместе с демоном [frr](https://frrouting.org/).
3. По желанию в файл `/etc/hosts` добавляем наши адреса [пример](configs/etc/hosts) для доступа к виртуальным машинам по именам.
4. `apt install htop hping3 tcpdump curl nginx` - утилиты для удобства отладки в настройке.
5. `apt install frr` - (PgSQL1, PgBAL1, PgBAL2, PgBAL3, FRR) - демон маршрутизации.
6. `apt install postgres` -  (PgSQL1, PgSQL2, PgSQL3) - сервер базы данных PostgreSQL.
7. `apt install pgpool2` - (PgBAL1, PgBAL2, PgBAL3) - балансировщик PgPOOL-II.
8. `apt install postgres-client` - (FRR) - клиент для подключения к базе данных.
9. Для каждого сервера задайте имя хоста в файле `/etc/hostname` в соответствии с таблицей.

### Настройка сетевых адресов

В соответствии с таблицей нам необходимо произвести настройку сетевых интерфейсов в файле `/etc/network/interfaces` на виртуальных машиных и перезапустить службу `service networking restart`.
* IP base - опорный адрес, прописываем на первую сетевую карту (скорее всего eth0);
* IP loopback - адрес loopback, который необходимо добавить на интерфейс loopback (почти всегда lo);
* IP routed - адрес сети, который необходимо прописать на второй сетевой интерфейс для серверов  (PgSQL1, PgBAL1, PgBAL2, PgBAL3, FRR) (скорее всего eth1);
* IP Anycast - адрес, который мы *временно* (на период базовой настройки) добавим на интерфейс loopback (lo) для серверов (PgSQL1, PgBAL1, PgBAL2, PgBAL3);
<details>
<summary>Пример файла конфигурации /etc/network/interfaces</summary>

```bash
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback
    address <IP loopback>
    address <IP Anycast> # если такой адрес должен быть *(временно пропишем)
   
# опорная сеть IP base
auto eth0
iface eth0 inet static
    address <IP base>
    ip-forward off  # для сервера frr параметр должен быть on
    ip6-forward off
    arp-accept on

# ospf сеть IP routed для серверов (PgSQL1, PgBAL1, PgBAL2, PgBAL3, FRR)
auto eth1
iface eth1 inet static
    address <IP routed>
    ip-forward off  # для сервера frr параметр должен быть on
    ip6-forward off
    arp-accept on

```
</details>
Перед тем как начать производить дальнейшую настройку, нам необходимо убедится что все виртуальные машины доступны по IP адресам, которые мы для них задали. проверьте доступность машин используя команду (для всех серверов)

```bash
for addr in `seq 90 1 96`; do ping -c1 -q 198.18.0.$addr; done
```

<details>
   <summary>Вывод</summary>

```bash
PING 198.18.0.90 (198.18.0.90) 56(84) bytes of data.

--- 198.18.0.90 ping statistics ---
1 packets transmitted, 1 received, 0% packet loss, time 0ms
rtt min/avg/max/mdev = 0.025/0.025/0.025/0.000 ms
PING 198.18.0.91 (198.18.0.91) 56(84) bytes of data.

--- 198.18.0.91 ping statistics ---
1 packets transmitted, 1 received, 0% packet loss, time 0ms
rtt min/avg/max/mdev = 0.109/0.109/0.109/0.000 ms
PING 198.18.0.92 (198.18.0.92) 56(84) bytes of data.

--- 198.18.0.92 ping statistics ---
1 packets transmitted, 1 received, 0% packet loss, time 0ms
rtt min/avg/max/mdev = 0.128/0.128/0.128/0.000 ms
PING 198.18.0.93 (198.18.0.93) 56(84) bytes of data.

--- 198.18.0.93 ping statistics ---
1 packets transmitted, 1 received, 0% packet loss, time 0ms
rtt min/avg/max/mdev = 0.125/0.125/0.125/0.000 ms
PING 198.18.0.94 (198.18.0.94) 56(84) bytes of data.

--- 198.18.0.94 ping statistics ---
1 packets transmitted, 1 received, 0% packet loss, time 0ms
rtt min/avg/max/mdev = 0.103/0.103/0.103/0.000 ms
PING 198.18.0.95 (198.18.0.95) 56(84) bytes of data.

--- 198.18.0.95 ping statistics ---
1 packets transmitted, 1 received, 0% packet loss, time 0ms
rtt min/avg/max/mdev = 0.117/0.117/0.117/0.000 ms
PING 198.18.0.96 (198.18.0.96) 56(84) bytes of data.

--- 198.18.0.96 ping statistics ---
1 packets transmitted, 1 received, 0% packet loss, time 0ms
rtt min/avg/max/mdev = 0.114/0.114/0.114/0.000 ms
```
</details>

Так же на серверах с двумя сетевыми интерфейсам (PgSQL1, PgBAL1, PgBAL2, PgBAL3 и FRR) мы тоже должны убедится, что все настроено:
```bash
for addr in 90 91 94 95 96; do ping -c1 -q 198.18.1.$addr; done
```

<details>
  <summary>Вывод</summary>

```bash

PING 198.18.1.90 (198.18.1.90) 56(84) bytes of data.

--- 198.18.1.90 ping statistics ---
1 packets transmitted, 1 received, 0% packet loss, time 0ms
rtt min/avg/max/mdev = 0.009/0.009/0.009/0.000 ms
PING 198.18.1.91 (198.18.1.91) 56(84) bytes of data.

--- 198.18.1.91 ping statistics ---
1 packets transmitted, 1 received, 0% packet loss, time 0ms
rtt min/avg/max/mdev = 0.142/0.142/0.142/0.000 ms
PING 198.18.1.94 (198.18.1.94) 56(84) bytes of data.

--- 198.18.1.94 ping statistics ---
1 packets transmitted, 1 received, 0% packet loss, time 0ms
rtt min/avg/max/mdev = 0.138/0.138/0.138/0.000 ms
PING 198.18.1.95 (198.18.1.95) 56(84) bytes of data.

--- 198.18.1.95 ping statistics ---
1 packets transmitted, 1 received, 0% packet loss, time 0ms
rtt min/avg/max/mdev = 0.131/0.131/0.131/0.000 ms
PING 198.18.1.96 (198.18.1.96) 56(84) bytes of data.

--- 198.18.1.96 ping statistics ---
1 packets transmitted, 1 received, 0% packet loss, time 0ms
rtt min/avg/max/mdev = 0.129/0.129/0.129/0.000 ms
```  
</details>

### Настройка маршрутизации
После того, как мы убедились в том, что все адреса доступны, можем приступить к настройке демона маршрутизации FRR, для этого отредактируем файл [/etc/frr/daemon](configs/etc/frr/daemons) и включим OSFP параметр `ospfd=yes`, так же рекомендую включить BFD (но это не обязательно), за это отвечает параметр `bfdd=yes`. Протокол BFD позволит уменьшить время переключения маршрута (быстрее определить линк, который вышел из строя).

* Выполнить перезапуск демона FRR `service frr restart`
* Запустить `sudo vtysh` и добавить команды 
```
interface eth1
 ip ospf bfd

router ospf
 ospf router-id 198.18.2.9X # указать адрес IP loopback (id должен быть разный для каждого сервера)
 redistribute connected
 passive-interface default
 no passive-interface eth1
 network 198.18.1.0/24 area 0
 network 198.18.2.0/24 area 0
```
* Незабудем сохранить конфигурацию -  `write memory`

### Проверка работы  маршрутизации
На сервере FRR мы должны увидеть маршруты к нашему виртуальному адресу со всех балансиров.
```bash
user@frr:~$ sudo ip route show 198.18.2.0
198.18.2.0 nhid 29 proto ospf metric 20 
        nexthop via 198.18.1.96 dev eth1 weight 1 # PgBAL1
        nexthop via 198.18.1.94 dev eth1 weight 1 # PgBAL2
        nexthop via 198.18.1.95 dev eth1 weight 1 # PgBAL3
```
при желании можно проверить доступность наших балансеров
```bash
user@frr:~$ sudo for ips in `ip route show 198.18.2.0 | awk '$2=="via" {print $3}'`;do ping -c3 $ips; done
```

<details>
  <summary>Вывод</summary>

```bash
PING 198.18.1.96 (198.18.1.96) 56(84) bytes of data.
64 bytes from 198.18.1.96: icmp_seq=1 ttl=64 time=0.390 ms
64 bytes from 198.18.1.96: icmp_seq=2 ttl=64 time=0.127 ms
64 bytes from 198.18.1.96: icmp_seq=3 ttl=64 time=0.124 ms

--- 198.18.1.96 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2051ms
rtt min/avg/max/mdev = 0.124/0.213/0.390/0.124 ms
PING 198.18.1.94 (198.18.1.94) 56(84) bytes of data.
64 bytes from 198.18.1.94: icmp_seq=1 ttl=64 time=0.126 ms
64 bytes from 198.18.1.94: icmp_seq=2 ttl=64 time=0.109 ms
64 bytes from 198.18.1.94: icmp_seq=3 ttl=64 time=0.143 ms

--- 198.18.1.94 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2045ms
rtt min/avg/max/mdev = 0.109/0.126/0.143/0.013 ms
PING 198.18.1.95 (198.18.1.95) 56(84) bytes of data.
64 bytes from 198.18.1.95: icmp_seq=1 ttl=64 time=0.129 ms
64 bytes from 198.18.1.95: icmp_seq=2 ttl=64 time=0.138 ms
64 bytes from 198.18.1.95: icmp_seq=3 ttl=64 time=0.121 ms

--- 198.18.1.95 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2046ms
rtt min/avg/max/mdev = 0.121/0.129/0.138/0.007 ms
```
</details>

### Несколько слов про Equal-Cost Multi-Path routing (ECMP) и Five-Tuple.
После того как мы получили несколько маршрутов к нашему виртуальному адресу, нам необходимо "согласовать правила игры", по которым пакеты будут распределятся между ними. Правила игры у каждого производителя телекоммуникационного  оборудования свои, и для того что бы по ним играть, Вам сначала необходимо понять какой трафик преобладает внутри Вашей сети. Проще говоря - понять ключи на основании которых трафик будет рассчитана hash-функция (IP SRC, PORT SRC, TOS, DSCP, IF-IN, IPv6 Flow Label etc), и сравнив с документацией производителя выбрать наиболее оптимальные ключи, обеспечивающие балансировку трафика. 

