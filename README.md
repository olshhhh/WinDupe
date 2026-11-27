# WinDupe

> **Aviso de autoría y transparencia:** Este proyecto fue desarrollado con asistencia de Inteligencia Artificial en el **Creador de Apps de Google AI Studio**. Todo el código fuente (PowerShell, C# y XAML) se distribuye íntegro en texto plano, sin binarios precompilados (`.exe` / `.dll`), para garantizar su **total auditabilidad y transparencia** antes de ejecutarse en tu equipo.

## Descripción corta sugerida (About de GitHub)

> Buscador y limpiador ultra-rápido de archivos duplicados para Windows 10/11 en PowerShell + C# (`Add-Type`) + WPF oscuro, sin requerir permisos de Administrador (sin UAC), con motor de 3 fases, protección OneDrive/Hard-Links NTFS, modo `-Cli` y envío seguro a la Papelera de Reciclaje.

---

## Qué SÍ es y qué NO es

### Qué SÍ es
- Una herramienta nativa y ligera para **Windows 10 y Windows 11** que detecta archivos idénticos mediante un motor en C# compilado en memoria (`Add-Type`) de **3 fases** (`Tamaño exacto -> Hash parcial 16 KB -> SHA-256 completo`).
- Una interfaz gráfica **WPF/XAML en modo oscuro** fluida y sin congelamientos (`RunspacePool` + `ConcurrentQueue` + `DispatcherTimer`), con búsqueda instantánea en resultados, filtro por tamaño mínimo y selección inteligente (incluso por carpeta completa).
- Un **modo consola (`-Cli`)** para generar reportes de espacio recuperable desde terminal (incluyendo salida `-Json` compatible con pipelines de PowerShell).
- Un limpiador seguro que **no requiere elevación UAC**, omite archivos en la nube de OneDrive (*Files On-Demand*) y enlaces duros (*Hard Links* NTFS), y envía copias exclusivamente a la **Papelera de Reciclaje de Windows** dejando registro de auditoría.

### Qué NO es
- **No es** un buscador de imágenes "visualmente parecidas" o difusas: compara contenido binario exacto (SHA-256).
- **No es** un programa con instalador persistente ni deja servicios residentes en segundo plano: se ejecuta de forma volátil desde `%TEMP%` y se autodestruye al cerrarse.
- **No realiza** borrados permanentes destructivos (`Remove-Item -Force`) ni modifica `C:\Windows`, `Program Files` o carpetas ocultas del sistema.

### Advertencia de privilegios, SmartScreen / Antivirus y responsabilidad
- **Privilegios:** WinDupe está diseñado para funcionar como **usuario estándar sin elevación UAC**. Nunca solicitará permisos de Administrador.
- **SmartScreen / Antivirus:** Al descargarse y compilar código C# en memoria mediante `Add-Type`, algunos antivirus heurísticos pueden emitir una alerta preventiva. Al ser código 100% abierto en texto plano, puedes auditar `bootstrap.ps1`, `WinDupe.ps1` y `Core/WinDupeEngine.cs` línea por línea antes de ejecutarlo.
- **Responsabilidad del usuario:** Aunque WinDupe utiliza la Papelera de Reciclaje y guarda un registro de auditoría, el usuario es responsable de revisar qué archivos selecciona antes de confirmar la limpieza.

---

## Cómo usar (Ejecución Zero-Install en 1 línea)

Abre **PowerShell** en Windows 10 o Windows 11 (no necesitas abrirlo como Administrador) y ejecuta:

```powershell
irm https://raw.githubusercontent.com/olshhhh/WinDupe/main/bootstrap.ps1 | iex
```

### Variantes con parámetros (`[scriptblock]::Create`)

**Abrir la interfaz gráfica apuntando a Imágenes (archivos mayores a 1 MB):**
```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/olshhhh/WinDupe/main/bootstrap.ps1))) -Profile Pictures -Filter Images -MinSizeMB 1
```

**Modo consola (`-Cli`) para generar reporte de espacio recuperable en una ruta:**
```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/olshhhh/WinDupe/main/bootstrap.ps1))) -Cli -Path "$env:USERPROFILE\Downloads"
```

**Modo consola (`-Cli`) filtrando Videos > 10 MB y exportando en JSON directo a objeto PowerShell:**
```powershell
$reporte = & ([scriptblock]::Create((irm https://raw.githubusercontent.com/olshhhh/WinDupe/main/bootstrap.ps1))) -Cli -Path "D:\Multimedia" -Filter Videos -MinSizeMB 10 -Json | ConvertFrom-Json
$reporte.totalReclaimableHuman
```

### Ejecución local (repositorio clonado)

```powershell
git clone https://github.com/olshhhh/WinDupe.git
cd WinDupe
.\bootstrap.ps1 -BaseUrl "$PWD"
```

---

## Arquitectura interna paso a paso

1. **Lanzador volátil (`bootstrap.ps1`):**
   - Configura TLS 1.2 y política de ejecución únicamente para el proceso actual (`-Scope Process`).
   - Crea una carpeta temporal única en `%TEMP%\WinDupe_<GUID>`.
   - Descarga los módulos desde GitHub Raw con *cache-busting* (`?cb=<timestamp>` y `Cache-Control: no-cache`), guardando `.ps1` en UTF-8 con BOM y `.xaml/.json/.cs` en UTF-8 sin BOM.
   - Inicia `WinDupe.ps1 -BasePath "$volatileRoot"` en modo `-STA` (sin UAC) para WPF o directamente en consola para `-Cli`, destruyendo la carpeta temporal en un bloque `finally`.

2. **Motor de escaneo en 3 fases (`Core/WinDupeEngine.cs` + `Core/ScannerService.ps1`):**
   - Compilado en memoria con `Add-Type` (C# compatible con Windows PowerShell 5.1 y PowerShell 7+) y ejecutado en segundo plano mediante `RunspacePool` + `ConcurrentQueue` + `DispatcherTimer`:
     - **Fase 1 (Tamaño exacto):** Recorre directorios de forma iterativa segura, omite marcadores en la nube de OneDrive (*Offline / RecallOnDataAccess*) y agrupa por `Length` en bytes, descartando al instante cualquier archivo de tamaño único.
     - **Fase 2 (Hash parcial de 16 KB + Hard Links NTFS):** Detecta mediante `kernel32.dll` (`GetFileInformationByHandle`) si dos rutas son enlaces duros al mismo inodo NTFS para no falsificar espacio recuperable, y calcula SHA-256 únicamente sobre los primeros `16,384` bytes de los candidatos de Fase 1.
     - **Fase 3 (SHA-256 completo):** Calcula el hash SHA-256 completo en búferes de 128 KB únicamente sobre los candidatos reales que sobrevivieron a la Fase 2.

3. **Interfaz gráfica moderna (`UI/MainWindow.xaml` + `WinDupe.ps1`):**
   - Tema oscuro nativo en WPF con accesos rápidos (`Descargas`, `Documentos`, `Imágenes` o carpeta personalizada), filtro por categoría (`Todos`, `Imágenes`, `Videos`, `Documentos`, `Audio`), filtro de tamaño mínimo, buscador en tiempo real, vista previa en memoria sin bloquear archivos en disco (`MemoryStream` + `OnLoad`), menú contextual para marcar copias por carpeta y selección inteligente O(n) (*Conservar más antiguo*, *Conservar más reciente*, *Selección automática*).

4. **Guardrails y auditoría (`Core/Guardrails.ps1` + `Core/RecycleAudit.ps1`):**
   - Bloquea explícitamente `C:\Windows`, `Program Files`, `Program Files (x86)`, `ProgramData`, `$Recycle.Bin`, `System Volume Information`, enlaces simbólicos (*ReparsePoint*) y carpetas ocultas o de sistema.
   - Envía los archivos marcados a la Papelera de Reciclaje mediante `Microsoft.VisualBasic.FileIO.FileSystem::DeleteFile(..., SendToRecycleBin)`.
   - Registra cada acción de limpieza en `%LOCALAPPDATA%\WinDupe\Logs\deleted_audit.jsonl` y `audit_history.log`, y errores críticos en `last_error.log`.

---

## Estructura del proyecto

```text
WinDupe/
├── bootstrap.ps1          # Lanzador Zero-Install volátil (sin UAC)
├── WinDupe.ps1            # Orquestador principal (GUI WPF + CLI)
├── LICENSE                # Licencia MIT (olshhhh)
├── README.md              # Documentación técnica
├── Core/
│   ├── WinDupeEngine.cs   # Motor C# de 3 fases + P/Invoke NTFS + ViewModel WPF
│   ├── ScannerService.ps1 # Compilación Add-Type y RunspacePool
│   ├── Guardrails.ps1     # Bloqueo de rutas del sistema y helpers
│   ├── RecycleAudit.ps1   # Papelera segura y logs de auditoría/error
│   └── CliRunner.ps1      # Modo consola (-Cli) y reporte de espacio
├── UI/
│   └── MainWindow.xaml    # Interfaz oscura WPF/XAML
└── Data/
    └── FileCategories.json# Extensiones por categoría y exclusiones
```
