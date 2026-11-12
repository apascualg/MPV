@echo off
echo Compilando cropclip.exe con el compilador C# de .NET Framework...
"C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /optimize+ /target:winexe /out:"%~dp0cropclip.exe" "%~dp0cropclip.cs"
if %ERRORLEVEL% EQU 0 (
    echo [OK] Compilado con exito: %~dp0cropclip.exe
) else (
    echo [ERROR] Fallo la compilacion.
)
pause
