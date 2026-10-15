# Локальный Git-хост

EL Workspace умеет быть маленьким GitHub, который живёт на вашем Mac или
Windows. Репозитории хранятся дома. GitHub, если он подключён, только зеркало:
push уходит после слияния в основную ветку, а обрыв сети оставляет задание в
очереди.

Лаунчер PowerShell (`el`, `el <проект>`, `el run`) от этого не меняется.
Команды хоста — отдельные подкоманды того же `el`.

## Почему такой стек

Сервер написан на Go и собирается в один бинарник без CGO.

- Go запускается одинаково на macOS и Windows, умеет встроить веб-интерфейс и
  поднять SSH-сервер через `golang.org/x/crypto/ssh`.
- Объекты и pack-протокол не переписаны. Smart HTTP и SSH вызывают системные
  `git upload-pack` и `git receive-pack`, поэтому `git clone` и `git push`
  говорят с настоящим Git.
- Задачи, pull request, комментарии, сборки, очередь зеркала и ключи лежат в
  SQLite (`modernc.org/sqlite`, без отдельной установки).
- Интерфейс — обычные HTML, CSS и JS внутри бинарника. Отдельный Node.js для
  запуска не нужен.

Rust дал бы тот же один файл, но SSH, SQLite и встраивание UI здесь короче на
Go, а поведение протокола всё равно определяется установленным Git.

## Что нужно заранее

- Git 2.30 или новее в `PATH` (нужны `upload-pack`, `receive-pack`,
  `merge-tree`, `bundle`).
- Go 1.22 или новее, только чтобы собрать бинарник. На Mac:
  `brew install go`. На Windows, в PowerShell 7: `winget install GoLang.Go`.
  После установки откройте терминал заново, иначе `go` не попадёт в `PATH`.
- Для шагов workflow с `shell: pwsh` — PowerShell 7. Обычные шаги `run`
  идут через bash, а если его нет — через `sh`.

Сервер слушает `127.0.0.1`. Открывать порт в сеть можно флагом
`--http 0.0.0.0:8080` и `--ssh 0.0.0.0:2222`, если машина и так ваш домашний
сервер. SSH без добавленного ключа не пускает никого.

## macOS

Модуль Go лежит в `server/`, не в корне репозитория. Сборка из корня
заканчивается `go: cannot find main module`.

```bash
git clone https://github.com/J3ckJ/EL-Workspace.git
cd EL-Workspace
cd server && go build -o bin/el ./cmd/el
./bin/el serve
```

Откройте `http://127.0.0.1:8080`. Данные лягут в
`~/.local/share/el-workspace` (или `$XDG_DATA_HOME/el-workspace`).

Ключ с этой машины подхватывается сам, если в каталоге ещё нет ключей и рядом
лежит `~/.ssh/id_ed25519.pub`. Иначе:

```bash
./bin/el key add ~/.ssh/id_ed25519.pub --title "MacBook"
```

Клонирование:

```bash
git clone http://127.0.0.1:8080/git/eugene/FlyDrop.git
git clone ssh://git@127.0.0.1:2222/eugene/FlyDrop.git
```

Меню-бар. В EL Workspace откройте `#/panel` или выполните `el panel`. Для
SwiftBar положите [`panel/el-menubar.sh`](../panel/el-menubar.sh) в каталог
плагинов и поправьте адрес, если порт не 8080.

## Windows

Нужны PowerShell 7 и Git for Windows. Если `go` ещё нет:

```powershell
winget install GoLang.Go
```

Закройте окно терминала и откройте новое, затем соберите из каталога `server`.
Флаг `-o` пишет файл ровно под указанным именем и сам `.exe` не добавляет,
поэтому на Windows имя — `bin\el.exe`. Локальный путь `.\cmd\el` Go на
Windows принимает и переводит обратные слэши в обычные.

```powershell
cd EL-Workspace
cd server && go build -o bin\el.exe .\cmd\el
.\bin\el.exe serve
```

Либо, когда бинарник уже лежит в `server\bin` или в `src\Terminal\bin`:

```powershell
el serve
```

Каталог данных: `%LOCALAPPDATA%\EL-System-Tools\Git`.

Ключ:

```powershell
el key add $env:USERPROFILE\.ssh\id_ed25519.pub --title "Windows"
```

Трей: [`panel/el-tray.ps1`](../panel/el-tray.ps1). Скрипт показывает иконку и
по клику открывает ту же панель, что и меню-бар на Mac.

```powershell
pwsh -NoProfile -File .\panel\el-tray.ps1
```

`el serve` в PowerShell не конфликтует с короткой командой `serve`, которая
по-прежнему запускает задачу `dev` проекта `website`.

## Ежедневные команды

```bash
el serve --demo          # учебные репозитории, только в пустой каталог данных
el repo create FlyDrop --description "файлы по локальной сети"
el pr checkout 2 --repo eugene/Transport-Master
el release v0.4.1 --from-ci --repo eugene/AppRestore
el release v0.4.1 --from-ci --repo eugene/AppRestore --publish
el panel
el status
```

`--from-ci` берёт файлы, которые успешный workflow положил в `artifacts/`
(переменная `EL_ARTIFACTS`). `--publish` отправляет тег на URL зеркала. Если
зеркало — GitHub и в настройках сохранён токен, дополнительно создаётся
GitHub Release. Токен в окружение сборки не передаётся.

Другой каталог данных: `el serve --data D:\EL\git` и тот же `--data` у
клиентских команд. Файл `server.json` в этом каталоге говорит командам, куда
стучаться, и удаляется при остановке сервера.

## Как устроены зеркало, задачи и сборки

Режим репозитория:

| Режим | Поведение |
|---|---|
| только локально | наружу ничего не уходит |
| push при слиянии | основная ветка и теги ставятся в очередь после обновления |
| двусторонний | то же для каждой обновлённой ветки |

Очередь повторяет push, пока зеркало не примет его. Если истории разошлись,
обычный push не переписывает зеркало. Force-push в интерфейсе сначала
показывает коммиты, которые есть на зеркале и пропадут, и выполняется только
если подтверждённый список совпал с текущим.

Задача закрывается, когда в основную ветку попадает коммит или текст pull
request с `fixes #12`, `closes #12` или темой вида `fix: сокеты #12`.

Сборки читают `.github/workflows/*.yml`. Запускаются шаги `run`.
`actions/checkout` ничего не делает: рабочая копия уже есть. Любой другой
`uses` пропускается и пишется в лог. `runs-on` сохраняется в журнале, команды
выполняются локально — на том Mac или Windows, где запущен сервер.

Коммиты, которые создаёт сам хост (слияние, squash, правка, тег), подписываются
автором `Evgenii Lyubkin <80674830+J3ckJ@users.noreply.github.com>` и не
добавляют `Co-authored-by`.

## Интерфейс

EL Midnight включена по умолчанию. Светлая тема переключается в сайдбаре и
запоминается в браузере; `?theme=light` открывает её сразу. Пустые списки,
недоступный сервер, очередь зеркала и расхождение истории — отдельные
состояния. Числа на них приходят из заданий и последней успешной связи, а не
из подписей макета.

## Проверка

```bash
cd server
go test ./...
```

Сценарий теста создаёт репозиторий, клонирует и пушит по HTTP и SSH, смотрит
diff, открывает и сливает pull request, закрывает задачу через `fixes #N`,
прогоняет workflow, пушит зеркало на локальный bare-репозиторий, требует
подтверждение force-push и проверяет `git bundle`.
