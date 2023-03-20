## Описание 
В статье описан способ настройки конфигурации PgPOOL-II в качестве балансировщика "читающей" (SELECT) нагрузки PostgreSQL в режиме "Master-Master" используя принципы [IP Anycast](https://en.wikipedia.org/wiki/Anycast). 

### Ограничения
* Все настройки, файлы конфигураций и рекомендации приведены для дистрибутива Debian Linux, и именно для пакетов входящих в стандартную поставку Debian 11. В случае если Вы работаете с другим Linux или пакетами, то Вам будет необходимо внести изменения самостоятельно.
* Мы будем работать с PostgreSQL 13 и PgPOOL-II 4.1, проблем с другими версиями скорее всего не будет, но это не точно.
* У Вас уже должен быть настроенный кластер потоковой репликации для PostgreSQL, или Вы знаете как его сделать, в рамках статьи мы немного затронем эту тему, но абсолютно ее не раскроем. Если Вам нужны более глубокие знания, обязательно советую попасть на курс [DBA3](https://postgrespro.ru/education/courses/DBA3).
* Вам потребуются минимальные знания сетевого стэка Linux и протокола динамической маршрутизации в частности OSPF, но можно использовать любой другой протокол.


## С чего все началось
Много лет я работал в телекоме, и так получилось, что за все время с базой PostgreSQL так и не пришлось всерьез поработать. Но совсем недавно, попав в мир Enterprice,  мне пришлось познакомится с PostgreSQL, и чуть ли не сразу погрузиться в решение проблемы распределения нагрузки между разными экземплярами. Сразу на глаза попались разные решения, в том числе и [PgPOOL-II](https://pgpool.net), [PgCat](https://github.com/levkk/pgcat), [Percona](https://www.percona.com/ha-for-postgresql), но мне пришлось значительно удивится тому, что во всех предлагаемых конфигурациях используется один виртуальный адрес, который "перебрасывается" между нодами с помощью скриптов либо используя keepalived, что на мой взгляд не очень то современно.

### Недостатки готовых решений
  * Независимо от количества нод для балансировки, весь трафик будет при любом сценарии идти только через одну ноду, на которой в данный момент будет находится виртуальный адрес. Все остальные ноды будут простаивать в ожидании назначения IP адреса, эти ресурсы у нас будут постоянно выделены но не использоваться.
  * Если у нас несколько датаЦентров (например: Санкт-петербург, Москва, Екатеринбург), и по ноде балансировки расположено в каждом из них, то в этом случае трафик может "бегать" между городами впустую занимая дорогостоящую полосу пропускания, в добавок к этому увеличивая время отклика самого приложения.
  * Время переключения ("переноса") адреса в случае сценария выхода из строя одной ноды, заметное для приложения и составляет до 2-10 секунд (это зависит от конкретной сети ).

## Реализация конфигурации Pg-Pool-II "Master-Master":

### Основа
Во всех современных сетях, нередко применяют технологию IP Anycast для распределения нагрузки, еще с прошлого века самым известным сервисом, который использовал anycast была служба DNS. Сегодня в современных сетях в общих случаях применяя anycast мы можем организовать балансировку "без самого балансировщика", используя только протоколы динамической маршрутизации. Одним из таких примеров может быть  сервис nginx (работающий как прокси или веб сервер), который будет принимать запросы на anycast адрес и обрабатывать их. Я оставлю [файл конфигурации](https://github.com/IgorAlov/pg_pool2_ng/blob/master/configs/nginx_ping.conf) для nginx, на случай если будет необходимо  отладить схему с балансировкой. С точки зрения IP Anycast, не должно возникнуть каких либо проблем для работы механизмов блансировки, однако транспортный протокол по которому работает PostgreSQL - TCP, и при балансировке TCP есть определенные тонкости, о которых я расскажу чуть позже. 

### Начальная настройка (общий случай)
Для начала определимся с конфигурацией нашей сети, и адресным пространством, которое мы будем использовать для нашего тестового стенда кластера базы данных.
| Host | IP base | IP routed | IP loopback | IP Anycast | Description |
|--:   |--:      |--:        |--:          |--:        |--:         |
| FRR | 198.18.0.90/24 | 198.18.1.90/24 | 198.18.2.90/32 | NA | Routing Daemon |
| PgSQL1 | 198.18.0.91/24 | 198.18.1.91/24 | 198.18.2.91/32 | 198.18.2.0/32 | PostgreSQL Master |
| PgSQL2 | 198.18.0.92/24 | 198.18.1.92/24 | 198.18.2.92/32 | NA | PostgreSQL Replica |
| PgSQL3 | 198.18.0.93/24 | 198.18.1.93/24 | 198.18.2.93/32 | NA | PostgreSQL Replica |
| PgBAL1 | 198.18.0.94/24 | 198.18.1.94/24 | 198.18.2.94/32 | 198.18.2.0/32 | PgPOOL-II Instance 1 |
| PgBAL2 | 198.18.0.95/24 | 198.18.1.95/24 | 198.18.2.95/32 | 198.18.2.0/32 | PgPOOL-II Instance 2 |
| PgBAL3 | 198.18.0.96/24 | 198.18.1.96/24 | 198.18.2.96/32 | 198.18.2.0/32 | PgPOOL-II Instance 3 |

### Настройка серверов (виртуальных машин) для стенда
Для нашего тестового стенда мы создадим 8 виртуальных машин на базе Debian 11, при этом исключительно для упрощения создания тестовой среды предлагаю сделать дополнительному сетевому интерфейсу, в ходящих в общую сеть, для всех виртуальных машин, которые будут принимать участие в динамической маршрутизации (PgSQL1, PgBAL1, PgBAL2, PgBAL3 и FRR). Например, если собираете стенд в VirtualBox, то подключите второй сетевой интерфейс к Internal Network (название Internal Network в виртуальных машинах должно совпадать). Вы так же можете выполнить конфигурацию используя шаблоны, путем копирования виртуальных машин.

### Установка и конфигурация пакетов для всех виртуальных машин
1. `apt update && apt upgrade` - (Все VM) - обнвляем все пакеты
2. `apt install ipupdown2 ` - (все VM) - обновленная служба конфигурации сети, необходима для корректного работы демона frr.
3. Добавляем в файл `/etc/hosts` наши адреса [пример](https://github.com/IgorAlov/pg_pool2_ng/blob/master/configs/hosts) для удобства обращения к виртуальным машинам по именам.
3. `apt install htop hping3 tcpdump tcpflow curl` - утилиты для удобства отладки в настройке.
4. `apt install frr` - (PgSQL1, PgBAL1, PgBAL2, PgBAL3, FRR) - демон маршрутизации.
5. `apt install postgres` -  (PgSQL1, PgSQL2, PgSQL3) - сервер базы данных PostgreSQL.
6. `apt install pgpool2` - (PgBAL1, PgBAL2, PgBAL3) - балансировщик PgPOOL-II.
6. `apt install postgres-client` - (FRR) - клиент для подключения к базе данных.

### Настройка маршрутизации
Перед тем как начать производить дальнейшую настройку маршрутизации, нам необходимо убедится что все виртуальные машины доступны по IP адресам, которые мы для них задали. проверьте доступность машин используя команду на всех серверах
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

мы должны получить ответ от всех адресов.
Так же на серверах с двумя сетевыми интерфейсам (PgSQL1, PgBAL1, PgBAL2, PgBAL3 и FRR) мы должны проверить доступность серверов командой:
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


### Проверка 







