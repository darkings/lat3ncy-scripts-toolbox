# Probe OpenCode Go endpoints: deepseek-v4-flash (completions) + muse-spark-1.2-contributor (responses)
# Go correct endpoint: https://opencode.ai/zen/go/v1 (catalog: pi-ai/dist/providers/opencode-go.js)
# muse-spark uses openai-responses -> /v1/responses, 403 RegionError = limited regions per Go docs
$ErrorActionPreference = 'Stop'

$text = Get-Content -Raw -Encoding UTF8 'C:\Users\Jie\.dsh\.credentials.yaml'
$m = [regex]::Match($text, '(?m)^\s*OPENCODE_GO_API_KEY\s*:\s*["'']?([^"''\r\n]+)')
$key = $m.Groups[1].Value.Trim()
if (-not $key)
{ Write-Host 'no key'; exit 1 }

$authHeader = "Authorization: Bearer $key"
$jsonHeader = 'Content-Type: application/json'

Write-Host '== GET /zen/go/v1/models =='
$resp = curl.exe -s https://opencode.ai/zen/go/v1/models -H $authHeader --max-time 20 2>$null
try {
  $j = $resp | ConvertFrom-Json -ErrorAction Stop
  Write-Host ("  models: {0}" -f $j.data.Count)
  $hasMuse = $j.data.id -contains 'muse-spark-1.2-contributor'
  Write-Host ("  has muse-spark-1.2-contributor: {0}" -f $hasMuse)
} catch { Write-Host $resp.Substring(0,[Math]::Min(800,$resp.Length)) }

$bases = @(
  'https://opencode.ai/zen/go/v1',
  'https://opencode.ai/zen/v1',
  'https://opencode.ai/go/v1',
  'https://opencode.ai/v1',
  'https://api.opencode.ai/zen/go/v1',
  'https://api.opencode.ai/v1'
)

$chatBody = '{"model":"deepseek-v4-flash","max_tokens":16,"messages":[{"role":"user","content":"ping"}]}'
$responsesBody = '{"model":"muse-spark-1.2-contributor","input":[{"role":"user","content":[{"type":"input_text","text":"Reply with exactly: OK"}]}],"max_output_tokens":16}'

foreach ($b in $bases)
{
  $url = "$b/chat/completions"
  $out = curl.exe -s -w "|%{http_code}" -X POST $url -H $authHeader -H $jsonHeader -d $chatBody --max-time 20 2>$null
  $parts = $out -split '\|'
  Write-Host ("POST {0} -> {1}" -f $url, $parts[-1])
  if ($parts[-1] -match '^2\d\d$')
  {
    Write-Host ("  ok: {0}" -f $parts[0].Substring(0,[Math]::Min(300,$parts[0].Length)))
  } elseif ($parts[0] -match 'RegionError')
  {
    Write-Host '  RegionError: model not available in your country (Muse Spark limited regions)'
  } elseif ($parts[-1] -match '^5\d\d$')
  {
    Write-Host ("  server error: {0}" -f $parts[0].Substring(0,[Math]::Min(300,$parts[0].Length)))
  }
}

Write-Host ''
Write-Host '== POST /zen/go/v1/responses (muse-spark-1.2-contributor) =='
$url = 'https://opencode.ai/zen/go/v1/responses'
$out = curl.exe -s -w "|%{http_code}" -X POST $url -H $authHeader -H $jsonHeader -d $responsesBody --max-time 20 2>$null
$parts = $out -split '\|'
Write-Host ("POST {0} -> {1}" -f $url, $parts[-1])
$bodyPreview = $parts[0].Substring(0,[Math]::Min(600,$parts[0].Length))
Write-Host ("  body: {0}" -f $bodyPreview)
if ($parts[0] -match 'RegionError')
{
  Write-Host '  -> RegionError as above, not a config error, Meta geographic restriction'
} elseif ($parts[-1] -match '^2\d\d$')
{
  Write-Host '  -> success: Muse Spark reachable (even if incomplete due to max_output_tokens)'
}
