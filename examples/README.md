# Примеры

## `project-manifest.json`

Пример безопасного project manifest для Node.js-приложения. Скопируйте файл
в корень проекта под именем `.el-project.json`, затем проверьте результат:

```powershell
Copy-Item .\project-manifest.json C:\Code\MyProject\.el-project.json
Set-Location C:\Code\MyProject
el-project inspect .
```

Задачи `dev` и `tests` ссылаются только на уже существующие scripts из
`package.json`. EL Workspace не устанавливает пакеты и не создаёт scripts.
Они доступны в палитре, но не запускаются при обычном открытии workspace.

Если проект новый:

```powershell
el-project add .
```

Если проект уже зарегистрирован:

```powershell
el-project refresh myproject
```

Для автоматизированного `refresh` одного `-Yes` недостаточно: менеджер также
потребует точный SHA-256, показанный во время `inspect`.
