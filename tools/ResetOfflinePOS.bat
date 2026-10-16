@echo off
:: Deletes ALL of Offline POS's data on this computer (orders, menu, staff, settings,
:: pairing) so it opens as a new install. Keeps a backup in Documents first, and
:: asks you to type DELETE before it touches anything.
chcp 65001 >nul
title Offline POS - delete all data
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0reset_offline_pos.ps1"
