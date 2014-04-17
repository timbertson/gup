if not exist bin mkdir bin &
if not exist tmp mkdir tmp &
python build\combine_modules.py gup tmp\gup.py &
copy /Y tmp\gup.py bin\gup
