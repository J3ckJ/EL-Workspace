# Политика безопасности

EL Workspace изменяет PowerShell profile, конфигурацию Windows Terminal и
запускает подтверждённые задачи локальных проектов. Ошибки на этих границах
считаются security-sensitive.

## Поддерживаемые версии

| Версия | Исправления безопасности |
|---|---|
| 0.1.x | да |
| неопубликованные прототипы | нет |

Исправления выпускаются для последней опубликованной версии.

## Как сообщить об уязвимости

Не создавайте публичный issue для ещё не исправленной уязвимости. Используйте
[private security advisory](https://github.com/J3ckJ/EL-Workspace/security/advisories/new).

По возможности приложите:

- версию EL Workspace, PowerShell, Windows и Windows Terminal;
- безопасные минимальные шаги воспроизведения;
- ожидаемое и фактическое поведение;
- оценку затронутых файлов и границы влияния;
- обезличенный фрагмент вывода или тестовый manifest.

Удалите имена пользователей, персональные абсолютные пути, remote URL
приватных репозиториев, токены и содержимое рабочих файлов. Не прикладывайте
целиком `$PROFILE`, `projects.json`, backup или архив пользовательского
каталога.

## Важные границы безопасности

Особенно важны сообщения о случаях, когда EL Workspace:

- записывает данные за пределами `%LOCALAPPDATA%\EL-System-Tools`, своего
  Terminal fragment или маркированного блока PowerShell profile;
- следует через junction, symlink или другой reparse point при backup,
  restore, обновлении или удалении;
- выполняет строку из `.el-project.json` без структурированного runner;
- позволяет относительному пути задачи выйти за пределы проекта;
- незаметно принимает изменённый manifest без нового подтверждения;
- удаляет registry проектов или пользовательские данные без `-PurgeData`;
- выполняет `git push` при грязном working tree или без подтверждения;
- повышает права, меняет системный `PATH` либо глобальный Git trust без
  явной необходимости.

Запуск подтверждённой проектной задачи исполняет код соответствующего
проекта. Поведение вредоносного `npm test`, `docker compose`, Python-модуля
или PowerShell-файла внутри недоверенного репозитория не является обходом
границ EL Workspace само по себе. Добавляйте только доверенные проекты.

## Установка и цепочка поставки

Стабильный установщик загружается из asset последнего GitHub Release:

```text
https://github.com/J3ckJ/EL-Workspace/releases/latest/download/install.ps1
```

`raw.githubusercontent.com/.../main/install.ps1` отражает ветку разработки и
не является стабильным release-каналом.

Перед запуском bootstrap можно скачать отдельно и прочитать:

```powershell
$installer = Join-Path $env:TEMP 'el-workspace-install.ps1'
Invoke-WebRequest `
  -Uri 'https://github.com/J3ckJ/EL-Workspace/releases/latest/download/install.ps1' `
  -OutFile $installer
Get-FileHash -LiteralPath $installer -Algorithm SHA256
notepad $installer
```

`SHA256SUMS.txt` содержит отдельные записи для bootstrap и release-архива.
Bootstrap загружает versioned `EL-Workspace-<version>.zip` и manifest из
одного Release,
требует ровно одну запись для ожидаемого имени ZIP и сравнивает SHA-256 до
распаковки. Архив дополнительно проверяется на абсолютные пути, path traversal
и reparse points.

Для ручной проверки payload:

```powershell
$base = 'https://github.com/J3ckJ/EL-Workspace/releases/latest/download'
$version = '0.1.1'
$archiveName = "EL-Workspace-$version.zip"
$archive = Join-Path $env:TEMP $archiveName
$sums = Join-Path $env:TEMP 'EL-Workspace-SHA256SUMS.txt'
Invoke-WebRequest "$base/$archiveName" -OutFile $archive
Invoke-WebRequest "$base/SHA256SUMS.txt" -OutFile $sums

$matching = @(Get-Content -LiteralPath $sums | Where-Object {
  $_ -match ('(?i)^[0-9a-f]{64}\s+\*?' + [regex]::Escape($archiveName) + '$')
})
if ($matching.Count -ne 1) { throw 'Checksum entry не найдена или неоднозначна.' }
$expected = ($matching[0] -split '\s+', 2)[0]
$actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
if ($actual -ne $expected) { throw 'SHA-256 не совпадает.' }
```

При несовпадении ничего не запускайте и сообщите об инциденте приватно.

Контрольная сумма не является доказательством авторства. Скрипты EL Workspace
версии 0.1.x не подписаны Authenticode; документация не утверждает обратного.

## Внешние компоненты

PowerShell, Windows Terminal, Git, `winget`, zoxide, fzf, Oh My Posh,
Terminal-Icons и шрифты имеют собственные модели обновления и безопасности.
EL Workspace не удаляет их при uninstall. Уязвимость во внешнем компоненте
следует также сообщать его сопровождающим.

## Backup и приватность

Backup предназначен для конфигурации EL Workspace и может содержать локальные
пути, названия проектов и Git remote. Он не предназначен для хранения
паролей, токенов или секретов. Храните backup как пользовательские данные и
не публикуйте его в issue или репозитории.
