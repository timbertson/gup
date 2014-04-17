set GUP_EXE=%CD%\bin\gup&
set SKIP_PYCHECKER=1&
cmd /C .\build.bat&
0install run --command=test-min ../gup-test-local.xml -w ..\test %*
