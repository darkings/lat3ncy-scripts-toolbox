# Opt-in synthetic API/history test. Never reads unrelated notification content.
$ErrorActionPreference='Stop'
$appId='{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
$tag=[guid]::NewGuid().ToString('N').Substring(0,16)
$group='tbx-validation'
$posted=$false;$found=$false;$setting='unknown';$errorType='none';$hresult=0;$cleaned=$false;$phase='types'
try {
    $null=[Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime]
    $null=[Windows.Data.Xml.Dom.XmlDocument,Windows.Data.Xml.Dom.XmlDocument,ContentType=WindowsRuntime]
    $phase='xml';$xml=[Windows.Data.Xml.Dom.XmlDocument]::new()
    $xml.LoadXml('<toast><visual><binding template="ToastGeneric"><text>Toolbox OCR validation</text><text>Fixed synthetic fixture; no banner.</text></binding></visual></toast>')
    $toast=[Windows.UI.Notifications.ToastNotification]::new($xml)
    $toast.Tag=$tag;$toast.Group=$group;$toast.SuppressPopup=$true
    $phase='notifier';$notifier=[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId)
    $setting=[string]$notifier.Setting
    $phase='show';$notifier.Show($toast);$posted=$true
    $phase='history'
    for($i=0;$i -lt 20;$i++) {
        foreach($item in [Windows.UI.Notifications.ToastNotificationManager]::History.GetHistory($appId)) {
            if($item.Tag -eq $tag -and $item.Group -eq $group){$found=$true}
        }
        if($found){break}
        Start-Sleep -Milliseconds 100
    }
} catch {
    $probeException=$_.Exception
    while($probeException.InnerException){$probeException=$probeException.InnerException}
    $errorType=$probeException.GetType().Name;$hresult=$probeException.HResult
} finally {
    if($posted){try{[Windows.UI.Notifications.ToastNotificationManager]::History.Remove($tag,$group,$appId);$cleaned=$true}catch{}}
}
[Console]::WriteLine("posted=$posted`nfound=$found`nsetting=$setting`nphase=$phase`nerror_type=$errorType`nhresult=$hresult`ncleaned=$cleaned")
