# MulticamDesdeSincro.ps1  v1.3
# Arma una Multicamera Source Sequence por cada grupo de una secuencia de sincro,
# escribiendo directo en una COPIA del .prproj (el original no se toca).
# Uso: arrastrar el .prproj (con Premiere cerrado) sobre MulticamDesdeSincro.bat

param([string]$ProjectPath, [string]$SequenceName)

$ErrorActionPreference = 'Stop'
# compilado como .exe (ps2exe) no hay .bat que haga "pause": la ventana se cerraria sola
$script:IsExe = ([System.Diagnostics.Process]::GetCurrentProcess().ProcessName -notmatch '^(powershell|pwsh)$')
function Pause-IfExe { if ($script:IsExe) { Write-Host ''; [void](Read-Host 'Enter para cerrar') } }
trap { Write-Host ''; Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red; Pause-IfExe; exit 1 }
$script:Log = New-Object System.Collections.Generic.List[string]
function Say([string]$t) { Write-Host $t; $script:Log.Add($t) }
$script:warned = @{}
function Warn([string]$t) { if ($script:warned.ContainsKey($t)) { return }; $script:warned[$t] = 1; Write-Host ("  ! " + $t) -ForegroundColor Yellow; $script:Log.Add("  ! " + $t) }

$TINY_FRAMES = 50          # pedazos mas cortos que esto, con otra sincro, se ignoran
$DRIFT_FRAMES = 25         # dos pedazos de un archivo con sincros que difieren hasta esto = correccion de drift (se respetan como estan)

# ---------------------------------------------------------------- abrir
if (-not $ProjectPath) { $ProjectPath = Read-Host 'Arrastra el .prproj aca y Enter' }
$ProjectPath = $ProjectPath.Trim().Trim('"', "'")
# Terminal de Mac: al arrastrar un archivo escapa los espacios ("Mi\ Proyecto.prproj")
if (-not (Test-Path -LiteralPath $ProjectPath) -and $ProjectPath -match '\\[ ()&\[\]]') { $ProjectPath = $ProjectPath -replace '\\(.)', '$1' }
if (-not (Test-Path -LiteralPath $ProjectPath)) { throw "No encuentro el archivo: $ProjectPath" }
$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path

Say "Leyendo $ProjectPath ..."
$fs = [System.IO.File]::OpenRead($ProjectPath)
try {
    $gz = New-Object System.IO.Compression.GZipStream($fs, [System.IO.Compression.CompressionMode]::Decompress)
    $sr = New-Object System.IO.StreamReader($gz, [System.Text.Encoding]::UTF8)
    $xmlText = $sr.ReadToEnd()
    $sr.Close()
} finally { $fs.Close() }

$doc = New-Object System.Xml.XmlDocument
$doc.PreserveWhitespace = $true
$doc.LoadXml($xmlText)
$xmlText = $null
$rootEl = $doc.DocumentElement

# ---------------------------------------------------------------- indice
$byId  = New-Object 'System.Collections.Generic.Dictionary[string,System.Xml.XmlElement]'
$byUid = New-Object 'System.Collections.Generic.Dictionary[string,System.Xml.XmlElement]'
[long]$maxId = 0
foreach ($n in $rootEl.ChildNodes) {
    if ($n.NodeType -ne 'Element') { continue }
    $a = $n.GetAttribute('ObjectID')
    if ($a) { $byId[$a] = $n; $v = [long]$a; if ($v -gt $maxId) { $maxId = $v } }
    $u = $n.GetAttribute('ObjectUID')
    if ($u) { $byUid[$u] = $n }
}
$script:nextId = $maxId + 1

function Ref([System.Xml.XmlNode]$n) {
    if ($null -eq $n) { return $null }
    $r = $n.GetAttribute('ObjectRef'); if ($r) { return $byId[$r] }
    $r = $n.GetAttribute('ObjectURef'); if ($r) { return $byUid[$r] }
    return $null
}
function Txt([System.Xml.XmlNode]$n, [string]$path) { $x = $n.SelectSingleNode($path); if ($x) { return $x.InnerText } return $null }
function LongOr0($s) { if ($s) { return [long]::Parse($s) } return [long]0 }

# ---------------------------------------------------------------- clonado
$GuidRx = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$script:newEls = New-Object System.Collections.Generic.List[System.Xml.XmlElement]

function Add-Obj([System.Xml.XmlElement]$el) {
    $id = $el.GetAttribute('ObjectID'); if ($id) { $byId[$id] = $el }
    $u = $el.GetAttribute('ObjectUID'); if ($u) { $byUid[$u] = $el }
    $script:newEls.Add($el)
}

# Clona un objeto y todo lo que referencia, salvo los tags de $Stop (se comparten).
function Clone-Obj([System.Xml.XmlElement]$el, [hashtable]$Stop, [scriptblock]$Prune) {
    $map = @{}
    return (Clone-Rec $el $Stop $map $Prune $true)
}
function Clone-Rec([System.Xml.XmlElement]$el, [hashtable]$Stop, [hashtable]$map, [scriptblock]$Prune, [bool]$top) {
    $oldKey = $el.GetAttribute('ObjectID'); if (-not $oldKey) { $oldKey = 'u:' + $el.GetAttribute('ObjectUID') }
    if ($map.ContainsKey($oldKey)) { return $map[$oldKey] }
    $new = [System.Xml.XmlElement]$el.CloneNode($true)
    if ($el.GetAttribute('ObjectID')) { $new.SetAttribute('ObjectID', [string]$script:nextId); $script:nextId++ }
    else { $new.SetAttribute('ObjectUID', [guid]::NewGuid().ToString()) }
    $map[$oldKey] = $new
    if ($top -and $Prune) { & $Prune $new }
    foreach ($g in @($new.SelectNodes('.//ID|.//ClipID'))) {
        if ($g.InnerText -match $GuidRx) { $g.InnerText = [guid]::NewGuid().ToString() }
    }
    foreach ($r in @($new.SelectNodes('.//*[@ObjectRef or @ObjectURef]'))) {
        $tgt = Ref $r
        if ($null -eq $tgt) { continue }
        if ($Stop.ContainsKey($tgt.LocalName)) { continue }
        $c = Clone-Rec $tgt $Stop $map $null $false
        if ($r.GetAttribute('ObjectRef')) { $r.SetAttribute('ObjectRef', $c.GetAttribute('ObjectID')) }
        else { $r.SetAttribute('ObjectURef', $c.GetAttribute('ObjectUID')) }
    }
    Add-Obj $new
    return $new
}

function Set-Child([System.Xml.XmlElement]$parent, [string]$name, [string]$value, [System.Xml.XmlNode]$before) {
    $c = $parent.SelectSingleNode($name)
    if (-not $c) {
        $c = $doc.CreateElement($name)
        if ($before) { [void]$parent.InsertBefore($c, $before) } else { [void]$parent.AppendChild($c) }
    }
    $c.InnerText = $value
}
function Remove-Child([System.Xml.XmlElement]$parent, [string]$name) {
    foreach ($c in @($parent.SelectNodes($name))) { [void]$parent.RemoveChild($c) }
}
function Set-List([System.Xml.XmlElement]$container, [string]$itemTag, [string]$attr, $values) {
    foreach ($c in @($container.SelectNodes($itemTag))) { [void]$container.RemoveChild($c) }
    $i = 0
    foreach ($v in $values) {
        $e = $doc.CreateElement($itemTag)
        $e.SetAttribute('Index', [string]$i); $e.SetAttribute($attr, $v)
        [void]$container.AppendChild($e); $i++
    }
}

# ---------------------------------------------------------------- secuencias
$seqs = @($byUid.Values | Where-Object { $_.LocalName -eq 'Sequence' })
function Is-Multicam-Seq($s) { return [bool]$s.SelectSingleNode('Node/Properties/Source.Monitor.Multicam.SwitchOnMulticamName') }
function Is-Merged-Seq($s) { return [bool]$s.SelectSingleNode('Node/Properties/BE.Sequence.IsMergedClip') }

$syncSeq = $null
if ($SequenceName) {
    $syncSeq = $seqs | Where-Object { (Txt $_ 'Name') -eq $SequenceName } | Select-Object -First 1
    if (-not $syncSeq) { throw "No hay ninguna secuencia llamada '$SequenceName'" }
} else {
    # siempre se elige: lista de secuencias comunes (sin multicam ni merged), las SYNC primero
    $list = @($seqs | Where-Object { -not (Is-Multicam-Seq $_) -and -not (Is-Merged-Seq $_) } |
        Sort-Object @{ Expression = { -not ((Txt $_ 'Name') -match 'SYNC') } }, @{ Expression = { Txt $_ 'Name' } })
    if ($list.Count -eq 0) { throw 'El proyecto no tiene secuencias.' }
    $def = 1
    Write-Host ''
    Write-Host '  Secuencias del proyecto:'
    for ($i = 0; $i -lt $list.Count; $i++) { Write-Host ("  {0,3}) {1}" -f ($i + 1), (Txt $list[$i] 'Name')) }
    Write-Host ''
    while (-not $syncSeq) {
        $ans = Read-Host ("Numero de la secuencia de sincro [Enter = {0}]" -f (Txt $list[$def - 1] 'Name'))
        if (-not $ans) { $syncSeq = $list[$def - 1]; break }
        $k = 0
        if ([int]::TryParse($ans.Trim(), [ref]$k) -and $k -ge 1 -and $k -le $list.Count) { $syncSeq = $list[$k - 1] }
        else { Write-Host '  Numero invalido, proba de nuevo.' -ForegroundColor Yellow }
    }
}
$syncName = Txt $syncSeq 'Name'
Say "Secuencia de sincro: $syncName"

# plantilla: una multicam ya existente en el proyecto
# plantilla: una multicam hecha a mano; se prefiere una con audio adaptativo (Multichannel)
function Get-McInfo($m) {
    $info = @{ MC = $m; V = $null; A = $null; AIdx = -1; Seq = $null; Groups = @{}; Adaptive = $false; Ok = $false }
    $i = 0
    foreach ($c in $m.SelectNodes('Clips/Clip')) {
        $o = Ref $c
        if ($o.LocalName -eq 'VideoClip') { $info.V = $o } elseif ($o.LocalName -eq 'AudioClip') { $info.A = $o; $info.AIdx = $i }
        $i++
    }
    if (-not $info.V -or -not $info.A) { return $info }
    $vs = Ref $info.V.SelectSingleNode('Clip/Source'); if (-not $vs -or $vs.LocalName -ne 'VideoSequenceSource') { return $info }
    $info.Seq = Ref $vs.SelectSingleNode('SequenceSource/Sequence'); if (-not $info.Seq) { return $info }
    foreach ($tg in $info.Seq.SelectNodes('TrackGroups/TrackGroup')) { $g = Ref $tg.SelectSingleNode('Second'); if ($g) { $info.Groups[$g.LocalName] = $g } }
    $ag = $info.Groups['AudioTrackGroup']; $vg = $info.Groups['VideoTrackGroup']
    if (-not $ag -or -not $vg) { return $info }
    if (-not $vg.SelectSingleNode('TrackGroup/Tracks/Track') -or -not $ag.SelectSingleNode('TrackGroup/Tracks/Track')) { return $info }
    $mix = Ref $ag.SelectSingleNode('MasterTrack')
    if ($mix) { $mc = Ref $mix.SelectSingleNode('AudioTrack/ComponentOwner/Components'); if ($mc -and (Txt $mc 'ChannelType') -eq '3') { $info.Adaptive = $true } }
    $info.Ok = $true
    return $info
}
$tmpl = $null; $tmplAny = $null
foreach ($m in $byUid.Values) {
    if ($m.LocalName -ne 'MasterClip') { continue }
    if ((Txt $m 'Node/Properties/Source.Monitor.Multicam.Enabled') -ne 'true') { continue }
    $inf = Get-McInfo $m
    if (-not $inf.Ok) { continue }
    if (-not $tmplAny) { $tmplAny = $inf }
    if ($inf.Adaptive) { $tmpl = $inf; break }
}
if (-not $tmpl) { $tmpl = $tmplAny }
if (-not $tmpl) { throw 'El proyecto no tiene ninguna multicam armada a mano para usar de modelo. Arma una cualquiera y volve a correr.' }
$tmplMC = $tmpl.MC; $tmplVClip = $tmpl.V; $tmplAClip = $tmpl.A; $tmplSeq = $tmpl.Seq; $tmplGroups = $tmpl.Groups
if (-not $tmpl.Adaptive) { Warn 'Ninguna multicam del proyecto tiene audio Multichannel (adaptativo); uso otra de modelo y el ruteo de audio puede no quedar bien.' }
$tmplVTrack = Ref $tmplGroups['VideoTrackGroup'].SelectSingleNode('TrackGroup/Tracks/Track')
$tmplATrack = Ref $tmplGroups['AudioTrackGroup'].SelectSingleNode('TrackGroup/Tracks/Track')
$tmplPI = $null
foreach ($p in $byUid.Values) { if ($p.LocalName -eq 'ClipProjectItem' -and $p.SelectSingleNode('MasterClip').GetAttribute('ObjectURef') -eq $tmplMC.GetAttribute('ObjectUID')) { $tmplPI = $p; break } }
Say ("Modelo de multicam: " + (Txt $tmplMC 'Name'))

# ---------------------------------------------------------------- leer la sincro
$vGroup = $null; $aGroup = $null
foreach ($tg in $syncSeq.SelectNodes('TrackGroups/TrackGroup')) { $g = Ref $tg.SelectSingleNode('Second'); if ($g.LocalName -eq 'VideoTrackGroup') { $vGroup = $g } elseif ($g.LocalName -eq 'AudioTrackGroup') { $aGroup = $g } }
[long]$FRAME = LongOr0 (Txt $vGroup 'TrackGroup/FrameRate')
$tiny = $TINY_FRAMES * $FRAME

$items = New-Object System.Collections.Generic.List[object]
foreach ($kind in @('V', 'A')) {
    $grp = $vGroup; if ($kind -eq 'A') { $grp = $aGroup }
    $ti = 0
    foreach ($t in $grp.SelectNodes('TrackGroup/Tracks/Track')) {
        $track = Ref $t
        foreach ($it in $track.SelectNodes('ClipTrack/ClipItems/TrackItems/TrackItem')) {
            $item = Ref $it
            $start = LongOr0 (Txt $item 'ClipTrackItem/TrackItem/Start')
            $end = LongOr0 (Txt $item 'ClipTrackItem/TrackItem/End')
            $sub = Ref $item.SelectSingleNode('ClipTrackItem/SubClip')
            if (-not $sub) { continue }
            $clip = Ref $sub.SelectSingleNode('Clip')
            $src = Ref $clip.SelectSingleNode('Clip/Source')
            if ($src.LocalName -notmatch 'MediaSource') { continue }   # secuencias anidadas, etc.
            $inP = LongOr0 (Txt $clip 'Clip/InPoint')
            $dur = LongOr0 (Txt $src 'OriginalDuration')
            $dur = $dur - ($dur % $FRAME)
            $media = Ref $src.SelectSingleNode('MediaSource/Media')
            $items.Add([pscustomobject]@{
                Kind = $kind; Track = $ti; El = $item; Start = $start; End = $end; In = $inP
                Off = $start - $inP; Dur = $dur; MC = $sub.SelectSingleNode('MasterClip').GetAttribute('ObjectURef')
                Name = Txt $sub 'Name'; Media = $media; Shift = [long]0; Drop = $false
            })
        }
        $ti++
    }
}
Say ("Clips en la sincro: {0} de imagen, {1} de sonido" -f @($items | Where-Object Kind -eq 'V').Count, @($items | Where-Object Kind -eq 'A').Count)

# ---------------------------------------------------------------- agrupar
$sorted = @($items | Sort-Object Start, End)
$groups = New-Object System.Collections.Generic.List[object]
$cur = $null; [long]$curEnd = -1
foreach ($it in $sorted) {
    if ($null -eq $cur -or $it.Start -ge $curEnd) { $cur = New-Object System.Collections.Generic.List[object]; $groups.Add($cur); $curEnd = $it.End }
    $cur.Add($it); if ($it.End -gt $curEnd) { $curEnd = $it.End }
}
# unir grupos que comparten un archivo de imagen
$changed = $true
while ($changed) {
    $changed = $false
    for ($i = 0; $i -lt $groups.Count -and -not $changed; $i++) {
        $vi = @($groups[$i] | Where-Object Kind -eq 'V' | ForEach-Object MC)
        for ($j = $i + 1; $j -lt $groups.Count; $j++) {
            $shared = @($groups[$j] | Where-Object { $_.Kind -eq 'V' -and $vi -contains $_.MC })
            if ($shared.Count -gt 0) { foreach ($x in $groups[$j]) { $groups[$i].Add($x) }; $groups.RemoveAt($j); $changed = $true; break }
        }
    }
}

# sonidos cortados entre varios grupos (ej. un wav largo cortado debajo de cada toma)
$audioGroups = @{}
for ($i = 0; $i -lt $groups.Count; $i++) {
    foreach ($mcId in @($groups[$i] | Where-Object Kind -eq 'A' | ForEach-Object MC | Select-Object -Unique)) {
        if (-not $audioGroups.ContainsKey($mcId)) { $audioGroups[$mcId] = 0 }
        $audioGroups[$mcId]++
    }
}

# ---------------------------------------------------------------- construir
function MinL($list, [string]$prop) { [long]$m = [long]::MaxValue; foreach ($x in $list) { if ([long]$x.$prop -lt $m) { $m = [long]$x.$prop } }; return $m }
function MaxL($list, [string]$prop) { [long]$m = [long]::MinValue; foreach ($x in $list) { if ([long]$x.$prop -gt $m) { $m = [long]$x.$prop } }; return $m }
function Overlap($a, $b) { $s = [math]::Max($a.Start, $b.Start); $e = [math]::Min($a.End, $b.End); return [long]($e - $s) }

$stopShared = @{ 'MasterClip' = 1; 'Media' = 1 }
$stopTmpl = @{ 'MasterClip' = 1; 'Media' = 1; 'Sequence' = 1; 'VideoClipTrack' = 1; 'AudioClipTrack' = 1; 'VideoClipTrackItem' = 1; 'AudioClipTrackItem' = 1 }
$pruneTrack = { param($n) foreach ($x in @($n.SelectNodes('ClipTrack/ClipItems/TrackItems/TrackItem'))) { [void]$x.ParentNode.RemoveChild($x) } }
$pruneGroup = { param($n) foreach ($x in @($n.SelectNodes('TrackGroup/Tracks/Track'))) { [void]$x.ParentNode.RemoveChild($x) } }

$projEl = Ref $rootEl.SelectSingleNode('Project')
$projNext = $projEl.SelectSingleNode('NextID')
[long]$script:nextPI = [long]::Parse($projNext.InnerText)

$newPIs = New-Object System.Collections.Generic.List[string]
$num = 0
foreach ($g in ($groups | Sort-Object { MinL $_ 'Start' })) {
    $vids = @($g | Where-Object Kind -eq 'V')
    $gStart = MinL $g 'Start'
    $tc = [TimeSpan]::FromSeconds([double]$gStart / 254016000000)
    if ($vids.Count -eq 0) { Warn ("Grupo en {0:hh\:mm\:ss} sin imagen: se saltea" -f $tc); continue }
    $num++
    $mcName = '{0}_multicam {1:000}' -f $syncName, $num

    # 1) pedacitos con otra sincro -> afuera
    foreach ($mcId in @($g | ForEach-Object MC | Select-Object -Unique)) {
        $pieces = @($g | Where-Object { $_.MC -eq $mcId })
        $offs = @($pieces | ForEach-Object Off | Select-Object -Unique)
        if ($offs.Count -lt 2) { continue }
        foreach ($p in $pieces) {
            if (($p.End - $p.Start) -lt $tiny -and @($pieces | Where-Object { $_.Off -ne $p.Off -and ($_.End - $_.Start) -ge $tiny }).Count -gt 0) {
                $p.Drop = $true; Warn ("{0}: ignoro un pedacito de {1} ({2} cuadros) con otra sincro" -f $mcName, $p.Name, [long](($p.End - $p.Start) / $FRAME))
            }
        }
    }
    $live = @($g | Where-Object { -not $_.Drop })

    # 2) camara partida con dos sincros -> todo se alinea al primer pedazo
    foreach ($mcId in @($live | Where-Object Kind -eq 'V' | ForEach-Object MC | Select-Object -Unique)) {
        $pieces = @($live | Where-Object { $_.MC -eq $mcId } | Sort-Object Start)
        $ref = $pieces[0]
        foreach ($p in $pieces) {
            $d = ($p.Off + $p.Shift) - ($ref.Off + $ref.Shift)
            if ($d -eq 0) { continue }
            if ([math]::Abs($d) -le ($DRIFT_FRAMES * $FRAME)) { continue }   # correccion de drift: se respeta
            foreach ($x in $live) {
                if ([object]::ReferenceEquals($x, $ref)) { continue }
                if ((Overlap $x $p) -gt (Overlap $x $ref) -or [object]::ReferenceEquals($x, $p)) {
                    if ($x.Shift -eq 0 -or [object]::ReferenceEquals($x, $p)) { $x.Shift = -$d }
                }
            }
        }
    }
    foreach ($x in $live) { $x | Add-Member -Force NOff ($x.Off + $x.Shift) }

    # 3) un clip entero por pista y archivo
    #    - si un archivo quedo con varias sincros (drift corregido a mano), se respetan sus pedazos como estan
    #      en la timeline; solo se estira la cabeza del primero y la cola del ultimo
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($pg in ($live | Group-Object Kind, Track, MC)) {
        $pcs = @($pg.Group | Sort-Object Start)
        $offs = @($pcs | ForEach-Object NOff | Select-Object -Unique)
        if ($offs.Count -eq 1) {
            $x = $pcs[0]
            $entries.Add([pscustomobject]@{ Kind = $x.Kind; Track = $x.Track; Src = $x; S = $x.NOff; E = $x.NOff + $x.Dur; In = [long]0 })
        } else {
            Warn ("{0}: {1} tiene pedazos con sincros distintas; los respeto como estan en la timeline" -f $mcName, $pcs[0].Name)
            for ($i = 0; $i -lt $pcs.Count; $i++) {
                $x = $pcs[$i]
                $S = $x.Start + $x.Shift; $E = $x.End + $x.Shift; $In = $x.In
                if ($i -eq 0) { $S -= $In; $In = [long]0 }
                if ($i -eq $pcs.Count - 1) { $E = $x.NOff + $x.Dur }
                $entries.Add([pscustomobject]@{ Kind = $x.Kind; Track = $x.Track; Src = $x; S = $S; E = $E; In = $In })
            }
        }
    }
    # sonido que tambien esta en otros grupos: se recorta al largo de las camaras de este grupo
    $vE = @($entries | Where-Object Kind -eq 'V')
    [long]$camS = MinL $vE 'S'; [long]$camE = MaxL $vE 'E'
    foreach ($e in @($entries | Where-Object { $_.Kind -eq 'A' -and $audioGroups[$_.Src.MC] -gt 1 })) {
        $ns = [math]::Max($e.S, $camS); $ne = [math]::Min($e.E, $camE)
        if ($ne -le $ns) { $e.Kind = 'X'; continue }
        $e.In += ($ns - $e.S); $e.S = $ns; $e.E = $ne
        Warn ("{0}: {1} esta cortado en varias tomas; lo recorto al largo de las camaras" -f $mcName, $e.Src.Name)
    }
    $entries = @($entries | Where-Object { $_.Kind -ne 'X' })
    [long]$base = MinL $entries 'S'
    foreach ($e in $entries) { $e.S -= $base; $e.E -= $base }
    # superposiciones en una misma pista: se recorta la cabeza del siguiente
    foreach ($grpE in ($entries | Group-Object Kind, Track)) {
        $prev = $null
        foreach ($e in ($grpE.Group | Sort-Object S)) {
            if ($prev -and $e.S -lt $prev.E) {
                $cut = $prev.E - $e.S
                if ($cut -ge ($e.E - $e.S)) { Warn ("{0}: {1} queda tapado por {2} en la misma pista; se omite" -f $mcName, $e.Src.Name, $prev.Src.Name); $e.Kind = 'X'; continue }
                $e.S += $cut; $e.In += $cut
                Warn ("{0}: {1} se superpone con {2} en la misma pista; recorto {3} cuadros de cabeza" -f $mcName, $e.Src.Name, $prev.Src.Name, [long]($cut / $FRAME))
            }
            $prev = $e
        }
    }
    $entries = @($entries | Where-Object { $_.Kind -ne 'X' })
    [long]$seqDur = MaxL $entries 'E'

    # 4) pistas (compactadas: sin pistas vacias en el medio)
    foreach ($kk in @('V', 'A')) {
        $used = @($entries | Where-Object Kind -eq $kk | ForEach-Object Track | Sort-Object -Unique)
        foreach ($e in ($entries | Where-Object Kind -eq $kk)) { $e.Track = [array]::IndexOf($used, $e.Track) }
    }
    $nV = (MaxL @($entries | Where-Object Kind -eq 'V') 'Track') + 1
    $aE = @($entries | Where-Object Kind -eq 'A')
    $nA = 1; if ($aE.Count) { $nA = (MaxL $aE 'Track') + 1 }
    $v1 = @($entries | Where-Object { $_.Kind -eq 'V' } | Sort-Object Track, S)[0]
    $vs = Ref $v1.Src.Media.SelectSingleNode('VideoStream')
    $rect = Txt $vs 'FrameRect'; $vRate = Txt $vs 'FrameRate'
    if (-not $vRate) { $vRate = [string]$FRAME }

    $vTracks = @(); $aTracks = @()
    for ($t = 0; $t -lt $nV; $t++) {
        $tr = Clone-Obj $tmplVTrack $stopTmpl $pruneTrack
        $tr.SelectSingleNode('ClipTrack/Track/ID').InnerText = [string]($t + 1)
        foreach ($ix in $tr.SelectNodes('ClipTrack/*/Index')) { $ix.InnerText = [string]$t }
        $tr.SelectSingleNode('ClipTrack/Track/Node/Properties/MZ.SourceTrackNumber').InnerText = $(if ($t -eq 0) { '0' } else { '-1' })
        $vTracks += $tr
    }
    for ($t = 0; $t -lt $nA; $t++) {
        $tr = Clone-Obj $tmplATrack $stopTmpl $pruneTrack
        $tr.SelectSingleNode('ClipTrack/Track/ID').InnerText = [string]($t + 2)
        foreach ($ix in $tr.SelectNodes('ClipTrack/*/Index')) { $ix.InnerText = [string]$t }
        $sn = $tr.SelectSingleNode('ClipTrack/Track/Node/Properties/MZ.SourceTrackNumber'); if ($sn) { $sn.InnerText = $(if ($t -eq 0) { '0' } else { '-1' }) }
        # ruteo adaptativo como lo arma Premiere: A1->ch1, A2->ch2, A3->ch3...
        # (pares de canales; pista par = balance izquierda, impar = derecha)
        $pan = Ref $tr.SelectSingleNode('AudioTrack/Panner')
        $pair = 2 * [math]::Floor($t / 2)
        $mx = $pan.SelectSingleNode('.//Matrix'); if ($mx) { $mx.InnerText = ('[[0,[{0}]],[1,[{1}]]]' -f $pair, ($pair + 1)) }
        $bal = Ref $pan.SelectSingleNode('.//Params/Param')
        if ($bal) {
            Remove-Child $bal 'StartKeyframe'; Remove-Child $bal 'CurrentValue'
            if (($t % 2) -eq 0) {
                $nm = $bal.SelectSingleNode('Name')
                $sk = $doc.CreateElement('StartKeyframe'); $sk.InnerText = '-91445760000000000,0.,0,0,0,0,0,0'; [void]$bal.InsertBefore($sk, $nm)
                $cv = $doc.CreateElement('CurrentValue'); $cv.InnerText = '0'; [void]$bal.InsertBefore($cv, $nm)
            }
        }
        $aTracks += $tr
    }

    # 5) clips dentro de las pistas
    foreach ($e in $entries) {
        $ni = Clone-Obj $e.Src.El $stopShared $null
        $ti = $ni.SelectSingleNode('ClipTrackItem/TrackItem')
        Remove-Child $ti 'Start'
        if ($e.S -ne 0) { Set-Child $ti 'Start' ([string]$e.S) $ti.SelectSingleNode('End') }
        Set-Child $ti 'End' ([string]$e.E) $null
        $sub = Ref $ni.SelectSingleNode('ClipTrackItem/SubClip')
        $cl = (Ref $sub.SelectSingleNode('Clip')).SelectSingleNode('Clip')
        Remove-Child $cl 'InPoint'
        $outN = $cl.SelectSingleNode('OutPoint')
        Set-Child $cl 'OutPoint' ([string]$e.Src.Dur) $cl.SelectSingleNode('InPoint')
        $outN = $cl.SelectSingleNode('OutPoint')
        $inN = $doc.CreateElement('InPoint'); $inN.InnerText = [string]$e.In
        [void]$cl.InsertAfter($inN, $outN)
        $trk = $(if ($e.Kind -eq 'V') { $vTracks[$e.Track] } else { $aTracks[$e.Track] })
        $tis = $trk.SelectSingleNode('ClipTrack/ClipItems/TrackItems')
        $n = $doc.CreateElement('TrackItem'); $n.SetAttribute('Index', [string]$tis.SelectNodes('TrackItem').Count); $n.SetAttribute('ObjectRef', $ni.GetAttribute('ObjectID'))
        [void]$tis.AppendChild($n)
    }
    # ordenar items por tiempo dentro de cada pista (re-indexar)
    foreach ($trk in ($vTracks + $aTracks)) {
        $tis = $trk.SelectSingleNode('ClipTrack/ClipItems/TrackItems')
        $refs = @($tis.SelectNodes('TrackItem') | Sort-Object { LongOr0 (Txt $byId[$_.GetAttribute('ObjectRef')] 'ClipTrackItem/TrackItem/Start') } | ForEach-Object { $_.GetAttribute('ObjectRef') })
        Set-List $tis 'TrackItem' 'ObjectRef' $refs
    }

    # 6) grupos de pistas y secuencia
    $nVG = Clone-Obj $tmplGroups['VideoTrackGroup'] $stopTmpl $pruneGroup
    Set-List $nVG.SelectSingleNode('TrackGroup/Tracks') 'Track' 'ObjectURef' @($vTracks | ForEach-Object { $_.GetAttribute('ObjectUID') })
    $nVG.SelectSingleNode('TrackGroup/FrameRate').InnerText = $vRate
    $nVG.SelectSingleNode('TrackGroup/NextTrackID').InnerText = [string]($nV + 1)
    if ($rect) { $nVG.SelectSingleNode('FrameRect').InnerText = $rect }

    $nAG = Clone-Obj $tmplGroups['AudioTrackGroup'] $stopTmpl $pruneGroup
    Set-List $nAG.SelectSingleNode('TrackGroup/Tracks') 'Track' 'ObjectURef' @($aTracks | ForEach-Object { $_.GetAttribute('ObjectUID') })
    $nAG.SelectSingleNode('TrackGroup/NextTrackID').InnerText = [string]($nA + 2)
    $nAdapt = [math]::Min($nA, 32)
    $nAG.SelectSingleNode('NumAdaptiveChannels').InnerText = [string]$nAdapt
    $mix = Ref $nAG.SelectSingleNode('MasterTrack')
    $inlet = Ref $mix.SelectSingleNode('Inlet')
    Set-List $inlet.SelectSingleNode('Sources') 'Source' 'ObjectURef' @($aTracks | ForEach-Object { $_.GetAttribute('ObjectUID') })

    $nDG = $null; if ($tmplGroups.ContainsKey('DataTrackGroup')) { $nDG = Clone-Obj $tmplGroups['DataTrackGroup'] $stopTmpl $null }

    $nSeq = Clone-Obj $tmplSeq $stopTmpl {
        param($n)
        foreach ($tg in $n.SelectNodes('TrackGroups/TrackGroup')) { $tg.SelectSingleNode('Second').RemoveAttribute('ObjectRef') }
    }
    # cada TrackGroup de la plantilla se reemplaza por el nuevo del MISMO tipo (no se asume orden)
    $newByType = @{ 'VideoTrackGroup' = $nVG; 'AudioTrackGroup' = $nAG }
    if ($nDG) { $newByType['DataTrackGroup'] = $nDG }
    $oldTgs = @($tmplSeq.SelectNodes('TrackGroups/TrackGroup'))
    $newTgs = @($nSeq.SelectNodes('TrackGroups/TrackGroup'))
    for ($i = 0; $i -lt $newTgs.Count; $i++) {
        $typ = (Ref $oldTgs[$i].SelectSingleNode('Second')).LocalName
        if ($newByType.ContainsKey($typ)) { $newTgs[$i].SelectSingleNode('Second').SetAttribute('ObjectRef', $newByType[$typ].GetAttribute('ObjectID')) }
        else { [void]$newTgs[$i].ParentNode.RemoveChild($newTgs[$i]) }
    }
    $nSeq.SelectSingleNode('Name').InnerText = $mcName
    $props = $nSeq.SelectSingleNode('Node/Properties')
    foreach ($p in @($props.ChildNodes)) {
        if ($p.NodeType -ne 'Element') { continue }
        if ($p.LocalName -like 'HSL.*' -or $p.LocalName -eq 'MZ.InPoint' -or $p.LocalName -eq 'MZ.OutPoint') { [void]$props.RemoveChild($p) }
    }
    $el = $props.SelectSingleNode('MZ.EditLine'); if ($el) { $el.InnerText = '0' }
    $el = $props.SelectSingleNode('Monitor.ProgramZoomOut'); if ($el) { $el.InnerText = [string]$seqDur }
    if ($rect) {
        $wh = $rect.Split(',')
        $el = $props.SelectSingleNode('MZ.Sequence.PreviewFrameSizeWidth'); if ($el) { $el.InnerText = $wh[2] }
        $el = $props.SelectSingleNode('MZ.Sequence.PreviewFrameSizeHeight'); if ($el) { $el.InnerText = $wh[3] }
    }

    # 7) master clip multicam + item de proyecto
    $nMC = Clone-Obj $tmplMC $stopTmpl $null
    $nMC.SelectSingleNode('Name').InnerText = $mcName
    (Ref $nMC.SelectSingleNode('LoggingInfo')).SelectSingleNode('ClipName').InnerText = $mcName
    $mp = $nMC.SelectSingleNode('Node/Properties')
    $el = $mp.SelectSingleNode('monitor.edit.time'); if ($el) { $el.InnerText = '0' }
    $el = $mp.SelectSingleNode('monitor.zoom.out.time'); if ($el) { $el.InnerText = [string]$seqDur }
    $el = $mp.SelectSingleNode('Source.Monitor.Multicam.TrackIndex'); if ($el) { $el.InnerText = '0' }
    foreach ($c in $nMC.SelectNodes('Clips/Clip')) {
        $o = Ref $c
        $cc = $o.SelectSingleNode('Clip')
        Remove-Child $cc 'InPoint'; Remove-Child $cc 'OutPoint'
        $ss = Ref $cc.SelectSingleNode('Source')
        $ss.SelectSingleNode('SequenceSource/Sequence').SetAttribute('ObjectURef', $nSeq.GetAttribute('ObjectUID'))
        $ss.SelectSingleNode('OriginalDuration').InnerText = [string]$seqDur
    }
    # canales de audio del master clip = canales adaptativos
    $chains = $nMC.SelectSingleNode('AudioComponentChains')
    $ch = @($chains.SelectNodes('AudioComponentChain'))
    $keep = @(); for ($i = 0; $i -lt $nAdapt; $i++) { if ($i -lt $ch.Count) { $keep += $ch[$i].GetAttribute('ObjectRef') } else { $keep += (Clone-Obj (Ref $ch[0]) $stopTmpl $null).GetAttribute('ObjectID') } }
    Set-List $chains 'AudioComponentChain' 'ObjectRef' $keep
    $grpVec = Ref $nMC.SelectSingleNode('AudioClipChannelGroups')
    $vecs = $grpVec.SelectSingleNode('ClipChannelVectors')
    $first = Ref $vecs.SelectSingleNode('ClipChannelVectorItem')
    $newVecs = @()
    for ($i = 0; $i -lt $nAdapt; $i++) {
        $v = Clone-Obj $first $stopTmpl $null
        $cs = Ref $v.SelectSingleNode('ClipChannels/ClipChannelItem')
        $cs.SelectSingleNode('SourceClipIndex').InnerText = [string]$tmpl.AIdx
        $cs.SelectSingleNode('mSourceChannelIndex').InnerText = [string]$i
        $newVecs += $v.GetAttribute('ObjectID')
    }
    Set-List $vecs 'ClipChannelVectorItem' 'ObjectRef' $newVecs

    $nPI = Clone-Obj $tmplPI $stopTmpl $null
    $nPI.SelectSingleNode('ProjectItem/Name').InnerText = $mcName
    $nPI.SelectSingleNode('ProjectItem/Node/ID').InnerText = [string]$script:nextPI; $script:nextPI++
    $nPI.SelectSingleNode('MasterClip').SetAttribute('ObjectURef', $nMC.GetAttribute('ObjectUID'))
    $newPIs.Add($nPI.GetAttribute('ObjectUID'))

    $nCams = @($entries | Where-Object Kind -eq 'V' | ForEach-Object Track | Select-Object -Unique).Count
    $snd = @($entries | Where-Object Kind -eq 'A' | ForEach-Object { $_.Src.Name } | Select-Object -Unique) -join ', '
    Say ("{0}  ({1:hh\:mm\:ss})  camaras: {2}  sonido: {3}" -f $mcName, $tc, $nCams, $(if ($snd) { $snd } else { '-' }))
}

if ($num -eq 0) { throw 'No se armo ninguna multicam: esa secuencia no tiene clips de camara/sonido sueltos. Elegiste la secuencia de sincro?' }

# ---------------------------------------------------------------- bin nuevo
$tmplBin = $null
foreach ($b in $byUid.Values) { if ($b.LocalName -eq 'BinProjectItem') { $tmplBin = $b; break } }
$rootItem = Ref $projEl.SelectSingleNode('RootProjectItem')
$rItems = $rootItem.SelectSingleNode('ProjectItemContainer/Items')
if ($tmplBin) {
    $nBin = [System.Xml.XmlElement]$tmplBin.CloneNode($true)
    $nBin.SetAttribute('ObjectUID', [guid]::NewGuid().ToString())
    $bp = $nBin.SelectSingleNode('ProjectItem/Node/Properties'); if ($bp) { foreach ($c in @($bp.ChildNodes)) { [void]$bp.RemoveChild($c) } }
    $nBin.SelectSingleNode('ProjectItem/Node/ID').InnerText = [string]$script:nextPI; $script:nextPI++
    $nBin.SelectSingleNode('ProjectItem/Name').InnerText = "$($syncName)_multicams"
    Set-List $nBin.SelectSingleNode('ProjectItemContainer/Items') 'Item' 'ObjectURef' $newPIs
    Add-Obj $nBin
    $toRoot = @($nBin.GetAttribute('ObjectUID'))
    $where = "el bin '$($syncName)_multicams'"
} else {
    # proyecto sin ninguna carpeta: las multicam van a la raiz
    $toRoot = @($newPIs)
    $where = 'la raiz del proyecto'
}
foreach ($u in $toRoot) {
    $cnt = $rItems.SelectNodes('Item').Count
    $ri = $doc.CreateElement('Item'); $ri.SetAttribute('Index', [string]$cnt); $ri.SetAttribute('ObjectURef', $u)
    [void]$rItems.AppendChild($ri)
}
$projNext.InnerText = [string]$script:nextPI

# ---------------------------------------------------------------- limpiar objetos nuevos sin uso
$refd = New-Object 'System.Collections.Generic.HashSet[string]'
function Collect-Refs([System.Xml.XmlElement]$el) {
    foreach ($r in $el.SelectNodes('descendant-or-self::*[@ObjectRef or @ObjectURef]')) {
        $a = $r.GetAttribute('ObjectRef'); if ($a) { [void]$refd.Add($a) }
        $b = $r.GetAttribute('ObjectURef'); if ($b) { [void]$refd.Add($b) }
    }
}
$isNew = New-Object 'System.Collections.Generic.HashSet[System.Xml.XmlElement]'
foreach ($e in $script:newEls) { [void]$isNew.Add($e) }
foreach ($n in $rootEl.ChildNodes) { if ($n.NodeType -eq 'Element') { Collect-Refs $n } }
$alive = New-Object System.Collections.Generic.List[System.Xml.XmlElement]
$pending = New-Object System.Collections.Generic.List[System.Xml.XmlElement]
foreach ($e in $script:newEls) { $pending.Add($e) }
$progress = $true
while ($progress) {
    $progress = $false
    for ($i = $pending.Count - 1; $i -ge 0; $i--) {
        $e = $pending[$i]
        $key = $e.GetAttribute('ObjectID'); if (-not $key) { $key = $e.GetAttribute('ObjectUID') }
        if ($refd.Contains($key)) { $alive.Add($e); Collect-Refs $e; $pending.RemoveAt($i); $progress = $true }
    }
}
$script:newEls = $alive

# ---------------------------------------------------------------- escribir
foreach ($e in $script:newEls) {
    [void]$rootEl.AppendChild($doc.CreateTextNode("`n`t"))
    [void]$rootEl.AppendChild($e)
}
[void]$rootEl.AppendChild($doc.CreateTextNode("`n"))

$dir = [System.IO.Path]::GetDirectoryName($ProjectPath)
$baseName = [System.IO.Path]::GetFileNameWithoutExtension($ProjectPath) + '_MULTICAM'
$outPath = Join-Path $dir ($baseName + '.prproj'); $k = 2
while (Test-Path -LiteralPath $outPath) { $outPath = Join-Path $dir ('{0}_{1}.prproj' -f $baseName, $k); $k++ }

$ms = New-Object System.IO.MemoryStream
$ws = New-Object System.Xml.XmlWriterSettings
$ws.Encoding = New-Object System.Text.UTF8Encoding($false)
$xw = [System.Xml.XmlWriter]::Create($ms, $ws)
$doc.Save($xw); $xw.Close()
$out = [System.IO.File]::Create($outPath)
try {
    $gzo = New-Object System.IO.Compression.GZipStream($out, [System.IO.Compression.CompressionMode]::Compress)
    $ms.Position = 0; $ms.CopyTo($gzo); $gzo.Close()
} finally { $out.Close() }

Say ''
Say "Listo: $num multicam en $where"
Say "Proyecto nuevo: $outPath"
[System.IO.File]::WriteAllLines(($outPath -replace '\.prproj$', '_log.txt'), $script:Log, (New-Object System.Text.UTF8Encoding($true)))
Pause-IfExe
