# Phase 7: 07-nativeimages
# Extracted from WinEasebuilder.ps1
# Dot-sourced by the main orchestrator


# 7. Removing NativeImages (.NET)
Write-Host "Removing pre-compiled .NET Native Images..." -ForegroundColor Cyan
Remove-Item -Path "$scratchDir\Windows\assembly\NativeImages_*" -Recurse -Force -ErrorAction SilentlyContinue
