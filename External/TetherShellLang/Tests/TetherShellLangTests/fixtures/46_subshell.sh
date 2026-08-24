x=outer
(x=inner; echo "sub:$x"; echo subfile > sub.txt)
echo "main:$x"
if [ -e sub.txt ]; then echo "leaked"; else echo "isolated"; fi
(exit 9)
echo "status=$?"
