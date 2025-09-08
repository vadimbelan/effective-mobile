# Effective Mobile Test Monitor

https://disk.yandex.ru/i/gGdzAs_N7c7c0Q

Bash-скрипт и systemd-таймер для мониторинга процесса `test` в Linux.  
Решение упаковано в Docker-образ (Ubuntu + systemd), чтобы запускать и тестировать под macOS Docker Desktop.

---

## Логика

- Раз в минуту запускается `test-monitor.sh` (через systemd timer).
- Скрипт ищет процесс `test`:
  - Берёт список PID из `/proc/*/comm`.
  - Для каждого — `starttime` (поле 22 в `/proc/<pid>/stat`).
  - Выбирает **наиболее старый** (минимальное `starttime`).
- Если процесс не найден — выходим без действий.
- Если найден:
  - При первом обнаружении — лог `started`.
  - Если `starttime` изменился — лог `restarted`.
  - Всегда выполняется HTTPS-запрос на `$MONITORING_URL` (по умолчанию `https://test.com/monitoring/test/api`).
  - Ошибка сети / таймаут / код ответа ≠ 2xx → лог `monitoring_error`.
- Логи пишутся в `/var/log/monitoring.log` в формате:

2025-09-04T12:20:21Z ERROR event=monitoring_error pid=138 starttime=950746 detail="http_status=000"

- State хранится в `/var/run/test-monitor/.last_starttime`.
- Защита от гонок — `flock` на `/var/run/test-monitor/lock`.

---

## Сборка и запуск

### Вариант 1 — напрямую
```bash
docker build -t test-monitor:latest .

docker run -d --name test-monitor \
--privileged --cgroupns=host \
-v /sys/fs/cgroup:/sys/fs/cgroup:rw \
--tmpfs /run --tmpfs /run/lock \
test-monitor:latest
```

### Вариант 2 — docker compose

```bash
docker compose up -d
```

## Внутри контейнера

```bash
# Подключиться внутрь
docker exec -it test-monitor bash

# Проверить таймер и сервис
systemctl status test-monitor.timer --no-pager
systemctl status test-simulator.service --no-pager

# Логи
tail -f /var/log/monitoring.log
journalctl -u test-monitor.service --no-pager
```

## Переопределение MONITORING_URL

URL задаётся через `/etc/default/test-monitor`:

```bash
echo 'MONITORING_URL="http://host.docker.internal:18080/"' > /etc/default/test-monitor
systemctl start test-monitor.service
```

## Эмуляция процесса test

В контейнере уже есть `test-simulator.service`:

```bash
systemctl restart test-simulator.service   # перезапустить процесс
systemctl status test-simulator.service
```

## Тесты

### 1. Базовый сценарий (успешный запрос)

```bash
docker run --rm -d --name mock200 -p 18080:80 nginx:alpine
echo 'MONITORING_URL="http://host.docker.internal:18080/"' > /etc/default/test-monitor
systemctl start test-monitor.service
tail -n 5 /var/log/monitoring.log   # ошибок быть не должно
```

### 2. Перезапуск процесса

```bash
systemctl restart test-simulator.service
systemctl start test-monitor.service
tail -n 5 /var/log/monitoring.log   # появится "restarted"
```

### 3. Ошибка мониторинга

```bash
echo 'MONITORING_URL="http://host.docker.internal:19999/health"' > /etc/default/test-monitor
systemctl start test-monitor.service
tail -n 5 /var/log/monitoring.log   # появится "monitoring_error"
```

### 4. Persistent=true

```bash
docker stop test-monitor
sleep 180   # подождать 3 минуты
docker start test-monitor
docker exec -it test-monitor bash -lc 'systemctl list-timers | grep test-monitor'
```

### 5. Конкурентность

```bash
for i in {1..5}; do /usr/local/bin/test-monitor.sh & done; wait
tail -n 20 /var/log/monitoring.log   # дублированных started/restarted быть не должно
```

## Примеры логов
2025-09-04T12:19:49Z INFO event=started pid=41 starttime=936265 detail="first_detection"

2025-09-04T12:20:06Z INFO event=restarted pid=138 starttime=950746 detail="process_starttime_changed prev=936265"

2025-09-04T12:20:21Z ERROR event=monitoring_error pid=138 starttime=950746 detail="http_status=000"

2025-09-04T12:22:10Z ERROR event=monitoring_error pid=141 starttime=951100 detail="curl_exit=28 Operation timed out"

2025-09-04T12:23:05Z ERROR event=monitoring_error pid=141 starttime=951100 detail="http_status=500"

2025-09-04T12:23:30Z ERROR event=monitoring_error pid=- starttime=- detail="script_error: cannot create /var/run/test-monitor"

## Завершение работы

```bash
docker stop test-monitor
docker rm test-monitor
docker rm -f mock200   # если запускали nginx
```
