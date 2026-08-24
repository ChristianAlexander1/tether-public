x=before
echo "x=$x"
unset x
echo "after:${x:-gone}"
list="a b"
unset list
echo "list:${list:-also-gone}"
