@echo off
:: Puts this (new) version of Offline POS in place of the installed one, keeping
:: the shop's data. Run it from the folder the new version was unzipped to.
chcp 65001 >nul
title Offline POS update
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\update_offline_pos.ps1" -Source "%~dp0."
