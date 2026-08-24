today=$(echo "2026-08-23")
echo "date=$today"
legacy=`echo legacy`
echo "$legacy"
both="x$(echo mid)y"
echo "$both"
words=$(printf 'a b c')
for w in $words; do
  echo "[$w]"
done
