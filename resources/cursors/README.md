# 鼠标光标

本机 dark/light 切换用的 Cursor Concept 3 免费包。作者 [Jepri Creations](https://www.deviantart.com/jepricreations)。

## 目录

* `light/`：浅色方案（18 个 `.cur` / `.ani` + `Install.inf`）
* `dark/`：深色方案（同上）
* `Agreement.txt`：作者许可全文

`theme-scheduler` 不跑 `Install.inf`，只读这两个目录里的文件，写当前用户：

```text
HKCU\Control Panel\Cursors
```

再调用 `SPI_SETCURSORS` 刷新指针。

## 开关

`tools/theme-scheduler/config.toml`：

```toml
[cursor]
enabled = true
light_dir = ""
dark_dir = ""
light_scheme = "Cursor Concept 3 Light"
dark_scheme = "Cursor Concept 3 Dark"
```

当前已开启。`Set-Theme-Light.ps1` / `Set-Theme-Dark.ps1` 会随颜色模式换对应方案。目录留空则用本文件夹下的 `light` / `dark`。要关掉就把 `enabled` 改回 `false`。

## 许可

允许个人设备使用和个人修改。不允许重新分发光标包文件，不得冒充作者。必须保留作者信息与 DeviantArt 链接：

https://www.deviantart.com/jepricreations
