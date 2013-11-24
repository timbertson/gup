if not exist bin mkdir bin &
set SKIP_PYCHECKER=1 &
python build/combine_modules.py gup tmp/gup.py &
copy /Y tmp\gup.py bin\gup
