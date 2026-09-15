<img src="Resources/Branding/AppIcon-1024.png" width="96" alt="GarminDesk icon">

# GarminDesk

Ваши показатели Garmin Connect в приложении для Mac и системных виджетах рабочего стола. Нативный интерфейс на русском и английском, гибкие профили, история занятий и опубликованный календарь тренировок.

[Скачать приложение](https://github.com/sifushka322/garmin-widget-macos/releases) · [Установка](docs/distribution.md) · [Версия 0.3.0](docs/releases/0.3.0.md) · [English](#english)

## Установка

1. Скачайте **GarminDesk-0.3.0-arm64.dmg** для Mac с Apple Silicon.
2. Откройте DMG, перенесите **GarminDesk.app** в **Applications («Программы»)** и запустите приложение оттуда.
3. В разделе **«Аккаунт Garmin»** выполните обычный вход Garmin Connect.
4. Откройте **«Профили виджетов»**, выберите показатели, оформление и назначения четырёх видов виджетов.
5. Нажмите правой кнопкой на рабочий стол → **«Изменить виджеты» → GarminDesk** и добавьте нужный виджет.

ZIP — альтернативный формат того же приложения. **Python, Homebrew, дополнительные библиотеки и терминал для установки не нужны.** Целевая система — macOS 14+, текущий пакет — Apple Silicon. Границы проверки конкретной версии указаны в [заметках к выпуску](docs/releases/0.3.0.md).

Приложение распространяется без платной подписи Developer ID и заверения Apple. Если macOS сообщает о неизвестном разработчике, после попытки открытия доверенной копии используйте **«Системные настройки» → «Конфиденциальность и безопасность» → «Всё равно открыть»**. [Инструкция Apple](https://support.apple.com/102445).

## Возможности

- **Одно окно и значок в Dock.** Обзор данных, профили, подключение Garmin и общие настройки находятся в одном приложении.
- **Четыре вида системных виджетов:** обзор, спорт, сон и тренировки; маленький, средний и большой размеры.
- **Гибкие профили:** состав и порядок показателей, главный показатель, плотность и оформление. Назначение каждого вида меняется в приложении; экземпляры одного вида используют одно назначение.
- **Тренировки:** последние завершённые занятия и предстоящие записи опубликованного календаря с явным указанием покрытия.
- **Автоматическое обновление** и сохранение сессии. Если новых измерений нет, остаются последние реальные значения с их датами. До подключения вымышленные показатели не показываются.
- **Русский и английский.** По умолчанию язык следует системе, вручную меняется в разделе «Основные».

Нажатие виджета открывает окно GarminDesk с его профилем. Закрытие окна оставляет синхронизацию работающей; **⌘Q** завершает приложение. Новые измерения требуют интернета и синхронизации часов с Garmin Connect. Расписание обновления системных виджетов контролирует macOS.

## Данные остаются у вас

Собственного сервера нет. Приложение подключается напрямую к Garmin через системный WebKit; сессия сайта и кэш хранятся локально. Расширение виджетов читает отдельный снимок без пароля и cookies. Учётные данные и измерения не входят в исходники или готовый пакет.

GarminDesk — неофициальное приложение, не связанное с Garmin. Доступность метрик зависит от устройства и аккаунта; изменения Garmin Connect могут потребовать обновления интеграции. Не прикладывайте к публичным Issues пароли, cookies, токены или личные экспорты.

## Сборка для разработчиков

Нужен Mac с совместимыми инструментами Swift и macOS SDK. Обычный пакет использует системные frameworks; Swift Package Manager и Python не требуются.

```bash
APP_VERSION=0.3.0 APP_BUILD=9 CONFIGURATION=release bash scripts/build-app.sh
bash scripts/package-release.sh
```

Приложение и архивы появятся в `build/`. Дополнительные параметры, вариант App Intents и необязательный legacy-коннектор описаны в [документации сборки](docs/distribution.md#для-разработчиков).

[История проверок 0.2.0](docs/validation.md) · [Аудит публикуемых файлов](docs/source-publication-audit-2026-09-16.md)

Лицензия исходников пока не выбрана.

## English

GarminDesk brings Garmin Connect data to a native Mac app and desktop widgets. Version 0.3.0 uses one regular window and a Dock icon, with **Overview**, **Widget profiles**, **Garmin account** and **General** sections.

Download **GarminDesk-0.3.0-arm64.dmg** from [Releases](https://github.com/sifushka322/garmin-widget-macos/releases), drag the app into Applications, then sign in under **Garmin account**. Configure profiles and assign the four widget kinds under **Widget profiles**. Right-click the desktop → **Edit Widgets → GarminDesk** to add a widget. Clicking it opens the app with its assigned profile.

No Python, Homebrew, additional libraries or terminal setup is required. The current package targets Apple Silicon and macOS 14+. See the [release notes](docs/releases/0.3.0.md) for this version's validation status. The app uses ad-hoc signing without Developer ID or notarization; a trusted download may require the standard macOS **Open Anyway** confirmation.

Health summaries, sleep, activity, recent workouts and published upcoming calendar entries are configurable. The interface follows the system language or your English/Russian selection. Closing the window keeps synchronization running; **⌘Q** quits the app.

GarminDesk connects directly to Garmin using system WebKit. Website session data and cached readings stay on your Mac; no developer-operated backend is involved. It is an unofficial project, not affiliated with Garmin. Source licensing has not yet been specified.
