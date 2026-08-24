printf 'alpha 1
beta 2
gamma 3
' > data.txt
while read name num; do
  echo "row:$name/$num"
done < data.txt
echo "done"
