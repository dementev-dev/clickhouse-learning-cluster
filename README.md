# Учебный кластер ClickHouse на Docker Compose

Готовый к использованию стенд для изучения кластерных возможностей ClickHouse. Проект создан для быстрого развертывания учебного кластера на любой машине с Docker.

## 🎯 Зачем это нужно

- **Быстрый старт**: поднять кластер ClickHouse на ноутбуке за 5 минут
- **Практическое изучение**: пощупать репликацию, шардинг, балансировку и отказоустойчивость
- **Безопасность**: всё в Docker Compose, сломалось — пересобрали без риска для продакшена
- **Наглядность**: прозрачная структура конфигураций для понимания принципов работы

## 🏗️ Архитектура стенда

```
                    ┌─────────────┐
                    │   HAProxy   │ 
                    │ :8124/:9001 │
                    └──────┬──────┘
                           │
          ┌────────────────┼────────────────┐
          │                │                │
   ┌──────▼──┐      ┌──────▼──┐      ┌──────▼──┐      ┌──────▼──┐
   │ click1  │      │ click2  │      │ click3  │      │ click4  │
   │ :9123   │      │ :9124   │      │ :9125   │      │ :9126   │
   │ :8002   │      │ :8003   │      │ :8004   │      │ :8005   │
   └─────────┘      └─────────┘      └─────────┘      └─────────┘
          │                │                │                │
          └────────────────┼────────────────┘                │
                           │                                  │
                    ┌──────▼──┐                               │
                    │ZooKeeper│ ◄─────────────────────────────┘
                    │  :2182  │
                    └─────────┘
```

### Состав инфраструктуры

- **4× ClickHouse Server** (версия 25.1) — основные узлы кластера
- **1× ZooKeeper** (3.9.3) — координатор для репликации
- **1× HAProxy** (3.1.7) — балансировщик нагрузки
- **3 типа кластерных конфигураций**: 1×4, 2×2, 4×1 (шарды×реплики)

## 🚀 Быстрый старт

### Предварительные требования

- Docker и Docker Compose
- Минимум 4GB RAM
- Свободные порты: 8124, 9001, 8002-8005, 9123-9126, 2182

### Запуск

```bash
# Клонируем репозиторий
git clone https://github.com/dementev-dev/clickhouse-learning-cluster
cd clickhouse-learning-cluster

# Запускаем кластер
docker compose up -d

# Проверяем статус
docker compose ps
```

### Проверка работоспособности

```bash
# Через HAProxy (рекомендуемый способ)
curl "http://default:123456@localhost:8124" -d "SELECT version()"

# Или через прямое подключение к узлу
curl "http://default:123456@localhost:9123" -d "SELECT version()"
```

## 🔧 Конфигурация кластера

### Доступные кластерные топологии

| Кластер | Шарды | Реплики | Назначение |
|---------|-------|---------|------------|
| `c1sh4rep` | 1 | 4 | Максимальная отказоустойчивость |
| `c2sh2rep` | 2 | 2 | Сбалансированное решение |
| `c4sh1rep` | 4 | 1 | Максимальная производительность |

### Порты и доступ

| Сервис | HTTP | Native | Назначение |
|--------|------|--------|------------|
| HAProxy | 8124 | 9001 | Балансировка (основной доступ) |
| click1 | 9123 | 8002 | Прямой доступ для отладки |
| click2 | 9124 | 8003 | Прямой доступ для отладки |
| click3 | 9125 | 8004 | Прямой доступ для отладки |
| click4 | 9126 | 8005 | Прямой доступ для отладки |
| ZooKeeper | - | 2182 | Координация кластера |

### Аутентификация

- **Пользователь**: `default`
- **Пароль**: `123456`

## 📊 Примеры работы с кластером

### Проверка кластерной конфигурации

```sql
-- Список доступных кластеров
SHOW CLUSTERS;

-- Детальная информация о узлах
SELECT cluster, groupArray(concat(host_name,':',toString(port))) AS hosts
FROM system.clusters 
GROUP BY cluster 
ORDER BY cluster;
```

### Создание реплицируемых таблиц

```sql
-- Создаем локальную реплицируемую таблицу на всех узлах
CREATE TABLE user_scores_local ON CLUSTER c2sh2rep (
    user_id    UInt32,
    avg_score  Float32,
    created_at DateTime
)
ENGINE = ReplicatedMergeTree(
    '/clickhouse/shard_{shard_c2sh2rep}/{database}/{table}',
    '{replica_c2sh2rep}'
)
ORDER BY (user_id);

-- Создаем Distributed таблицу для прозрачного доступа
CREATE TABLE user_scores ON CLUSTER c2sh2rep
AS user_scores_local
ENGINE = Distributed(c2sh2rep, default, user_scores_local, user_id);
```

### Тестирование с данными

```sql
-- Генерируем тестовые данные
INSERT INTO user_scores
SELECT
    number % 100000 + 1                AS user_id,
    toFloat32(rand() % 50 + rand() % 50) / 10 AS avg_score,
    now() - (number * 86400 / 1000)    AS created_at
FROM numbers(100000);

-- Проверяем распределение данных по шардам
SELECT
  _shard_num AS shard_num,
  hostName() AS host,
  count()    AS rows
FROM clusterAllReplicas('c2sh2rep', 'default', 'user_scores_local')
GROUP BY _shard_num, host
ORDER BY _shard_num, host;
```

### Мониторинг репликации

```sql
-- Состояние репликационных очередей
SELECT 
    database,
    table,
    replica_name,
    total_replicas,
    active_replicas
FROM system.replicas;

-- Лог репликации
SELECT * FROM system.replication_queue LIMIT 10;
```

## 🛠️ Структура проекта

```
clickhouse-learning-cluster/
├── docker-compose.yml          # Основная конфигурация сервисов
├── configs/
│   ├── default_user.xml        # Настройки пользователя default
│   ├── z_config.xml           # Конфигурация кластеров и ZooKeeper
│   ├── macros_ch1.xml         # Макросы для узла click1
│   ├── macros_ch2.xml         # Макросы для узла click2
│   ├── macros_ch3.xml         # Макросы для узла click3
│   ├── macros_ch4.xml         # Макросы для узла click4
│   └── haproxy/
│       └── haproxy.cfg        # Конфигурация балансировщика
├── sql/
│   └── sample_queries.sql     # Примеры запросов для тестирования
└── data/                      # Директория для пользовательских файлов
```

## 🔍 Отладка и мониторинг

### Логи сервисов

```bash
# Логи всех сервисов
docker compose logs -f

# Логи конкретного узла
docker compose logs -f click1

# Логи балансировщика
docker compose logs -f haproxy
```

### Проверка состояния

```bash
# Статус контейнеров
docker compose ps

# Использование ресурсов
docker stats
```

### Подключение к узлам напрямую

```bash
# ClickHouse client к первому узлу
docker exec -it clickhouse-learning-cluster-click1-1 clickhouse-client --user default --password 123456

# Или через внешний клиент
clickhouse-client --host localhost --port 8002 --user default --password 123456
```

## ⚠️ Важные особенности

### Уникальность путей в ZooKeeper

Каждая реплицируемая таблица должна иметь уникальный путь в ZooKeeper. Используйте макросы:
- `{shard_c2sh2rep}` — имя шарда
- `{replica_c2sh2rep}` — имя реплики
- `{database}`, `{table}` — имя базы и таблицы

### Лимиты ресурсов

Настроены оптимальные ulimits для ClickHouse:
- `nofile: 262144` — файловые дескрипторы
- `nproc: 65535` — процессы/потоки

### Сети

Все сервисы изолированы в сети `ch_learning_net` для безопасности.

## 🧪 Сценарии для экспериментов

### Тестирование отказоустойчивости
Подразумевается, что создана Distributed таблица user_scores из примеров.

```bash
# Остановим одну реплику шарда 2
docker compose stop click3

# Прроверим чтение распределенной таблицы
curl "http://default:123456@localhost:8124" -d "SELECT count() FROM user_scores"

# Остановим вторую реплику шарда 2
docker compose stop click4

# Снова проверим чтение распределенной таблицы
curl "http://default:123456@localhost:8124" -d "SELECT count() FROM user_scores"

# Восстановим узлы узлы
docker compose start click3
docker compose start click4
```

### Проверка балансировки

```bash
for i in {1..8}; do
  echo "Запрос $i:"
  curl -s "http://default:123456@localhost:8124" -d "SELECT hostName() AS current_node, now() AS request_time"
  echo ""
done
```

## 📚 Полезные ссылки

- [Официальная документация ClickHouse](https://clickhouse.com/docs/)
- [Репликация в ClickHouse](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/replication)
- [Масштабирование и кластеры](https://clickhouse.com/docs/en/architecture/cluster-deployment)
- [ClickHouse Keeper](https://clickhouse.com/docs/en/guides/sre/keeper/clickhouse-keeper)

## 📝 Лицензия

MIT License — используйте свободно в учебных и коммерческих целях.

## 🤝 Вклад в проект

Приветствуются pull requests с улучшениями:
- Дополнительные примеры запросов
- Новые конфигурации кластеров
- Улучшения документации
- Скрипты автоматизации

## 📞 Поддержка

При возникновении вопросов создавайте issue в репозитории или обращайтесь к официальной документации ClickHouse.