param(
    [string]$Title = "Lat3ncy Toolbox",
    [string]$Message = ""
)

try {
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

    $escapedT = [System.Security.SecurityElement]::Escape($Title)
    $escapedM = [System.Security.SecurityElement]::Escape($Message)

    $xml = [Windows.Data.Xml.Dom.XmlDocument]::new()
    $toastXml = @"
<toast duration="short">
    <visual>
        <binding template="ToastGeneric">
            <text>$escapedT</text>
            <text>$escapedM</text>
        </binding>
    </visual>
</toast>
"@
    $xml.LoadXml($toastXml)
    $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
    # 固定 Tag/Group，新结果覆盖旧结果，避免连按把 Toast 排成一串。
    $toast.Tag = "lat3ncy-toolbox"
    $toast.Group = "lat3ncy-toolbox"
    $appId = "{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe"
    try {
        [Windows.UI.Notifications.ToastNotificationManager]::History.RemoveGroup("lat3ncy-toolbox", $appId)
    } catch {}
    $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId)
    $notifier.Show($toast)
} catch {}
