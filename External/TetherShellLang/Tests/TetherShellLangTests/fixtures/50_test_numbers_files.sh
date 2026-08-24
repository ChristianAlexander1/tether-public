if [ 5 -gt 3 ]; then echo "5>3"; fi
if [ 3 -lt 1 ]; then echo "bad"; else echo "3!<1"; fi
if [ 4 -le 4 ]; then echo "le"; fi
if [ 7 -ge 8 ]; then echo "ge-bad"; else echo "ge-false"; fi
if [ 9 -eq 9 ] && [ 9 -ne 8 ]; then echo "eq-ne"; fi
echo content > probe.txt
: > empty.txt
if [ -e probe.txt ]; then echo "exists"; fi
if [ -s probe.txt ]; then echo "has-size"; fi
if [ -e empty.txt ]; then echo "empty-exists"; fi
if [ -s empty.txt ]; then echo "bad-size"; else echo "zero-size"; fi
if [ -e nope.txt ]; then echo "bad"; else echo "missing-false"; fi
