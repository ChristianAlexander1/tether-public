#@ argv: orig extra
#@ file: lib2.sh :: echo "sourced:$1 $2"\n
. ./lib2.sh a b
echo "outer:$1"
