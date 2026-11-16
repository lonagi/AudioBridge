# Сборка

Исходники: Swift/AppKit/AVAudioEngine для Mac, C#/.NET и NAudio.Wasapi 2.2.1 для Windows. Драйверы не устанавливаются.

## Mac

На Mac с Command Line Tools, из этой папки:

```sh
swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 mac/Packet.swift mac/Discovery.swift mac/Microphone.swift mac/MicrophoneTests.swift mac/UpdateServer.swift mac/main.swift -o AudioBridge
```

Полученный файл — исполняемая часть приложения. Установленное приложение находится в `/Applications/AudioBridge.app`. Его ресурсы `Contents/Resources` содержат индивидуальный `connection.json` и архив Windows. Рядом необходим `windows-version.json` вида `{"Version":"0.4.2"}`: версия должна совпадать с `<Version>` в WindowsAudio.csproj. При изменении приложения сначала закройте его, замените исполняемый файл в `Contents/MacOS`, затем выполните:

```sh
codesign --force --deep --sign - /absolute/path/AudioBridge.app
```

Готовый Mac-бинарник собран и проверен на текущем Mac Apple Silicon. Перенос на другие версии macOS отдельно не проверялся.

## Windows x64

С установленным .NET SDK 8:

```sh
dotnet publish windows/WindowsAudio.csproj -c Release -r win-x64 -p:RuntimeFrameworkVersion=8.0.31 -o publish-win
```

Скопируйте WindowsAudio.exe и connection.json в одну папку. Поля конфигурации: `MacIP` (подсказка для поиска), `Port` (49152), `Key` (32 случайных байта в Base64). Отправитель и приёмник должны использовать одинаковый ключ. Поле `DownloadToken` в конфигурации Mac задаёт индивидуальную ссылку HTTP-сервера на порту 8765.

Перед новой сборкой увеличьте `<Version>` в WindowsAudio.csproj. Для обновления скачиваемой версии упакуйте WindowsAudio.exe, connection.json, Install.cmd, Stop.cmd, Disable-startup.cmd, README.txt и лицензии в Windows-Audio.zip и замените также копию ZIP и windows-version.json внутри ресурсов приложения Mac. Полностью перезапустите Mac-приложение после замены: архив загружается при запуске. CMD-файлы должны иметь окончания строк CRLF.

`--install` копирует программу в `%LOCALAPPDATA%\AudioBridge`, регистрирует `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\AudioBridge` с аргументом `--background`, добавляет ярлыки в меню Пуск и запускает фоновую копию. Запись StartupApproved не изменяется, чтобы сохранять выбор пользователя в Диспетчере задач. Служба Windows и задача Планировщика не создаются. `--stop` останавливает только WindowsAudio с совпадающим ключом пары; `--disable-startup` удаляет запись Run. Именованный мьютекс препятствует запуску двух новых отправителей для одной пары.

Фоновая версия является WinExe: консольное окно не появляется. Статус пишется в ограниченный журнал status.log. Обычный ручной запуск также открывает значок в трее. Служебные команды установки и тестов подключают консоль. Значок реализован через Windows Forms NotifyIcon.

## Проверка протокола без Windows

Захват WASAPI доступен только в Windows, но код формирования пакетов можно проверить на Mac:

```sh
dotnet build windows/WindowsAudio.csproj -r osx-arm64 -p:TestHost=true -p:SelfContained=false -p:PublishSingleFile=false -o test-host
dotnet test-host/WindowsAudio.dll --config connection.json --fixture
./AudioBridge --verify-fixture connection.json fixture.bin
```

Команда `--test-silence` вместо `--fixture` отправляет четырёхсекундный тестовый поток тишины порциями по 100 мс. Не запускайте тест поверх реального потока Windows.

## Проверка автопоиска

```sh
dotnet test-host/WindowsAudio.dll --config connection.json --discovery-request
./AudioBridge --verify-discovery connection.json discovery-request.bin discovery-response.bin
dotnet test-host/WindowsAudio.dll --config connection.json --verify-discovery
```

`./AudioBridge --discovery-server-test connection.json 20` запускает только сервер поиска на 20 секунд, без окна и без звука. Во время его работы `dotnet test-host/WindowsAudio.dll --config connection.json --find-mac` проверяет обнаружение. Для проверки fallback укажите заведомо устаревший MacIP в отдельной тестовой конфигурации с тем же ключом.

`--test-reconnect` ожидает последовательность «найден → недоступен → снова найден» в течение 28 секунд. Использованная проверка: сервер работает 3 секунды, отсутствует 10 секунд, запускается снова. Endpoint истекает через 8 секунд без подтверждения. На Mac тест прошёл с реальными UDP-запросами и заведомо неправильным сохранённым IP. Это не проверяет настройки межсетевого экрана или автозапуск на самом Windows.

## Протокол поиска

UDP 49153. Запрос: WAD1 (4 байта), случайный challenge (16), HMAC-SHA256 первых 20 байт (32). Ответ: WAR1 (4), тот же challenge (16), порт аудио UInt16 little-endian (2), HMAC первых 22 байт (32). Ключ общий с аудио; префиксы разделяют типы сообщений. IP берётся из источника проверенного ответа, а не из содержимого пакета.

Поиск каждые ~2 секунды: широковещательные адреса активных IPv4-интерфейсов, общий broadcast, последний подтверждённый адрес и подсказка MacIP. Аудио отправляется только после аутентифицированного ответа и прекращается, когда подтверждение устарело. При недоступности аудиоустройства или сети выполняются повторы. Автопоиск рассчитан на одну локальную сеть без изоляции клиентов; между VLAN и через некоторые VPN broadcast не проходит.

## Формат пакета

Все целые поля little-endian. Размер не превышает 1000 байт.

| Смещение | Размер | Поле |
|---|---|---|
| 0 | 4 | WAM1 |
| 4 | 8 | Случайный идентификатор сеанса |
| 12 | 4 | Номер пакета |
| 16 | 4 | Частота дискретизации |
| 20 | 2 | Число каналов: 2 |
| 22 | 2 | Число кадров: 1–240 |
| 24 | кадры × 4 | Зашифрованный PCM16 stereo |
| конец | 16 | AES-GCM authentication tag |

Nonce: байты 4–15. AAD: первые 24 байта. Ключ AES-256 общий для пары. При повторном запуске захвата формируется новый идентификатор сеанса. Полученные аудиосэмплы не пишутся на диск.

## Проверка обновлений

```sh
dotnet test-host/WindowsAudio.dll --config connection.json --test-update-files
./AudioBridge --update-server-test connection.json Windows-Audio.zip
# Пока отдельный тестовый сервер работает на 8766, в другом терминале:
dotnet test-host/WindowsAudio.dll --config connection.json --test-update-http
```

Тестовый сервер живёт 60 секунд и автоматически ставит запрос тестовому клиенту. Он не запускает аудиоприёмник. Проверки: HMAC C# ↔ Swift, SHA-256 и размер ZIP, запрос/подтверждение команды, неверный ключ, повтор nonce, небезопасные пути и дубликаты ZIP, повреждённый архив, замена файла и откат. Файловый тест проверяет логику на Mac; реальный перезапуск EXE и установку нужно проверять на Windows. Не запускайте две сборки .NET одновременно: они используют общую obj.

## Протокол обновления 0.3

Windows раз в две секунды отправляет состояние на Mac TCP 8765 `POST /api/status`. Адрес берётся из подтверждённого UDP-автопоиска. Кнопка Mac создаёт requestId для подключённого clientId; следующий запрос Windows получает этот идентификатор. Подтверждение возвращается в RequestId статуса. Ручная проверка из трея использует тот же путь. При равной версии замена не производится; понижение версии отклоняется.

Метаданные: Version, Size, Sha256, RequestId. ZIP скачивается через `GET /api/package`. Подпись запроса X-AB-Auth — HMAC-SHA256 общего ключа над UTF-8 `AB-REQ/1\nMETHOD\nPATH\nNONCE\nBODY_SHA256`. Nonce — случайные 16 байт, lowercase hex в X-AB-Nonce. Подпись ответа — HMAC над `AB-RESP/1\nSTATUS\nNONCE\nBODY_SHA256`. Хэши — lowercase hex. Сервер отклоняет повторы nonce в течение пяти минут, клиент отключает прокси/редиректы и проверяет подпись до использования ответа.

Из проверенного архива извлекается только WindowsAudio.exe: существующий ключ и конфигурация сохраняются. На Windows проверяется также встроенная версия PE. Отдельная копия Updater.exe дожидается завершения отправителя, сохраняет .previous, заменяет EXE и запускает его. Новая версия должна подтвердить запуск окна сообщений/трея за 15 секунд; иначе выполняется попытка отката. Проверка запуска не доказывает доступность аудиоустройства или сети. Результат сохраняется в update-result.json и читается отправителем для журнала, трея и статуса Mac.

Архивы содержат личный ключ пары; публичный репозиторий обновлений в этой версии не используется. Первая установка 0.3 поверх 0.2 выполняется вручную через Install.cmd.

## Микрофон 0.4.2

Добавьте NSMicrophoneUsageDescription в Info.plist Mac-приложения. Разрешение спрашивается только при первом включении, после открытия аутентифицированного потока. Для входа используется собственный AVAudioEngine с kAudioOutputUnitProperty_CurrentDevice; системный микрофон macOS не меняется. Список источников ограничен HyperX/QuadCast и аппаратным встроенным входом.

Windows отправляет Microphone в POST /api/status каждые 500 мс: Session, Outputs, Command, Status, Revision. Mac возвращает Microphone (Enabled, Source, OutputId, Sources, Status, CommandId, Revision). Mac владеет текущим состоянием; команды с повторным Id не применяются. Новая сессия Windows и потеря управления на 6 секунд выключают захват. Сохраняются только Source/OutputId. Состояние Enabled не пишется на диск.

Windows открывает POST /api/microphone с подписанным JSON ClientId/Session/Stream. Сервер проверяет активную пару/сессию и включение режима; возвращает HTTP 200 chunked с подписью пустого тела в X-AB-Auth. Далее идут бинарные кадры, каждый с UInt16 LE длиной, заголовком ABM1 (4), sequence UInt64 LE (8), rate UInt32 LE (4), PCM16 mono ciphertext (до 960 байт), AES-GCM tag (16). Ключ SHA-256(pairingKeyBytes || UTF8("AudioBridge microphone v1\n" + Stream)), nonce — 4 нулевых байта и sequence LE (8), AAD — заголовок 16 байт. Для каждого подключения Windows выбирает случайный Stream (GUID N); sequence начинается с 0. Это отделяет ключ и nonce от направления Windows → Mac и предыдущих подключений.

AudioRelayMicrophone.cs передаёт PCM прямо установленному драйверу AudioRelay Virtual Mic. Steam и устройства воспроизведения в этом пути не используются. Поддержан драйвер 1.0.2 из официального установщика AudioRelay 0.27.5 (https://dl.audiorelay.net/setups/windows/audiorelay-0.27.5.exe). Контракт совместимости проверен по native-driver.dll и virtual-mic.sys: `\\.\AudioRelayVirtualMicDeviceLink`, IOCTL 0x223070 (uint32 ёмкость очереди в байтах), 0x223074 (PCM16 LE 48 kHz stereo, ответ 8 байт). Перед обращением сверяется SHA-256 установленного файла драйвера. Драйверы и DLL AudioRelay в пакет не включены.

Mono PCM превращается в стерео, отличная от 48 kHz частота обрабатывается WDL resampler NAudio. Очередь драйвера — 100 мс. При выключении отменяется сетевой поток и очищается очередь. WasapiCapture читает тот же виртуальный вход, не сохраняя звук, для индикатора уровня и подтверждения поступления в capture endpoint. Телеметрия возвращается только парному Mac через подписанный /api/status.

CaptureDefaults.cs сохраняет прежние входы для Console/Multimedia/Communications в microphone-defaults.json перед переключением. При выключении, штатном выходе или потере связи прежние значения восстанавливаются, если пользователь не поменял их вручную. При следующем запуске восстанавливается журнал, оставшийся после принудительного завершения. Windows IPolicyConfig COM ABI соответствует используемому Sunshine интерфейсу; после установки выполняется чтение для проверки. Приложения с явно заданным другим микрофоном должны выбрать Default.

Проверки без доступа к реальному микрофону:

```sh
./AudioBridge --microphone-control-test connection.json
./AudioBridge --mic-fixture connection.json mic-fixture.bin
dotnet test-host/WindowsAudio.dll --config connection.json --test-mic-fixture
dotnet test-host/WindowsAudio.dll --config connection.json --test-mic-defaults
./AudioBridge --microphone-server-test connection.json
# В другом терминале в течение 60 секунд:
dotnet test-host/WindowsAudio.dll --config connection.json --test-mic-http
```

Тестовый сервер использует только порт 8766 и синтетическую тишину; физический вход не открывается. Полный маршрут через драйвер виртуального кабеля требует проверки на Windows через установленный AudioRelay Virtual Mic.
