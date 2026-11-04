param(
    [string]$Port = "COM12",
    [int]$Seconds = 12,
    [string]$Out = "D:\dev27\z7skytum\myxtrv32\out\uart_capture.txt"
)

$ErrorActionPreference = "Stop"
$sp = New-Object System.IO.Ports.SerialPort
$sp.PortName = $Port
$sp.BaudRate = 115200
$sp.Parity = "None"
$sp.DataBits = 8
$sp.StopBits = "One"
$sp.DtrEnable = $false
$sp.RtsEnable = $false
$sp.ReadTimeout = 500
$sp.Open()

$buf = New-Object byte[] 4096
$ms = New-Object System.IO.MemoryStream
$end = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $end) {
    if ($sp.BytesToRead -gt 0) {
        $n = $sp.Read($buf, 0, $buf.Length)
        $ms.Write($buf, 0, $n)
    } else {
        Start-Sleep -Milliseconds 20
    }
}
$sp.Close()

$bytes = $ms.ToArray()
[System.IO.File]::WriteAllBytes($Out, $bytes)
Write-Output ("captured {0} bytes -> {1}" -f $bytes.Length, $Out)
