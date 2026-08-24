list="one two  three"
for w in $list; do
  echo "[$w]"
done
for w in "$list"; do
  echo "<$w>"
done
count=0
for w in $list; do count=$((count + 1)); done
echo "fields=$count"
