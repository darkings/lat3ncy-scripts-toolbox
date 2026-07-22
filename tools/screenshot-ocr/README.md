# Screenshot OCR

Windows 屏幕区域 OCR 工具：拖拽框选屏幕区域，按 `Esc` 取消；识别结果会自动复制到剪贴板，并显示成功、空结果或错误通知。

## 安装

安装 Python 依赖：

```powershell
python -m pip install pillow
```

Tesseract OCR 是由脚本通过子进程直接调用的原生依赖，不是 Python 包，需要单独安装：

```powershell
winget install UB-Mannheim.TesseractOCR
```

简体中文识别需要 `chi_sim.traineddata`。可在安装 Tesseract 时选择简体中文语言包，或从 Tesseract 官方 `tessdata` 仓库下载该文件并放入 Tesseract 安装目录的 `tessdata` 文件夹。也可以在本工具目录新建 `tessdata` 文件夹并放入所需 `.traineddata` 文件；只有当 `OCR_LANG` 请求的组合语言模型全部存在（例如 `chi_sim+eng` 同时具备两个文件）时才启用本地覆盖，否则继续使用系统 Tesseract 的默认模型目录。这些模型是外部依赖，不纳入本仓库。

## 启动

- `launch.bat`：在终端中运行，便于查看启动错误。
- `launch-hidden.ps1`：使用 `pythonw.exe`，或回退到 `pyw.exe -3`，隐藏窗口运行。

若 PowerShell 执行策略阻止脚本，可从终端运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\launch-hidden.ps1
```

## Raycast 配置

1. 在 Raycast 中创建 Script Command、快捷方式或 Quicklink。
2. 目标设为 `launch.bat`；若希望静默启动，则运行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<本目录>\launch-hidden.ps1"`。
3. 分配快捷键。触发后拖拽框选 OCR 区域，结果会复制到剪贴板。

## 环境变量

- `OCR_LANG`：Tesseract 语言，默认 `chi_sim+eng`。
- `OCR_PSM`：首选页面分割模式，默认 `6`；无结果时还会依次尝试 `7`、`11`、`3`。
- `TESSERACT_CMD`：`tesseract.exe` 的完整路径。未设置时会检查 Program Files 的常见安装目录，最后从 `PATH` 查找。

例如：

```powershell
setx OCR_LANG "chi_sim+eng"
setx OCR_PSM "6"
setx TESSERACT_CMD "C:\Program Files\Tesseract-OCR\tesseract.exe"
```

## 调试与故障排查

每次运行会在本目录生成调试产物：`last_ocr.log`（Tesseract 路径、参数、退出码和错误信息）、`last_capture.png`（原始截图）和 `last_processed.png`（灰度、自动对比度、2 倍放大、增强对比度和锐化后的图像）。这些文件不会提交到仓库。

- 提示找不到 Tesseract：确认已安装，并重开终端/Raycast 让 `PATH` 生效；或设置 `TESSERACT_CMD`。
- 中文识别失败：确认 `chi_sim.traineddata` 已安装，并检查 `OCR_LANG`。
- 识别为空或不准：查看两张调试图，重新选择更清晰、更紧凑的区域，或尝试其他 `OCR_PSM`。
- Tesseract 执行失败：查看 `last_ocr.log` 中的 `stderr` 和实际命令。
