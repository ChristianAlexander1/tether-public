i=0
while [ "$i" -lt 5 ]; do
  i=$((i + 1))
  if [ "$i" -eq 2 ]; then
    continue
  fi
  if [ "$i" -eq 4 ]; then
    continue
  fi
  echo "k$i"
done
