# Fixed stdin JSON protocol. Text is data, never a command or argument.
$ErrorActionPreference = 'Stop'
$voice = $null
try {
    [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    $request = [Console]::In.ReadToEnd() | ConvertFrom-Json
    if ($request.lang -notin @('en', 'zh') -or [string]::IsNullOrWhiteSpace($request.text)) {
        throw 'Invalid synthesis input'
    }
    Add-Type -AssemblyName System.Speech
    $voice = New-Object System.Speech.Synthesis.SpeechSynthesizer
    $available = @($voice.GetInstalledVoices() | Where-Object { $_.Enabled -and $_.VoiceInfo.Culture.TwoLetterISOLanguageName -eq $request.lang })
    if (-not $available.Count) { throw 'No matching installed language' }
    $target = @($available | Where-Object { $_.VoiceInfo.Name.StartsWith([string]$request.voice, [StringComparison]::OrdinalIgnoreCase) })
    if (-not $target.Count) { $target = $available }
    $selected = $target[0].VoiceInfo
    $voice.SelectVoice($selected.Name)
    # XmlDocument escapes both text and attributes; selections cannot inject SSML.
    $document = [xml]'<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" />'
    $document.DocumentElement.SetAttribute('lang', 'http://www.w3.org/XML/1998/namespace', $selected.Culture.Name) | Out-Null
    $prosody = $document.CreateElement('prosody', 'http://www.w3.org/2001/10/synthesis')
    $prosody.SetAttribute('rate', [string]$request.rate)
    $prosody.SetAttribute('pitch', [string]$request.pitch)
    $prosody.SetAttribute('volume', [string]$request.volume)
    $prosody.InnerText = [string]$request.text
    $document.DocumentElement.AppendChild($prosody) | Out-Null
    $voice.SetOutputToWaveFile([string]$request.output)
    $voice.SpeakSsml($document.OuterXml)
    $voice.SetOutputToNull()
    [Console]::Out.WriteLine((@{voice=$selected.Name; culture=$selected.Culture.Name} | ConvertTo-Json -Compress))
} catch {
    [Console]::Error.WriteLine('SAPI file synthesis failed: ' + $_.Exception.GetType().Name)
    exit 1
} finally {
    if ($voice) { $voice.Dispose() }
}
