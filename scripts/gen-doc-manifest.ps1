# Generate docs/manifest.json -- a machine-readable index of the design documents.
#
# WHY THIS EXISTS
#   docs/ has 70+ numbered documents. docs/README.md is the human-facing index
#   and it is genuinely useful, but its "current state" section is a SNAPSHOT:
#   it still says "regression 21 tests / LUT 14725" while the tree is at
#   25 tests / LUT 30520. An agent that reads only the README believes numbers
#   that are days and several designs old.
#
#   A manifest cannot stop a document going stale, but it CAN say which document
#   is authoritative and what each one is. That was the missing part.
#
# HOW FIELDS ARE FILLED
#   path/title/chars/mtime  scanned
#   summary                 first real paragraph (skips headings, quotes, tables)
#   kind/status/tags        override table > filename heuristic
#   The override table is the ONLY hand-maintained part; re-run after adding docs.
#
# USAGE  pwsh -File gen-doc-manifest.ps1
# NOTE: ASCII only.

param(
    [string]$DocsDir = 'C:\Users\25437\Desktop\竞赛\嵌入式设计竞赛FPGA设计项目\2D图形加速引擎\docs',
    [string]$Out = ''
)

$ErrorActionPreference = 'Stop'
if (-not $Out) { $Out = Join-Path $DocsDir "manifest.json" }
if (-not (Test-Path $DocsDir)) { Write-Host ("ERROR: no docs dir: " + $DocsDir); exit 2 }

# ---------------------------------------------------------------- authority
$authority = [ordered]@{
    current_state      = '..\新会话交接-20261015.md'
    current_state_note = 'The handover note is the authoritative current state. docs\README.md is NOT: its state section is a snapshot.'
    stale              = @('README.md')
    stale_note         = 'README.md says (2026-10-07) regression 21 tests / LUT 14725; the tree is at 25 tests / LUT 30520 as of 2026-10-15. Read it for structure, not numbers.'
    newest_findings    = @('82-tile化帧缓冲方案与风险.md','81-行合并可行性判别.md','80-往返分解与各方向收益上限.md','79-方向A同步FIFO实施.md','78-通往2048的优化方向调研.md','77-扩表2048的真相-元凶是综合选项.md','75-性能退化的真相-扫描输出开关.md','76-扩表到2048.md','73-方案A目标读跨行流水.md','74-方案B写侧不等B响应-实测与回退.md','72-每精灵成本分解-按行往返主导.md')
}

# ------------------------------------------------------- hand-maintained
$over = @{
  'README.md'                           = @{ kind='index'; status='stale-index'; tags=@('索引','数字已过时'); summary='人读的结构索引。其中"当前状态"一节停在 2026-10-07（回归 21 项 / LUT 14725），数字一律勿信；权威状态看交接文档' }
  '04-硬件权威事实.md'                  = @{ kind='reference'; status='current'; tags=@('硬件','权威'); summary='DDR3/HDMI/引脚等硬件事实，冲突时以此为准' }
  '34-架构总览.md'                      = @{ kind='reference'; status='current'; tags=@('架构'); summary='模块划分与数据通路总览' }
  '45-验证方法论与审计总览.md'          = @{ kind='reference'; status='current'; tags=@('方法'); summary='验证方法与审计口径' }
  '48-片上断言监控.md'                  = @{ kind='reference'; status='current'; tags=@('监控'); summary='11 项片上监控条件与寄存器语义' }
  '49-风险登记册.md'                    = @{ kind='record';    status='current'; tags=@('风险'); summary='风险清单' }
  '63-读通道死锁根因与修复.md'          = @{ kind='finding';   status='current'; tags=@('死锁','AXI'); summary='读通道死锁根因（burst 中途撤 rready）与突发准入修复' }
  '67-潜伏的307Hz：显示bug与性能bug.md' = @{ kind='finding';   status='current'; tags=@('显示'); summary='扫描输出实际跑 640x480@307Hz；修后真 1080p60 且引擎快 24%' }
  '68-1080p扫描输出诊断进展.md'         = @{ kind='finding';   status='current'; tags=@('显示','AXI'); summary='扫描输出分段读缺陷的复现与 A/B 对照' }
  '70-精灵表扩到1024槽.md'              = @{ kind='finding';   status='superseded'; tags=@('精灵表'); summary='256->1024 槽与对照实验；其"1.87x 运行间波动"的解释已被 docs/75 修正' }
  '71-屏上实时读数与1024进60fps.md'    = @{ kind='finding';   status='current'; tags=@('OSD','性能'); summary='屏上 OSD + 1024 精灵进 60fps；其"快/慢随机"的说法已被 docs/75 修正' }
  '72-每精灵成本分解-按行往返主导.md'   = @{ kind='finding';   status='current'; tags=@('性能','测量'); summary='形状实验：86% 成本是每行一次 DDR 往返，不是带宽' }
  '73-方案A目标读跨行流水.md'           = @{ kind='finding';   status='current'; tags=@('性能','RTL'); summary='方案 A：目标读整矩形一次启动，净收益 1.20x' }
  '74-方案B写侧不等B响应-实测与回退.md' = @{ kind='finding';   status='current'; tags=@('性能','RTL'); summary='方案 B 负收益已回退；附超 DDR 时钟此路不通（PLL 到顶）' }
  '75-性能退化的真相-扫描输出开关.md'   = @{ kind='finding';   status='current'; tags=@('性能','重要'); summary='重要纠正："性能退化"不存在，那是扫描输出的开关；真实基线 1,230 而非 763' }
  '76-扩表到2048.md'                    = @{ kind='finding';   status='superseded'; tags=@('精灵表','结论已被77推翻'); summary='扩表 2048 的七次尝试记录。★ §8 的"占用率90%判据"已被 docs/77 推翻，读 §8 前先读 77' }
  '82-tile化帧缓冲方案与风险.md' = @{ kind='finding';   status='current'; tags=@('性能','方案','tile'); summary='tile 化帧缓冲：实测连续目标比 strided 快 12.46×（89 vs 1109 拍）；难点全在扫描输出需 96 个 RAM10 的行带缓冲；含四阶段实施计划' }
  '81-行合并可行性判别.md' = @{ kind='finding';   status='current'; tags=@('性能','判别','行合并'); summary='行合并判别：密排布点 3.45x、随机弹幕 0.92x（反而更慢）—— 收益由横向覆盖率决定，是【针对测量场景】的优化而非通用加速' }
  '80-往返分解与各方向收益上限.md' = @{ kind='finding';   status='current'; tags=@('性能','测量','收益上限'); summary='往返分解：目标读+写占 83.6%（每行一次，结构性）；描述符批量上限仅 2.2%、纹理缓存 11.7% —— 2,048 只能靠行合并' }
  '79-方向A同步FIFO实施.md' = @{ kind='finding';   status='current'; tags=@('性能','RTL','方向A'); summary='方向 A 第一步：输出 FIFO 换成 FWFT 同步读（可落 BRAM），吞吐仍 1 拍/字，回归 26/0；深度刻意留 32，分两步走' }
  '78-通往2048的优化方向调研.md' = @{ kind='finding';   status='current'; tags=@('调研','优化方向','性能'); summary='通往 2048 精灵的优化方向调研：需 1.49x；A-F 组合约 1.97k，G(行合并)可达 2-3x 但有条件；2048 后带宽成硬墙' }
  '77-扩表2048的真相-元凶是综合选项.md' = @{ kind='finding';   status='current'; tags=@('精灵表','性能','重要','已达成'); summary='★ 2048 扩表上线 + 算力上限实测 1,376 精灵（999.2‰ 预算，边际 1,196 拍/精灵，r2=0.999986）；真凶是 use-logic-for-small-mem=0（把 DDR 小 FIFO 改成 RAM10），不是 N、不是占用率' }
}

$docs = @()
foreach ($f in (Get-ChildItem $DocsDir -File -Filter '*.md' | Sort-Object Name)) {
    $raw   = Get-Content $f.FullName -Raw -Encoding UTF8
    $lines = $raw -split "\r?\n"

    $title = ''
    foreach ($l in $lines) { if ($l -match '^#\s+(.+)$') { $title = $Matches[1].Trim(); break } }
    if (-not $title) { $title = $f.BaseName }

    $sum = ''
    foreach ($l in $lines) {
        $t = $l.Trim()
        if ($t -eq '') { continue }
        if ($t.StartsWith('#') -or $t.StartsWith('>') -or $t.StartsWith('|') -or $t.StartsWith('-') -or $t.StartsWith('/')) { continue }
        $sum = $t; break
    }
    if ($sum.Length -gt 140) { $sum = $sum.Substring(0,140) }

    $kind = 'record'
    $status = 'historical'
    $tags = @()
    if ($f.Name -eq 'README.md') { $kind = 'index'; $status = 'current' }
    if ($f.BaseName -match '^(\d+)') {
        $n = [int]$Matches[1]
        if ($n -ge 56) { $status = 'current' }
    }

    if ($over.ContainsKey($f.Name)) {
        $o = $over[$f.Name]
        if ($o.kind)    { $kind   = $o.kind }
        if ($o.status)  { $status = $o.status }
        if ($o.summary) { $sum    = $o.summary }
        if ($o.tags)    { $tags   = $o.tags }
    }

    $docs += [ordered]@{
        path    = $f.Name
        title   = $title
        kind    = $kind
        status  = $status
        tags    = $tags
        summary = $sum
        chars   = $f.Length
        mtime   = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
    }
}

$byStatus = @{}
foreach ($d in $docs) {
    if (-not $byStatus.ContainsKey($d.status)) { $byStatus[$d.status] = 0 }
    $byStatus[$d.status]++
}

$manifest = [ordered]@{
    generated_at = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    root         = $DocsDir
    schema       = @('path','title','kind','status','tags','summary','chars','mtime')
    authority    = $authority
    counts       = [ordered]@{ total = $docs.Count; by_status = $byStatus }
    docs         = $docs
}

$manifest | ConvertTo-Json -Depth 8 | Set-Content $Out -Encoding UTF8
Write-Host ("wrote " + $Out + "  (" + $docs.Count + " docs)")
foreach ($k in $byStatus.Keys) { Write-Host ("  " + $k + ": " + $byStatus[$k]) }
