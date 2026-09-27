param(
    [string]$Root = (Join-Path $env:LOCALAPPDATA 'Programs\MamidLabs'),
    [switch]$Warmup
)

$ErrorActionPreference = 'Stop'
$python = Join-Path $Root 'venv\ocr\Scripts\python.exe'
$cpuPython = Join-Path $Root 'venv\ocr-cpu\Scripts\python.exe'
$worker = Join-Path $Root 'agent\ocr-tools.py'
$cache = Join-Path $Root 'tools\paddle-cache'
# pip onbellegi kullanici profiline degil kurulum kokune yazilir; kaldirmada kokle birlikte gider.
$env:PIP_CACHE_DIR = Join-Path $Root 'tools\pip-cache'
$paddleWheel = 'https://paddle-qa.bj.bcebos.com/paddle-pipeline/Develop-TagBuild-Training-Windows-Gpu-Cuda12.9-Cudnn9.9-Trt10.5-Mkl-Avx-VS2019-SelfBuiltPypiUse/86d658f56ebf3a5a7b2b33ace48f22d10680d311/paddlepaddle_gpu-3.0.0.dev20250717-cp312-cp312-win_amd64.whl'
# Resmi kararli PaddlePaddle GPU kanali (paddlepaddle.org.cn); yukaridaki ozel
# nightly/QA derlemesi (paddle-qa.bj.bcebos.com) kalici bir surum kanali degil -
# bir gun kaldirilirsa diye fallback. Not: bu kanal RTX 50 serisindeki ozel
# sm_120 duzeltmesini icermeyebilir (asagidaki yorum), o yuzden once ozel
# derleme deneniyor, yalnizca o basarisiz olursa buna dusuluyor.
$paddleFallbackIndex = 'https://www.paddlepaddle.org.cn/packages/stable/cu126/'

try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $python), $cache -Force | Out-Null
    if (!(Test-Path -LiteralPath $python -PathType Leaf)) {
        $basePython = Get-Command python.exe -ErrorAction SilentlyContinue
        if (!$basePython) { throw 'python.exe bulunamadi. Python 3 kurup kurulumu tekrar calistirin.' }
        & $basePython.Source -m venv (Split-Path -Parent (Split-Path -Parent $python))
    }

    & $python -m pip install --upgrade pip
    # Duz gorsel OCR GPU'da calisir. PDF OCR worker icinde ayrica CPU'ya sabitlenir.
    # RTX 50 serisi Windows icin Paddle'in ozel sm_120 wheel'ini kullan.
    # Standart cu126 wheel'i CUDA'yi gorur ama OCR detection cekirdegi bos sonuc
    # verebilir. Ozel wheel CUDA 12.9 ve cuDNN 9.9 runtime'larini pinler.
    & $python -m pip install --upgrade --force-reinstall $paddleWheel
    if ($LASTEXITCODE -ne 0) {
        Write-Warning 'Ozel PaddlePaddle GPU derlemesi (nightly/QA kanali) indirilemedi; resmi kararli kanala (cu126) dusuluyor. Bu kanal RTX 50 serisinde bos OCR sonucu sorununu icermeyebilir.'
        & $python -m pip install --upgrade --force-reinstall paddlepaddle-gpu -i $paddleFallbackIndex
        if ($LASTEXITCODE -ne 0) { throw 'PaddlePaddle GPU kurulamadi (hem ozel derleme hem resmi kararli kanal basarisiz oldu).' }
    }
    & $python -m pip install --upgrade paddleocr pymupdf
    if ($LASTEXITCODE -ne 0) { throw 'paddleocr/pymupdf kurulamadi.' }
    $basePython = Get-Command python.exe -ErrorAction SilentlyContinue
    if (!$basePython) { throw 'python.exe bulunamadi. Python 3 kurup kurulumu tekrar calistirin.' }
    if (!(Test-Path -LiteralPath $cpuPython -PathType Leaf)) {
        & $basePython.Source -m venv (Split-Path -Parent (Split-Path -Parent $cpuPython))
    }
    & $cpuPython -m pip install --upgrade pip
    & $cpuPython -m pip install --upgrade paddlepaddle paddleocr pymupdf
    if ($LASTEXITCODE -ne 0) { throw 'PDF (CPU) OCR ortami kurulamadi.' }
    if (!(Test-Path -LiteralPath $worker -PathType Leaf)) {
        throw "OCR worker bulunamadi: $worker"
    }
    if ($Warmup) {
        $env:PADDLE_HOME = $cache
        $env:PADDLEOCR_HOME = $cache
        $env:PADDLEX_HOME = $cache
        $env:PADDLE_PDX_HOME = $cache
        '{"action":"warmup","device":"gpu"}' | & $python $worker
        '{"action":"warmup","device":"cpu"}' | & $cpuPython $worker
    }
    Write-Output "OCR kurulumu tamamlandi. Ortam: $python"
    Write-Output "PDF CPU ortami: $cpuPython"
    Write-Output "Model cache: $cache"
} catch {
    Write-Error "OCR kurulumu basarisiz: $($_.Exception.Message)"
    exit 1
}
