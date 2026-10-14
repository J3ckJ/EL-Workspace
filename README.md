# EL Workspace

[![CI](https://github.com/J3ckJ/EL-Workspace/actions/workflows/ci.yml/badge.svg)](https://github.com/J3ckJ/EL-Workspace/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/J3ckJ/EL-Workspace?display_name=tag&sort=semver)](https://github.com/J3ckJ/EL-Workspace/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-2ea44f.svg)](LICENSE)

Аккуратное рабочее окружение для PowerShell 7 и Windows Terminal: единый
launcher проектов, контекстные вкладки, быстрые переходы и безопасное
управление установкой.

EL Workspace не заменяет терминал и не прячет команды проекта. Он собирает
их в понятный интерфейс, показывает план до запуска и оставляет пользователю
контроль над тем, что будет выполнено.

## Быстрый старт

Требования: Windows 10/11, PowerShell 7.2+ и Windows Terminal. Git нужен для
Git-команд и открытия репозиториев. `winget` рекомендуется для установки
необязательных зависимостей.

Откройте **PowerShell 7** и выполните:

```powershell
irm https://github.com/J3ckJ/EL-Workspace/releases/latest/download/install.ps1 | iex
```

После успешной установки сразу выполните вторую команду в том же окне:

```powershell
el
```

Установщик подключает команды к текущей сессии. Новое окно нужно только для
полного применения шрифта, цветов и остальных настроек Terminal.

Установщик работает в контексте текущего пользователя. Запуск от
администратора для обычной установки не требуется.

> Канонический URL указывает на asset последнего опубликованного GitHub
> Release и является стабильным каналом установки.
> Вариант `raw/main` предназначен только для разработки и может содержать
> изменения, которые ещё не вошли в релиз.

Локальная установка из клона:

```powershell
git clone https://github.com/J3ckJ/EL-Workspace.git
Set-Location .\EL-Workspace
pwsh -NoProfile -File .\install.ps1 -SourcePath .
```

Fallback на bootstrap из ветки разработки:

```powershell
irm https://raw.githubusercontent.com/J3ckJ/EL-Workspace/main/install.ps1 | iex
```

Если вы не хотите передавать сетевой ответ прямо в `iex`, сначала скачайте и
просмотрите установщик:

```powershell
$installer = Join-Path $env:TEMP 'el-workspace-install.ps1'
irm https://github.com/J3ckJ/EL-Workspace/releases/latest/download/install.ps1 -OutFile $installer
notepad $installer
pwsh -NoProfile -File $installer
```

## Что даёт EL Workspace

- распознаёт PWA, Docker Compose, Node.js, Python, .NET, Rust, Go и обычные
  проекты;
- по умолчанию создаёт рабочее пространство Windows Terminal без
  автоматического запуска dev-серверов, тестов или сборки;
- задаёт вкладкам контекстные названия и цвета в зависимости от проекта и
  задачи;
- добавляет интерактивный выбор проектов через `fzf` и быстрые переходы через
  `zoxide`;
- настраивает Oh My Posh, Terminal-Icons и удобное поведение PSReadLine, если
  соответствующие компоненты доступны;
- хранит подтверждённый snapshot задач и не перечитывает project manifest при
  каждом запуске;
- умеет диагностировать, обновлять, резервировать, восстанавливать и удалять
  собственную установку.

По умолчанию установщик пытается добавить недостающие zoxide, fzf и Oh My
Posh через `winget --scope user`, а CaskaydiaCove Nerd Font — через Oh My
Posh. Ошибка необязательной зависимости выводится как предупреждение и не
ломает базовый EL Workspace. Terminal-Icons автоматически не устанавливается,
но подключается, если модуль уже есть. Чтобы полностью пропустить bootstrap
зависимостей, скачайте установщик в файл и запустите его с
`-SkipDependencies`.

## Основные команды

| Команда | Что делает |
|---|---|
| `el` | Открывает интерактивный launcher проектов |
| `el <id>` | Открывает workspace зарегистрированного проекта |
| `el run <id> [task]` | Выбирает или запускает задачу проекта |
| `el recent` / `el favorites` / `el last` | Открывает недавние, избранные или последний проект |
| `el-project inspect .` | Показывает распознанный стек и задачи без изменений |
| `el-project add .` | Добавляет проект после предпросмотра и подтверждения |
| `el-project init .` | Создаёт шаблон `.el-project.json` |
| `el-project status [id]` | Показывает стек, Git-состояние и статус manifest |
| `el-project sync [-Check]` | Пересобирает Terminal fragment или проверяет его актуальность |
| `el-project trust-git <id\|path>` | Разрешает Git только для точного пути внутри EL |
| `el-project doctor` | Проверяет registry, runner, Terminal и проекты |
| `elj` | Выбирает проект в компактном `fzf`-интерфейсе |
| `z <часть-пути>` / `zi` | Быстро переходит в посещённый каталог через `zoxide` |
| `app` / `clean` / `site` | Открывает проекты `apprestore`, `cleantools` или `website` |
| `serve` | Запускает задачу `dev` проекта `website` |
| `g` | Показывает краткий Git-статус; аргументы передаются в `git` |
| `el-workspace doctor` | Проверяет установленный EL Workspace |
| `update-tools` | Запускает обновление из последнего GitHub Release |
| `publish` | После проверки и подтверждения отправляет текущую чистую Git-ветку |
| `el serve` | Поднимает локальный Git-хост, если собран бинарник |
| `el pr checkout <n>` | Забирает ветку pull request в текущий клон или клонирует её |
| `el release <tag> --from-ci` | Создаёт релиз из артефактов последней зелёной сборки |

Полная встроенная справка:

```powershell
el help
el-project help
el-workspace help
```

Короткие команды `app`, `clean`, `site` и `serve` начинают работать после
регистрации проектов с соответствующими ID. Посмотреть ID можно через
`el-project list`.

`publish` не создаёт коммит, Release или pull request. Команда отказывается
работать при незакоммиченных изменениях, показывает выбранные repository,
branch и remote, а затем выполняет обычный `git push` только после
подтверждения.

## Как добавить проект

Сначала выполните безопасный предпросмотр:

```powershell
Set-Location C:\Code\MyProject
el-project inspect .
```

Если стек и найденные задачи корректны, добавьте проект и откройте его:

```powershell
el-project add .
el-project list
el myproject
```

Менеджер ничего не устанавливает и не запускает во время `inspect` и `add`.
Если тип проекта неоднозначен, укажите его явно:

```powershell
el-project add . -Stack pwa
```

Поддерживаемые значения `-Stack`: `pwa`, `compose`, `node`, `python`,
`dotnet`, `rust`, `go`, `generic`.

### Project manifest

Для собственного набора задач создайте `.el-project.json`:

```powershell
el-project init .
```

После редактирования сначала проверьте manifest, затем подтвердите импорт:

```powershell
el-project inspect .
el-project add .
```

Для уже зарегистрированного проекта используйте:

```powershell
el-project inspect .
el-project refresh myproject
```

Готовый документированный шаблон находится в
[`examples/project-manifest.json`](examples/project-manifest.json). Project
manifest читается только при `inspect`, `add` и `refresh`; при открытии
workspace выполняется сохранённый локальный snapshot.

## Навигация и контекст терминала

`elj` фильтрует реестр проектов через `fzf`. `zoxide` запоминает посещённые
каталоги и предоставляет команды `z` и `zi`. Если одна из этих программ не
установлена, базовые команды `el` и `el-project` продолжают работать.

Открытая задача получает собственные:

- заголовок вкладки вида `EL · Проект · Задача`;
- цвет вкладки по типу задачи;
- контекст `EL_PROJECT_*` и `EL_TASK_*` для prompt;
- индикатор выполнения Windows Terminal для длительной команды.

## Обслуживание установки

```powershell
el-workspace version
el-workspace doctor
el-workspace doctor -Online
update-tools
```

`doctor -Online` дополнительно проверяет доступность endpoint последнего
Release. Обычный `doctor` не требует сетевого доступа.

Создание и восстановление backup:

```powershell
el-workspace backup
el-workspace restore 'C:\path\to\workspace-20260731-120000-ab12cd34'
```

Перед восстановлением создаётся дополнительный backup текущего состояния.
Целостность файлов из backup проверяется по SHA-256.

Удаление runtime с сохранением реестра проектов, состояния launcher и backup:

```powershell
el-workspace uninstall
```

Полное удаление локальных данных требует отдельного флага и подтверждения:

```powershell
el-workspace uninstall -PurgeData
```

EL Workspace не удаляет проекты, Git, PowerShell, Windows Terminal, zoxide,
fzf, Oh My Posh, шрифты или Terminal-Icons.

## Где хранятся данные

```text
%LOCALAPPDATA%\EL-System-Tools\
├── Backups\
└── Terminal\
    ├── el.ps1
    ├── el-project.ps1
    ├── el-workspace.ps1
    ├── workspace-pane.ps1
    ├── profile.ps1
    ├── projects.json
    ├── launcher-state.json
    ├── install.json
    ├── *.schema.json
    └── themes\

%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\
└── EL.ProjectManager\projects.json
```

Общий профиль PowerShell текущего пользователя
(`$PROFILE.CurrentUserAllHosts`) не заменяется целиком: установщик управляет
только блоком между маркерами `# >>> EL Workspace >>>` и
`# <<< EL Workspace <<<`.

## Безопасность

Менеджер проектных задач не использует `Invoke-Expression`, `cmd /c` или
произвольную строку из project manifest. Задачи представлены
структурированными runner-типами, относительные пути проверяются, а изменения
manifest требуют повторного предпросмотра и подтверждения. PowerShell profile
может инициализировать установленный zoxide или Oh My Posh сгенерированным ими
кодом; это отдельная граница доверия внешним компонентам.

При этом `test`, `dev`, `build` и другие задачи запускают код самого проекта.
Добавляйте только доверенные каталоги и проверяйте показанный план.

Release-архивы сопровождаются SHA-256. Контрольная сумма помогает обнаружить
повреждение или подмену asset относительно опубликованного manifest, но не
заменяет цифровую подпись: текущие скрипты не подписаны Authenticode.

Подробнее: [SECURITY.md](SECURITY.md).

## Если что-то пошло не так

### Вместо скрипта пришла страница Cloudflare

Такое происходило с временным доменом `chatgpt.site`: Cloudflare возвращал
HTML challenge, и `irm ... | iex` пытался выполнить HTML как PowerShell.
Установщик EL Workspace публикуется напрямую в GitHub Releases, поэтому этот
домен и его cookie/challenge-механизм не участвуют в установке.

Используйте только каноническую команду из раздела «Быстрый старт». Если
endpoint недоступен, скачайте asset в браузере со страницы
[последнего Release](https://github.com/J3ckJ/EL-Workspace/releases/latest)
и проверьте SHA-256 из того же Release.

### Команда `el` не найдена

Закройте и заново откройте PowerShell 7. Если функция `el-workspace` тоже не
найдена, запустите doctor напрямую из установленного runtime:

```powershell
& "$env:LOCALAPPDATA\EL-System-Tools\Terminal\el-workspace.ps1" doctor
```

Убедитесь, что открыт именно `pwsh`, а управляемый блок присутствует в
`$PROFILE.CurrentUserAllHosts`.

### Иконки отображаются квадратами

Выберите Nerd Font в профиле Windows Terminal — установщик EL Workspace
использует семейство `CaskaydiaCove NFM`. После изменения полностью
перезапустите Terminal.

### Палитра Terminal отстаёт от реестра

```powershell
el-project sync
el-project sync -Check
```

## Локальный Git-хост

Рядом с лаунчером терминала EL Workspace держит свой Git. Репозитории
живут на этой машине, интерфейс открывается в браузере, а GitHub остаётся
зеркалом: после слияния в основную ветку push ставится в очередь и уходит,
когда сеть есть. Force-push в зеркало показывает коммиты, которые будут
потеряны, и выполняется только после явного подтверждения этого списка.

Сервер — один Go-бинарник. Smart HTTP и SSH не имитируются: они вызывают
системные `git upload-pack` и `git receive-pack`. Задачи, pull request,
сборки и ключи лежат в SQLite. Веб-интерфейс встроен в бинарник, отдельный
Node.js для запуска не нужен. Почему выбран именно этот набор, как поставить
его на Mac и Windows и как устроены очередь, сборки и бэкап, написано в
[docs/local-git.md](docs/local-git.md).

Коротко, из корня репозитория:

```bash
go build -o server/bin/el ./server/cmd/el
./server/bin/el serve
```

На Windows, когда `server\bin\el.exe` уже собран, достаточно `el serve` в
PowerShell 7. Каталог данных — `%LOCALAPPDATA%\EL-System-Tools\Git`, на
macOS и Linux — `~/.local/share/el-workspace`. По умолчанию HTTP и SSH
слушают только `127.0.0.1`.

В интерфейсе: обзор с блоком «нужно внимание» и одним главным действием,
репозиторий с деревом файлов и README, история и diff (J/K, вместе или
раздельно), pull request с комментарием к строке и squash/rebase/merge,
доска задач по всем репозиториям, релизы, локальный прогон
`.github/workflows`, настройки зеркала и ночной `git bundle`. Поиск по коду,
коммитам и задачам открывается по Ctrl+K или Cmd+K.

Панель меню-бара macOS и трея Windows — это `#/panel` плюс
[`panel/el-menubar.sh`](panel/el-menubar.sh) и
[`panel/el-tray.ps1`](panel/el-tray.ps1).

Сборка `run` из workflow выполняется на той же машине, что и сервер. Пушьте
workflow только в репозитории, которым доверяете. Коммиты, которые создаёт
сам хост, авторствует как
`Evgenii Lyubkin <80674830+J3ckJ@users.noreply.github.com>`.

Проверка сервера:

```bash
cd server
go test ./...
```

## Разработка

```powershell
git clone https://github.com/J3ckJ/EL-Workspace.git
Set-Location .\EL-Workspace
pwsh -NoProfile -File .\scripts\test-install.ps1
pwsh -NoProfile -File .\scripts\build-release.ps1
```

`test-install.ps1` использует изолированные временные пути и не меняет
пользовательский registry проектов, PowerShell profile или настройки
Terminal. CI дополнительно проверяет синтаксис PowerShell и корректность JSON.

История изменений: [CHANGELOG.md](CHANGELOG.md). Сообщение об уязвимости:
[SECURITY.md](SECURITY.md).

## Лицензия

[MIT](LICENSE) © 2026 J3ckJ and EL Workspace contributors.
