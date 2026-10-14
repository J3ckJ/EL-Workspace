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
- Go 1.22 или новее, только чтобы собрать бинарник.
- Для шагов workflow с `shell: pwsh` — PowerShell 7. Обычные шаги `run`
  идут через bash, а если его нет — через `sh`.

Сервер слушает `127.0.0.1`. Открывать порт в сеть можно флагом
`--http 0.0.0.0:8080` и `--ssh 0.0.0.0:2222`, если машина и так ваш домашний
сервер. SSH без добавленного ключа не пускает никого.

## macOS

```bash
git clone https://github.com/J3ckJ/EL-Workspace.git
cd EL-Workspace
go build -o server/bin/el ./server/cmd/el
./server/bin/el serve
```

Откройте `http://127.0.0.1:8080`. Данные лягут в
`~/.local/share/el-workspace` (или `$XDG_DATA_HOME/el-workspace`).

Ключ с этой машины подхватывается сам, если в каталоге ещё нет ключей и рядом
лежит `~/.ssh/id_ed25519.pub`. Иначе:

```bash
./server/bin/el key add ~/.ssh/id_ed25519.pub --title "MacBook"
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

Нужны PowerShell 7 и Git for Windows. Сборка из корня репозитория:

```powershell
go build -o server\bin\el.exe .\server\cmd\el
.\server\bin\el.exe serve
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

## Проверка

```bash
cd server
go test ./...
```

Сценарий теста создаёт репозиторий, клонирует и пушит по HTTP и SSH, смотрит
diff, открывает и сливает pull request, закрывает задачу через `fixes #N`,
прогоняет workflow, пушит зеркало на локальный bare-репозиторий, требует
подтверждение force-push и проверяет `git bundle`.
