echo "to-stdout"
echo "to-stderr" >&2
. ./missing-lib.sh 2> err.txt || echo "status=$?"
cat err.txt
