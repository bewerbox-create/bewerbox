<#
.SYNOPSIS
    Prüft alle URLs einer (WordPress-)Sitemap auf SEO-Grundlagen.

.DESCRIPTION
    Liest eine Sitemap oder einen Sitemap-Index (Yoast, Rank Math, wp-sitemap.xml)
    rekursiv ein und prüft jede URL:
      - HTTP-Status (ohne Weiterleitungen zu folgen) und Ziel einer Weiterleitung
      - noindex im X-Robots-Tag-Header oder im <meta name="robots">
      - Canonical-Tag vorhanden und zeigt auf dieselbe URL
      - <title> vorhanden, Länge des Titels und der Meta-Description
      - Antwortzeit
    Ergebnis: Übersicht in der Konsole + CSV-Datei (Semikolon, öffnet direkt in Excel).

    Läuft unter Windows PowerShell 5.1 und PowerShell 7+.

.EXAMPLE
    .\Check-Sitemap.ps1 -SitemapUrl https://bewerbox.de/sitemap_index.xml

.EXAMPLE
    # Nur Magazin-Artikel prüfen, 300 ms Pause zwischen den Anfragen
    .\Check-Sitemap.ps1 -SitemapUrl https://bewerbox.de/sitemap_index.xml -Filter '/magazin/' -DelayMs 300

.EXAMPLE
    # Falls Skripte blockiert sind:
    powershell -ExecutionPolicy Bypass -File .\Check-Sitemap.ps1 -SitemapUrl https://bewerbox.de/wp-sitemap.xml
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SitemapUrl,

    # Nur URLs prüfen, die diesen Text enthalten (z. B. '/magazin/')
    [string]$Filter = '',

    # Pause zwischen Anfragen, um den Server zu schonen
    [int]$DelayMs = 200,

    # Maximal so viele URLs prüfen (0 = alle)
    [int]$MaxUrls = 0,

    [int]$TimeoutSec = 30,

    # Ab dieser Antwortzeit gilt eine Seite als langsam
    [int]$SlowMs = 3000,

    [string]$OutFile = (Join-Path (Get-Location) ("sitemap-check_{0}.csv" -f (Get-Date -Format 'yyyy-MM-dd_HHmm')))
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 nutzt standardmäßig kein TLS 1.2
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Add-Type -AssemblyName System.Net.Http
}

# HttpClient statt Invoke-WebRequest: folgt Weiterleitungen nicht und wirft
# bei 3xx/4xx/5xx keine Fehler, verhält sich in PS 5.1 und 7 gleich.
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.AllowAutoRedirect = $false
$handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
$client.DefaultRequestHeaders.UserAgent.ParseAdd('Mozilla/5.0 (compatible; SitemapCheck/1.0)')

function Invoke-Get([string]$Url) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $resp = $client.GetAsync($Url).GetAwaiter().GetResult()
        $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $sw.Stop()
        [pscustomobject]@{ Response = $resp; Body = $body; Ms = $sw.ElapsedMilliseconds; Error = $null }
    }
    catch {
        $sw.Stop()
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
        [pscustomobject]@{ Response = $null; Body = $null; Ms = $sw.ElapsedMilliseconds; Error = $msg }
    }
}

function Get-HeaderValue($Response, [string]$Name) {
    $values = $null
    if ($Response.Headers.TryGetValues($Name, [ref]$values)) { return ($values -join ', ') }
    if ($Response.Content.Headers.TryGetValues($Name, [ref]$values)) { return ($values -join ', ') }
    return ''
}

# Wert eines Attributs aus einem einzelnen HTML-Tag, egal in welcher Reihenfolge
function Get-Attr([string]$Tag, [string]$Name) {
    $m = [regex]::Match($Tag, '\b' + $Name + '\s*=\s*(?:"([^"]*)"|''([^'']*)''|([^\s>]+))', 'IgnoreCase')
    if (-not $m.Success) { return $null }
    foreach ($i in 1..3) { if ($m.Groups[$i].Success) { return [Net.WebUtility]::HtmlDecode($m.Groups[$i].Value).Trim() } }
}

function Get-SitemapUrls([string]$Url, [System.Collections.Generic.HashSet[string]]$Seen) {
    if (-not $Seen.Add($Url)) { return }
    Write-Host "  Lese Sitemap: $Url" -ForegroundColor DarkGray
    $r = Invoke-Get $Url
    if ($r.Error) { Write-Warning "Sitemap nicht erreichbar: $Url ($($r.Error))"; return }
    $code = [int]$r.Response.StatusCode
    if ($code -ge 300 -and $code -lt 400 -and $r.Response.Headers.Location) {
        $target = (New-Object Uri([Uri]$Url, $r.Response.Headers.Location)).AbsoluteUri
        Write-Warning "Sitemap leitet weiter ($code) -> $target"
        Get-SitemapUrls $target $Seen
        return
    }
    if ($code -ne 200) { Write-Warning "Sitemap liefert HTTP $code`: $Url"; return }

    try { [xml]$xml = $r.Body } catch { Write-Warning "Sitemap ist kein gültiges XML: $Url"; return }

    # PowerShell ignoriert beim Punkt-Zugriff den XML-Namespace
    if ($xml.sitemapindex) {
        foreach ($s in @($xml.sitemapindex.sitemap)) { Get-SitemapUrls ([string]$s.loc).Trim() $Seen }
    }
    elseif ($xml.urlset) {
        foreach ($u in @($xml.urlset.url)) { ([string]$u.loc).Trim() }
    }
    else {
        Write-Warning "Unbekanntes Sitemap-Format: $Url"
    }
}

function Test-Page([string]$Url) {
    $r = Invoke-Get $Url
    $row = [ordered]@{
        URL             = $Url
        Status          = ''
        Weiterleitung   = ''
        Noindex         = ''
        Canonical       = ''
        CanonicalOK     = ''
        Title           = ''
        TitleLaenge     = ''
        DescLaenge      = ''
        Ms              = $r.Ms
        Probleme        = ''
    }
    $issues = New-Object System.Collections.Generic.List[string]

    if ($r.Error) {
        $row.Status = 'FEHLER'
        $issues.Add("Nicht erreichbar: $($r.Error)")
        $row.Probleme = $issues -join ' | '
        return [pscustomobject]$row
    }

    $resp = $r.Response
    $code = [int]$resp.StatusCode
    $row.Status = $code

    if ($code -ge 300 -and $code -lt 400) {
        if ($resp.Headers.Location) { $row.Weiterleitung = (New-Object Uri([Uri]$Url, $resp.Headers.Location)).AbsoluteUri }
        $issues.Add("Weiterleitung $code in der Sitemap (nur Ziel-URLs gehören hinein)")
    }
    elseif ($code -ne 200) {
        $issues.Add("HTTP $code")
    }

    $robotsHeader = Get-HeaderValue $resp 'X-Robots-Tag'
    $noindex = @()
    if ($robotsHeader -match 'noindex') { $noindex += 'Header' }

    $contentType = Get-HeaderValue $resp 'Content-Type'
    if ($code -eq 200 -and $contentType -match 'html') {
        $html = $r.Body

        foreach ($m in [regex]::Matches($html, '<meta\b[^>]*>', 'IgnoreCase')) {
            $name = Get-Attr $m.Value 'name'
            if ($name -match '^(robots|googlebot)$' -and (Get-Attr $m.Value 'content') -match 'noindex') { $noindex += 'Meta' }
            if ($name -eq 'description') { $row.DescLaenge = (Get-Attr $m.Value 'content').Length }
        }

        foreach ($m in [regex]::Matches($html, '<link\b[^>]*>', 'IgnoreCase')) {
            if ((Get-Attr $m.Value 'rel') -match '(^|\s)canonical(\s|$)') { $row.Canonical = Get-Attr $m.Value 'href'; break }
        }

        $t = [regex]::Match($html, '<title[^>]*>(.*?)</title>', 'IgnoreCase, Singleline')
        if ($t.Success) {
            $row.Title = ([Net.WebUtility]::HtmlDecode($t.Groups[1].Value) -replace '\s+', ' ').Trim()
            $row.TitleLaenge = $row.Title.Length
        }

        if (-not $row.Canonical) {
            $row.CanonicalOK = 'fehlt'
            $issues.Add('Canonical fehlt')
        }
        elseif ($row.Canonical.TrimEnd('/') -ieq $Url.TrimEnd('/')) {
            $row.CanonicalOK = 'ja'
        }
        else {
            $row.CanonicalOK = 'NEIN'
            $issues.Add("Canonical zeigt auf andere URL")
        }

        if (-not $row.Title) { $issues.Add('Title fehlt') }
        elseif ($row.TitleLaenge -gt 60) { $issues.Add("Title lang ($($row.TitleLaenge) Zeichen)") }

        if ($row.DescLaenge -eq '') { $issues.Add('Meta-Description fehlt') }
        elseif ($row.DescLaenge -gt 160) { $issues.Add("Description lang ($($row.DescLaenge) Zeichen)") }
    }

    if ($noindex) {
        $row.Noindex = ($noindex | Select-Object -Unique) -join '+'
        $issues.Add("NOINDEX ($($row.Noindex))")
    }
    if ($r.Ms -gt $SlowMs) { $issues.Add("Langsam ($($r.Ms) ms)") }

    $row.Probleme = $issues -join ' | '
    [pscustomobject]$row
}

# --- Ablauf -------------------------------------------------------------

Write-Host "`nSitemap wird gelesen..." -ForegroundColor Cyan
$seen = New-Object 'System.Collections.Generic.HashSet[string]'
$urls = @(Get-SitemapUrls $SitemapUrl $seen | Where-Object { $_ } | Select-Object -Unique)
Write-Host ("Gefunden: {0} URLs in {1} Sitemap(s)" -f $urls.Count, $seen.Count)

if ($Filter) {
    $urls = @($urls | Where-Object { $_ -like "*$Filter*" })
    Write-Host ("Nach Filter '{0}': {1} URLs" -f $Filter, $urls.Count)
}
if ($MaxUrls -gt 0 -and $urls.Count -gt $MaxUrls) { $urls = $urls[0..($MaxUrls - 1)] }
if ($urls.Count -eq 0) { Write-Warning 'Keine URLs zu prüfen.'; $client.Dispose(); return }

Write-Host "`nPrüfe Seiten..." -ForegroundColor Cyan
$results = New-Object System.Collections.Generic.List[object]
$i = 0
foreach ($u in $urls) {
    $i++
    Write-Progress -Activity 'Sitemap-Check' -Status "$i / $($urls.Count): $u" -PercentComplete ($i * 100 / $urls.Count)
    $res = Test-Page $u
    $results.Add($res)
    if ($res.Probleme) { Write-Host ("[{0}] {1}  ->  {2}" -f $res.Status, $u, $res.Probleme) -ForegroundColor Yellow }
    if ($DelayMs -gt 0 -and $i -lt $urls.Count) { Start-Sleep -Milliseconds $DelayMs }
}
Write-Progress -Activity 'Sitemap-Check' -Completed
$client.Dispose()

# UTF-8 mit BOM, damit Excel Umlaute richtig anzeigt
$encoding = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }
$results | Export-Csv -Path $OutFile -Delimiter ';' -NoTypeInformation -Encoding $encoding

# --- Zusammenfassung ----------------------------------------------------
$ok       = @($results | Where-Object { -not $_.Probleme }).Count
$not200   = @($results | Where-Object { $_.Status -ne 200 }).Count
$noindexN = @($results | Where-Object { $_.Noindex }).Count
$canonBad = @($results | Where-Object { $_.CanonicalOK -in 'NEIN', 'fehlt' }).Count
$timed    = @($results | Where-Object { $_.Ms -is [long] -or $_.Ms -is [int] })
$avgMs    = if ($timed.Count) { [math]::Round(($timed | Measure-Object Ms -Average).Average) } else { 0 }

Write-Host "`n===== Zusammenfassung =====" -ForegroundColor Cyan
Write-Host ("Geprüft:               {0}" -f $results.Count)
Write-Host ("Ohne Probleme:         {0}" -f $ok) -ForegroundColor Green
Write-Host ("Status nicht 200:      {0}" -f $not200) -ForegroundColor $(if ($not200) { 'Red' } else { 'Green' })
Write-Host ("NOINDEX:               {0}" -f $noindexN) -ForegroundColor $(if ($noindexN) { 'Red' } else { 'Green' })
Write-Host ("Canonical falsch:      {0}" -f $canonBad) -ForegroundColor $(if ($canonBad) { 'Yellow' } else { 'Green' })
Write-Host ("Ø Antwortzeit:         {0} ms" -f $avgMs)
Write-Host "`nCSV gespeichert: $OutFile`n" -ForegroundColor Cyan
