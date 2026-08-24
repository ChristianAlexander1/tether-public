{ echo a; echo b; } > group.txt
x=1
{ x=changed; }
echo "x=$x"
cat group.txt
