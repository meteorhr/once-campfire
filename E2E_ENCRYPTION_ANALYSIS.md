# Анализ E2E-шифрования в Campfire

## 1. Текущее состояние реализации

### Архитектура
Campfire — веб-чат на Ruby on Rails (Hotwire/Turbo/Stimulus). E2E-шифрование реализовано для **прямых сообщений** (Direct Messages) и основано на адаптации **X3DH + Double Ratchet** протоколов (Signal Protocol).

### Серверная часть (Rails)

| Компонент | Файл | Статус |
|-----------|-------|--------|
| Устройства пользователей | `app/models/e2e/device.rb` | Реализовано |
| Подписанные prekey | `app/models/e2e/signed_prekey.rb` | Реализовано |
| Одноразовые prekey | `app/models/e2e/one_time_prekey.rb` | Реализовано |
| Конверты сообщений | `app/models/e2e/message_envelope.rb` | Реализовано |
| Регистрация устройств | `app/controllers/users/e2e_devices_controller.rb` | Реализовано |
| Обмен prekey bundle | `app/controllers/users/e2e_prekey_bundles_controller.rb` | Реализовано |
| Key bundle комнаты | `app/controllers/rooms/e2e_key_bundles_controller.rb` | Реализовано |
| Валидация зашифрованных сообщений | `app/controllers/messages_controller.rb` | Реализовано |

### Клиентская часть (JavaScript)

| Компонент | Файл | Статус |
|-----------|-------|--------|
| E2E-клиент (X3DH + Double Ratchet) | `app/javascript/lib/e2e/client.js` | Реализовано |
| Контроллер расшифровки сообщений | `app/javascript/controllers/e2e_message_controller.js` | Реализовано |
| Интеграция с composer | `app/javascript/controllers/composer_controller.js` | Реализовано |

### Криптографические примитивы (client.js)
- **Обмен ключами**: ECDH на кривой P-256
- **KDF**: HKDF-SHA-256
- **Шифрование сообщений**: AES-256-GCM с 12-байтным IV
- **AAD (Associated Authenticated Data)**: версия, алгоритм, отправитель, получатель, счётчик
- **Хранение ключей**: localStorage браузера

### Схема базы данных
- `e2e_devices` — устройства пользователей (identity_key, device_id)
- `e2e_signed_prekeys` — подписанные prekey (ротация, active/inactive)
- `e2e_one_time_prekeys` — одноразовые prekey (consumed_at для отслеживания)
- `e2e_message_envelopes` — per-device конверты (ciphertext, header, algorithm)
- `users.e2e_public_key` — публичный ключ пользователя
- `messages.e2e_algorithm`, `messages.e2e_payload` — зашифрованные данные сообщения

---

## 2. Что уже сделано хорошо

1. **X3DH-подобный key agreement** — инициатор и ответчик создают shared secret через 3-4 DH операции (IK→SPK, EK→IK, EK→SPK, [EK→OPK])
2. **Multi-device поддержка** — сообщение шифруется для каждого устройства получателя и собственных устройств отправителя (self-sync)
3. **Ротация signed prekey** — каждые 7 дней (SIGNED_PREKEY_ROTATE_AFTER_MS)
4. **Ротация сессий** — после 200 сообщений или 3 дней (SESSION_ROTATE_AFTER_MESSAGES, SESSION_ROTATE_AFTER_MS)
5. **Удаление устаревших сессий** — через 30 дней (SESSION_EVICT_AFTER_MS)
6. **Обработка out-of-order сообщений** — skippedKeys с лимитом MAX_SKIPPED_KEYS=500
7. **Серверная валидация** — проверка алгоритма, отправителя, получателя, base64url формата, device ownership
8. **Encrypted messages не индексируются** в поиске (Message::Searchable)
9. **Encrypted messages не доставляются ботам** через webhook
10. **Encrypted messages нельзя редактировать** (editable? → false)
11. **Push-уведомления** не раскрывают содержимое зашифрованных сообщений (plain_text_body → "")
12. **AAD-binding** привязывает ciphertext к метаданным (версия, участники, счётчик)

---

## 3. Критические проблемы и недостатки

### 3.1 КРИТИЧНО: Приватные ключи хранятся в localStorage

**Файл**: `app/javascript/lib/e2e/client.js:924-947`

```javascript
#writeStorage(key, value) {
  localStorage.setItem(key, JSON.stringify(value))
}
```

Identity keys, signed prekey private keys, one-time prekey private keys и chain keys хранятся в localStorage в открытом виде. Это уязвимо к:
- XSS атакам (любой выполненный JS-код на странице получает доступ ко всем ключам)
- Расширениям браузера
- Инструментам разработчика
- Доступу к файловой системе

**Рекомендация**: Использовать IndexedDB + Web Crypto API `CryptoKey` с `extractable: false` для хранения приватных ключей. Рассмотреть шифрование хранилища через ключ, производный от пароля пользователя.

### 3.2 КРИТИЧНО: Pseudo-подпись вместо настоящей цифровой подписи

**Файл**: `app/javascript/lib/e2e/client.js:1314-1318`

```javascript
async function pseudoSign(identityPublicKeyJwk, signedPrekeyPublicKeyJwk) {
  const digestInput = textEncoder.encode(`${JSON.stringify(identityPublicKeyJwk)}:${JSON.stringify(signedPrekeyPublicKeyJwk)}`)
  const digest = await crypto.subtle.digest("SHA-256", digestInput)
  return bytesToBase64Url(new Uint8Array(digest))
}
```

Подписанный prekey подписывается через SHA-256 хеш **без использования приватного ключа**. Это значит:
- Любой может создать "подпись" для любой пары ключей
- Signed prekey не доказывает, что он создан владельцем identity key
- Позволяет серверу или MITM подменить signed prekey

**Рекомендация**: Использовать ECDSA (или Ed25519 через ECDH workaround) для подписи signed prekey приватной частью identity key.

### 3.3 КРИТИЧНО: Сервер не верифицирует подпись signed prekey

**Файл**: `app/controllers/users/e2e_devices_controller.rb:56-68`

Сервер принимает signature как строку и сохраняет без проверки. При выдаче prekey bundle (`e2e_prekey_bundles_controller.rb`) подпись отдаётся as-is. Клиент также **не верифицирует подпись** при получении bundle от сервера.

**Рекомендация**: Клиент должен проверять подпись signed prekey через identity key перед использованием.

### 3.4 КРИТИЧНО: Нет верификации identity keys (Trust on First Use отсутствует)

Нет механизма для:
- Показа "safety number" / "security code"
- Сравнения fingerprint identity ключей
- Предупреждения при смене identity key собеседника
- Проверки identity key через QR-код или out-of-band канал

**Рекомендация**: Реализовать отображение fingerprint (SHA-256 от identity key), предупреждения при смене ключа, QR-код верификацию.

### 3.5 КРИТИЧНО: Нет настоящего Double Ratchet (Diffie-Hellman Ratchet отсутствует)

**Файл**: `app/javascript/lib/e2e/client.js:612-617`

```javascript
async #advanceChain(chainKey) {
  const messageKey = await hkdf(chainKey, "once/e2e/message-key")
  const nextChainKey = await hkdf(chainKey, "once/e2e/next-chain-key")
  return { messageKey, nextChainKey }
}
```

Реализован только **symmetric ratchet** (KDF chain). Настоящий Double Ratchet Protocol требует:
1. **DH Ratchet** — обмен новыми ephemeral DH ключами при каждом "обороте" (когда направление сообщений меняется)
2. **Symmetric ratchet** — продвижение chain key для каждого сообщения

Без DH ratchet:
- Компрометация одного chain key раскрывает **все** будущие сообщения в этом направлении
- Нет **forward secrecy** на уровне отдельных сообщений
- Нет **post-compromise security** (break-in recovery)

**Рекомендация**: Реализовать полный Double Ratchet с DH ratchet step при каждой смене направления сообщений.

### 3.6 ВЫСОКИЙ: Утечка метаданных зашифрованных сообщений

Сервер видит:
- Кто кому отправляет сообщения (`from`, `to` в payload)
- Время отправки/получения (created_at)
- Размер ciphertext (длина сообщения)
- Device IDs отправителя и получателя
- Счётчик сообщений (`c`)
- X3DH headers (identity keys, ephemeral keys)

Эти метаданные хранятся в `e2e_message_envelopes` и `messages` в открытом виде.

### 3.7 ВЫСОКИЙ: Отсутствие шифрования файловых вложений

**Файл**: `app/controllers/messages_controller.rb:99`

```ruby
raise InvalidE2ePayload, "Attachment uploads cannot be sent as encrypted messages"
```

Файлы (изображения, документы) передаются в открытом виде. В Campfire активно используются вложения, что создаёт значительный пробел в покрытии.

**Рекомендация**: Реализовать шифрование файлов на клиенте перед загрузкой (encrypt blob → upload encrypted blob → store encrypted metadata).

### 3.8 ВЫСОКИЙ: Нет очистки ключевого материала из памяти

JavaScript-объекты с приватными ключами и chain keys остаются в памяти до GC. Нет явного обнуления `Uint8Array` с ключевым материалом после использования.

**Рекомендация**: Обнулять `Uint8Array` после использования (`array.fill(0)`). Использовать `CryptoKey` с `extractable: false` где возможно.

### 3.9 СРЕДНИЙ: Нет уведомления о новых/неизвестных устройствах

Когда у собеседника появляется новое устройство, сообщение автоматически шифруется для него без уведомления отправителя. Это позволяет потенциальному атакующему добавить устройство и получать сообщения.

**Рекомендация**: Показывать уведомление "User X added a new device" и позволять пользователю принять/отклонить.

### 3.10 СРЕДНИЙ: Отсутствие защиты prekey bundle endpoint от enumeration

**Файл**: `app/controllers/users/e2e_prekey_bundles_controller.rb`

Prekey bundle доступен любому аутентифицированному пользователю, который находится в общем direct room. Нет rate limiting на этот endpoint.

**Рекомендация**: Добавить rate limiting и логирование запросов prekey bundle.

### 3.11 СРЕДНИЙ: Нет отзыва скомпрометированных сессий

Если пользователь подозревает компрометацию ключей, нет механизма для:
- Принудительного сброса всех E2E сессий
- Отзыва identity key
- Уведомления собеседников о смене ключей

**Рекомендация**: Добавить UI для "Reset E2E Encryption" с перегенерацией identity key и уведомлением контактов.

### 3.12 СРЕДНИЙ: E2E шифрование не покрывает групповые чаты

E2E включено только для Direct Messages (`room.direct?`). Open и Closed rooms не поддерживаются.

**Рекомендация**: Рассмотреть Sender Keys protocol (как в Signal Groups) или MLS (Message Layer Security) для групповых чатов.

### 3.13 НИЗКИЙ: ZERO_SALT в HKDF

**Файл**: `app/javascript/lib/e2e/client.js:12`

```javascript
const ZERO_SALT = new Uint8Array(32)
```

HKDF использует нулевой salt по умолчанию. Хотя HKDF с нулевым salt технически безопасен (RFC 5869), использование уникального salt улучшает разделение доменов.

### 3.14 НИЗКИЙ: randomIntegerId() может генерировать коллизии

**Файл**: `app/javascript/lib/e2e/client.js:1087-1089`

```javascript
function randomIntegerId() {
  return Math.floor(Date.now() % 1_000_000_000 + Math.random() * 10_000)
}
```

Использует `Math.random()` (не CSPRNG) для генерации key IDs. Хотя key IDs не являются секретом, коллизии могут привести к перезаписи prekeys.

**Рекомендация**: Использовать `crypto.getRandomValues()`.

---

## 4. Тестовое покрытие

### Что протестировано
- Регистрация и обновление устройств (`e2e_devices_controller_test.rb`)
- Получение prekey bundle multi-device (`e2e_prekey_bundles_controller_test.rb`)
- Потребление one-time prekeys
- Key bundle комнаты (`e2e_key_bundles_controller_test.rb`)
- Создание зашифрованных сообщений (single/multi-device)
- Валидация payload (unknown devices, missing peer recipient)
- Запрет E2E в не-direct комнатах
- Запрет редактирования зашифрованных сообщений
- Запрет поиска зашифрованных сообщений

### Что НЕ протестировано
- Клиентская криптография (encrypt/decrypt)
- X3DH key agreement (initiator/responder)
- Chain key advancement
- Session rotation
- Out-of-order message handling
- Stale session pruning
- Signed prekey rotation
- Multi-device decryption (own messages)
- Edge cases: localStorage overflow, corrupt state, partial failures

---

## 5. План улучшений

### Фаза 1: Критические исправления безопасности (приоритет: СРОЧНО)

#### 1.1 Настоящая цифровая подпись Signed Prekey
- Заменить `pseudoSign()` на ECDSA подпись
- Клиент подписывает signed prekey приватной частью identity key
- Клиент получателя верифицирует подпись перед использованием prekey
- **Файлы**: `app/javascript/lib/e2e/client.js` (функция `pseudoSign`, `#createInitiatorSession`, `#bootstrapResponderSession`, `#refreshDeviceOnServer`)

#### 1.2 Безопасное хранение ключей
- Перевести хранение на IndexedDB + `CryptoKey` non-extractable
- Шифровать экспортируемые ключи через ключ, производный от credentials
- Добавить "E2E passphrase" как опцию для дополнительной защиты
- **Файлы**: `app/javascript/lib/e2e/client.js` (storage layer: `#readStorage`, `#writeStorage`, `#loadOrCreateIdentity`, `#loadOrCreateDeviceState`)

#### 1.3 Полный Double Ratchet
- Добавить DH Ratchet step при смене направления сообщений
- Обмен ephemeral DH ключами в header каждого сообщения
- Separate root chain, sending chain, receiving chain
- **Файлы**: `app/javascript/lib/e2e/client.js` (модель сессии, `#encryptForSession`, `#decryptIncomingEnvelope`, `#advanceChain`), `app/controllers/messages_controller.rb` (валидация headers)

### Фаза 2: Важные улучшения (приоритет: ВЫСОКИЙ)

#### 2.1 Верификация Identity Keys
- Генерировать safety number / security code из пары identity keys
- UI для отображения fingerprint
- QR-код для out-of-band верификации (инфраструктура уже есть: `qr_code_controller.rb`)
- Предупреждение при смене identity key собеседника
- **Файлы**: новый `app/javascript/lib/e2e/verification.js`, `app/javascript/controllers/e2e_verify_controller.js`, views в rooms/show

#### 2.2 Шифрование файловых вложений
- Encrypt файл на клиенте через AES-GCM перед upload
- Передать зашифрованный ключ файла через E2E конверт
- Расшифровать на клиенте при загрузке
- **Файлы**: `app/javascript/models/file_uploader.js`, `app/javascript/lib/e2e/client.js`, `app/controllers/messages_controller.rb`, новый `app/javascript/lib/e2e/file_crypto.js`

#### 2.3 Управление устройствами
- UI для просмотра списка своих устройств
- Возможность отзыва устройства
- Уведомление о новых устройствах собеседника
- Подтверждение нового устройства перед шифрованием для него
- **Файлы**: новый `app/controllers/users/e2e_devices_management_controller.rb`, views

#### 2.4 Сброс E2E шифрования
- Кнопка "Reset Encryption" для перегенерации identity key
- Удаление всех сессий и prekeys
- Уведомление контактов о смене ключей
- **Файлы**: `app/controllers/users/e2e_devices_controller.rb`, `app/javascript/lib/e2e/client.js`

### Фаза 3: Расширение функциональности (приоритет: СРЕДНИЙ)

#### 3.1 E2E для групповых чатов
- Реализовать Sender Keys protocol
- Каждый участник генерирует sender key, распространяет через pairwise E2E
- Group session management при add/remove участников
- **Файлы**: новый `app/javascript/lib/e2e/group_session.js`, изменения в `rooms_controller.rb`, `messages_controller.rb`

#### 3.2 Защита метаданных
- Минимизировать хранение метаданных на сервере
- Рассмотреть padding сообщений для сокрытия длины
- Sealed sender (скрытие отправителя от сервера)

#### 3.3 Резервное копирование ключей
- Encrypted key backup (зашифрованный экспорт identity key)
- Восстановление на новом устройстве через backup key
- Recovery code для аварийного восстановления

### Фаза 4: Тестирование и аудит (приоритет: ВЫСОКИЙ, параллельно)

#### 4.1 Клиентские тесты
- Unit-тесты для X3DH key agreement
- Unit-тесты для chain advancement и message encryption/decryption
- Integration-тесты для multi-device сценариев
- Тесты edge cases (corrupt state, localStorage overflow, concurrent tabs)

#### 4.2 Формальный аудит
- Заказать независимый криптографический аудит
- Проверка соответствия Signal Protocol specification
- Penetration testing E2E endpoints

---

## 6. Резюме

Текущая реализация создаёт **основу** для E2E-шифрования: X3DH-подобный key exchange, multi-device поддержка, серверная валидация. Однако присутствуют **критические пробелы**:

| Проблема | Серьёзность | Сложность исправления |
|----------|-------------|----------------------|
| Pseudo-подпись вместо ECDSA | Критическая | Средняя |
| Ключи в localStorage открыто | Критическая | Высокая |
| Нет DH Ratchet (только symmetric) | Критическая | Высокая |
| Нет верификации identity keys | Критическая | Средняя |
| Нет шифрования файлов | Высокая | Высокая |
| Нет очистки ключей из памяти | Высокая | Низкая |
| Нет уведомлений о новых устройствах | Средняя | Средняя |
| Нет групповых E2E чатов | Средняя | Очень высокая |
| Нет E2E тестов на клиенте | Высокая | Средняя |

**Общая оценка**: Реализация находится на стадии MVP/прототипа. Для production-ready E2E-шифрования необходимо пройти фазы 1-2 и провести независимый криптографический аудит.
