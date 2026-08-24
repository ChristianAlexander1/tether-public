s=""
if [ -z "$s" ]; then echo "empty"; fi
if [ -n "x" ]; then echo "nonempty"; fi
if [ "abc" = "abc" ]; then echo "eq"; fi
if [ "abc" != "abd" ]; then echo "ne"; fi
if ! [ 1 = 2 ]; then echo "bang"; fi
if [ ! "yes" = "no" ]; then echo "not-op"; fi
