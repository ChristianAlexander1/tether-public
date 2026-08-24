#@ argv: a b c d
echo "count=$#"
echo "first=$1 second=$2"
echo "all=$*"
shift
echo "after-shift:$1 $2 ($#)"
shift 2
echo "last:$1 ($#)"
set -- x y
echo "reset:$1$2 ($#)"
