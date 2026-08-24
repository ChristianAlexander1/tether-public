#@ cmd: missing-tool --flag => 127
#@ want: missing-tool --flag
true
echo "t=$?"
false
echo "f=$?"
missing-tool --flag
echo "c=$?"
echo ok > /dev/null
echo "r=$?"
